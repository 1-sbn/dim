-- Texture matching and brightness copies.
local ffi = require('ffi')
local bit = require('bit')
local textures = {}
local DXT1, DXT3, DXT5 = 827611204, 861165636, 894720068
local function check(hr, op)
    if hr ~= 0 then error(op .. ': ' .. tostring(hr)) end
end
local crc_table = {}
for value = 0, 255 do
    local crc = value
    for _ = 1, 8 do
        crc = bit.bxor(bit.rshift(crc, 1), bit.band(crc, 1) == 1 and 0xEDB88320 or 0)
    end
    crc_table[value] = crc
end
function textures.fingerprint(source)
    if source:GetType() ~= 3 then return nil end
    local src = ffi.cast('IDirect3DTexture8*', source)
    local hr, desc = src:GetLevelDesc(0)
    check(hr, 'Fingerprint description')
    local w, h, format = tonumber(desc.Width), tonumber(desc.Height), tonumber(desc.Format)
    if w > 1024 or h > 1024 or w < 1 or h < 1 then return nil end
    local compressed = format == DXT1 or format == DXT3 or format == DXT5
    if not compressed and format ~= 21 and format ~= 22 then return nil end
    local row_bytes = compressed and math.max(1, math.ceil(w / 4)) * (format == DXT1 and 8 or 16) or w * 4
    local rows = compressed and math.max(1, math.ceil(h / 4)) or h
    local read_hr, rect = src:LockRect(0, nil, 16)
    check(read_hr, 'Read-lock fingerprint')
    local ok, hash = pcall(function()
        assert(rect.pBits ~= nil and tonumber(rect.Pitch) >= row_bytes, 'Invalid fingerprint pixels/pitch')
        local bytes, crc = ffi.cast('uint8_t*', rect.pBits), -1
        for y = 0, rows - 1 do
            local row = bytes + y * tonumber(rect.Pitch)
            for x = 0, row_bytes - 1 do
                crc = bit.bxor(bit.rshift(crc, 8), crc_table[bit.band(bit.bxor(crc, row[x]), 255)])
            end
        end
        return bit.tohex(bit.bnot(crc), 8)
    end)
    local unlock_hr = src:UnlockRect(0)
    check(unlock_hr, 'Unlock fingerprint')
    if not ok then error(hash) end
    return string.format('%dx%d:%d:%s', w, h, format, hash)
end
local function scaled565(value, factor)
    local b = value % 32
    local g = math.floor(value / 32) % 64
    local r = math.floor(value / 2048)
    return math.floor(r * factor + 0.5) * 2048 +
        math.floor(g * factor + 0.5) * 32 + math.floor(b * factor + 0.5)
end
function textures.darken_rows(format, width, height, src_bits, src_pitch, dst_bits, dst_pitch, factor)
    assert(factor >= 0 and factor <= 1, 'Invalid RGB multiplier')
    local compressed = format == DXT1 or format == DXT3 or format == DXT5
    local block_size = format == DXT1 and 8 or 16
    assert(compressed or format == 21 or format == 22, 'Unsupported texture format: ' .. format)
    local columns = compressed and math.max(1, math.ceil(width / 4)) or width
    local rows = compressed and math.max(1, math.ceil(height / 4)) or height
    local row_bytes = columns * (compressed and block_size or 4)
    assert(src_pitch >= row_bytes and dst_pitch >= row_bytes, 'Invalid texture row pitch')
    assert(src_bits ~= nil and dst_bits ~= nil, 'Missing texture pixels')
    local src, dst = ffi.cast('uint8_t*', src_bits), ffi.cast('uint8_t*', dst_bits)
    for y = 0, rows - 1 do
        local s, d = src + y * src_pitch, dst + y * dst_pitch
        ffi.copy(d, s, row_bytes)
        if compressed then
            for x = 0, columns - 1 do
                local offset = x * block_size + (format == DXT1 and 0 or 8)
                local original = ffi.cast('uint16_t*', s + offset)
                local color = ffi.cast('uint16_t*', d + offset)
                local c0, c1 = scaled565(tonumber(original[0]), factor), scaled565(tonumber(original[1]), factor)
                -- DXT1 endpoint order selects the alpha mode.
                if format == DXT1 and original[0] > original[1] and c0 <= c1 then
                    if c1 < 65535 then c0 = c1 + 1 else c1 = c0 - 1 end
                elseif format == DXT1 and original[0] <= original[1] and c0 > c1 then
                    c0, c1 = c1, c0
                end
                color[0], color[1] = c0, c1
            end
        else
            for x = 0, width - 1 do
                for channel = 0, 2 do
                    local offset = x * 4 + channel
                    d[offset] = math.floor(tonumber(s[offset]) * factor + 0.5)
                end
            end
        end
    end
end
function textures.clone(device, source, factor)
    assert(source:GetType() == 3, 'Stage-0 resource is not a 2D texture')
    local src = ffi.cast('IDirect3DTexture8*', source)
    local hr, desc = src:GetLevelDesc(0)
    check(hr, 'Read texture description')
    local levels = tonumber(src:GetLevelCount())
    assert(levels > 0 and levels <= 32, 'Invalid texture mip count')
    local result, copy = device:CreateTexture(desc.Width, desc.Height, levels, 0, desc.Format, ffi.C.D3DPOOL_MANAGED)
    check(result, 'Create texture copy')
    assert(copy ~= nil, 'No texture copy returned')
    local source_locked, copy_locked, current = false, false, 0
    local ok, err = pcall(function()
        for level = 0, levels - 1 do
            current = level
            local info_hr, info = src:GetLevelDesc(level)
            check(info_hr, 'Read texture mip description')
            local read_hr, read = src:LockRect(level, nil, 16) -- D3DLOCK_READONLY
            check(read_hr, 'Read-lock original texture')
            source_locked = true
            local write_hr, write = copy:LockRect(level, nil, 0)
            check(write_hr, 'Write-lock texture copy')
            copy_locked = true
            textures.darken_rows(tonumber(info.Format), tonumber(info.Width), tonumber(info.Height),
                read.pBits, tonumber(read.Pitch), write.pBits, tonumber(write.Pitch), factor)
            check(copy:UnlockRect(level), 'Unlock texture copy')
            copy_locked = false
            check(src:UnlockRect(level), 'Unlock source texture')
            source_locked = false
        end
    end)
    if copy_locked then pcall(function() copy:UnlockRect(current) end) end
    if source_locked then pcall(function() src:UnlockRect(current) end) end
    if not ok then
        copy:Release()
        error(err)
    end
    return copy
end
return textures
