addon.name = 'dim'
addon.author = 'sbn'
addon.version = '1.15'
addon.desc = 'Automatic daytime glare reduction for Valkurm Dunes.'
addon.commands = { '/dim' }

require('common')
local ffi = require('ffi')
local d3d = require('d3d8')
local texture = require('dim_texture')
local fingerprints = require('dim_materials')

local ZONE = 103
local STRENGTH = {
    [6] = 10, [7] = 20, [8] = 30, [9] = 40,
    [10] = 50, [11] = 50, [12] = 50, [13] = 50,
    [14] = 30, [15] = 20, [16] = 10,
}
local events = { 'd3d_dp', 'd3d_dip', 'd3d_dpup', 'd3d_dipup' }
local accepted, dimensions = {}, {}
for _, identity in ipairs(fingerprints) do
    accepted[identity] = true
    dimensions[identity:match('^([^:]+:%d+):')] = true
end
local state = {
    enabled = true,
    active = false,
    hooked = false,
    rendering = false,
    zone = 0,
    hour = nil,
    percent = 0,
    fault = nil,
    device = nil,
}
local cache, cache_count = {}, 0
local clock

local function check(hr, operation)
    if hr ~= 0 then error(operation .. ': ' .. tostring(hr)) end
end
local function release_cache()
    for _, entry in pairs(cache) do
        if entry.copy then entry.copy:Release() end
        entry.source:Release()
    end
    cache, cache_count = {}, 0
end
local function stop()
    state.active = false
    if state.hooked then
        for _, event in ipairs(events) do
            ashita.events.unregister(event, 'dim_' .. event)
        end
        state.hooked = false
    end
    release_cache()
end

-- Keep the source alive while its address is cached.
local function get_copy(device)
    local hr, source = device:GetTexture(0)
    check(hr, 'GetTexture')
    if source == nil then return nil end
    local key = tonumber(ffi.cast('uintptr_t', source))
    local entry = cache[key]
    if entry then
        source:Release()
        return entry.copy
    end
    local ok, copy, eligible = pcall(function()
        if source:GetType() ~= 3 then return nil, false end
        local original = ffi.cast('IDirect3DTexture8*', source)
        local result, desc = original:GetLevelDesc(0)
        check(result, 'GetLevelDesc')
        local size = string.format('%dx%d:%d', tonumber(desc.Width), tonumber(desc.Height), tonumber(desc.Format))
        if not dimensions[size] then return nil, false end
        local identity = texture.fingerprint(source)
        if not identity or not accepted[identity] then return nil, true end
        return texture.clone(device, source, 1 - state.percent / 100), true
    end)
    if not ok then
        source:Release()
        error(copy)
    end
    if not eligible then
        source:Release()
        return nil
    end
    if cache_count >= 512 then release_cache() end
    cache[key] = { source = source, copy = copy }
    cache_count = cache_count + 1
    return copy
end

local function render(kind, e)
    if not state.active or state.rendering or e.blocked then return end
    local device = d3d.get_device()
    if device == nil then return end
    local copy = get_copy(device)
    if not copy then return end
    local hr, token = device:CreateStateBlock(ffi.C.D3DSBT_ALL)
    check(hr, 'CreateStateBlock')
    if token == nil then error('No render state token') end
    state.rendering = true
    local ok, err = pcall(function()
        check(device:SetTexture(0, ffi.cast('IDirect3DBaseTexture8*', copy)), 'SetTexture')
        local result
        if kind == 'd3d_dp' then
            result = device:DrawPrimitive(e.primitive_type, e.start_vertex, e.primitive_count)
        elseif kind == 'd3d_dip' then
            result = device:DrawIndexedPrimitive(e.primitive_type, e.min_index,
                e.num_vertices, e.start_index, e.primitive_count)
        elseif kind == 'd3d_dpup' then
            result = device:DrawPrimitiveUP(e.primitive_type, e.primitive_count,
                e.vertex_stream_zero_data, e.vertex_stream_zero_stride)
        else
            result = device:DrawIndexedPrimitiveUP(e.primitive_type, e.min_vertex_index,
                e.num_vertex_indices, e.primitive_count, e.index_data, e.index_data_format,
                e.vertex_stream_zero_data, e.vertex_stream_zero_stride)
        end
        check(result, 'Draw')
        e.blocked = true
    end)
    local restored, restore_hr = pcall(function() return device:ApplyStateBlock(token) end)
    local deleted, delete_hr = pcall(function() return device:DeleteStateBlock(token) end)
    state.rendering = false
    if not restored or restore_hr ~= 0 then error('Restore render state: ' .. tostring(restore_hr)) end
    if not deleted or delete_hr ~= 0 then error('Release render state: ' .. tostring(delete_hr)) end
    if not ok then error(err) end
end

local function attach()
    if state.hooked then return end
    for _, event in ipairs(events) do
        local kind = event
        ashita.events.register(kind, 'dim_' .. kind, function(e)
            local ok, err = pcall(render, kind, e)
            if not ok then
                state.active = false
                state.fault = tostring(err)
            end
        end)
    end
    state.hooked = true
end

local function load_clock()
    local ok, module = pcall(require, 'ffxi.time')
    if ok and type(module) == 'table' and type(module.get_game_hours) == 'function' then
        clock = module
    end
end

local function update()
    local zone_ok, zone = pcall(function()
        return AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0)
    end)
    local hour_ok, hour = false, nil
    if clock then hour_ok, hour = pcall(clock.get_game_hours) end
    if not hour_ok or type(hour) ~= 'number' or hour < 0 or hour >= 24 then hour = nil end
    if not zone_ok then zone = 0 end
    local device = AshitaCore:GetDirect3DDevice()
    local percent = 0
    if state.enabled and not state.fault and zone == ZONE and hour ~= nil and device ~= nil and device ~= 0 then
        percent = STRENGTH[math.floor(hour)] or 0
    end
    if zone ~= state.zone or device ~= state.device or percent ~= state.percent then stop() end
    state.zone, state.hour, state.device, state.percent = zone or 0, hour, device, percent
    if percent > 0 then
        state.active = true
        attach()
    elseif state.hooked then
        stop()
    end
    if state.fault then stop() end
end

ashita.events.register('load', 'dim_load', function()
    load_clock()
    update()
end)
ashita.events.register('d3d_present', 'dim_present', update)
ashita.events.register('unload', 'dim_unload', stop)
ashita.events.register('command', 'dim_command', function(e)
    local args = e.command:args()
    if not args[1] or args[1]:lower() ~= '/dim' then return end
    e.blocked = true
    local command = args[2] and args[2]:lower() or (state.enabled and 'off' or 'on')
    if command == 'on' then
        stop()
        state.enabled = true
        state.fault = nil
        if not clock then load_clock() end
        update()
    elseif command == 'off' then
        state.enabled = false
        stop()
    end
end)
