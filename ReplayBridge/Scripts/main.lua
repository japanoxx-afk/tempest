-- Tempest-specific UE4SS integration prototype. All UE access runs on the game thread.
local home = os.getenv('LOCALAPPDATA') .. '/TempestReplayLauncher/bridge/'
local function read(path)
    local f = io.open(path, 'rb'); if not f then return nil end
    local text = f:read('*a'); f:close(); return text
end
local request = read(home .. 'request.txt')
if not request then return end
request = request:gsub('\r\n', '\n')
local mode, session, expires, replay = request:match('^(%a+)\n([%w_-]+)\n(%d+)\n([%w_-]*)')
if not mode or tonumber(expires) < os.time() or tonumber(expires) > os.time() + 180 then return end
if mode ~= 'probe' and mode ~= 'record' and mode ~= 'play' then return end
os.remove(home .. 'request.txt') -- one launch only; normal Steam launches stay idle
local UE = require('UEHelpers')
local function write(path, text)
    local f = assert(io.open(path .. '.tmp', 'wb')); f:write(text); f:close()
    os.remove(path); assert(os.rename(path .. '.tmp', path))
end
local function status(state, detail)
    write(home .. 'status.txt', table.concat({session, tostring(os.time()), state, ((detail or ''):gsub('[\r\n]', ' '))}, '\n'))
    local history = assert(io.open(home .. 'events.log', 'ab'))
    history:write(table.concat({tostring(os.time()), session, state, ((detail or ''):gsub('[\r\n]', ' '))}, ' ') .. '\n')
    history:close()
    print('[TempestReplay] ' .. state .. ': ' .. (detail or '') .. '\n')
end
local function valid(o) return o ~= nil and o:IsValid() end
local function member(o, key)
    local ok, value = pcall(function() return o[key] end)
    if ok then return value end
end
local function describe(classPath)
    local cls = StaticFindObject(classPath)
    if not valid(cls) then return classPath .. ': NOT LOADED\n' end
    local lines = {classPath}
    cls:ForEachProperty(function(p) lines[#lines+1] = '  property ' .. p:GetFName():ToString() end)
    cls:ForEachFunction(function(fn)
        local names = {}
        fn:ForEachProperty(function(p) names[#names+1] = p:GetFName():ToString() end)
        lines[#lines+1] = '  function ' .. fn:GetFName():ToString() .. '(' .. table.concat(names, ',') .. ')'
    end)
    return table.concat(lines, '\n') .. '\n'
end
local function diagnostics()
    local text = {}
    for _, cls in ipairs({'/Script/Tempest.TedGameState','/Script/Tempest.TedGameModeBase',
        '/Script/Tempest.TedPlayerController','/Script/Tempest.TedPlayerController_Spectator',
        '/Script/Tempest.TedHUD','/Script/Engine.GameInstance','/Script/Engine.World',
        '/Script/Engine.GameState','/Script/Engine.GameModeBase',
        '/Script/Engine.PlayerController','/Script/Engine.KismetSystemLibrary'}) do
        text[#text+1] = describe(cls)
    end
    write(home .. 'reflection.txt', table.concat(text, '\n'))
    local driverLines = {}
    local ok, err = pcall(function()
      local engine = UE.GetEngine()
      if valid(engine) then
        local definitions = member(engine, 'NetDriverDefinitions')
        if definitions then
            definitions:ForEach(function(_, entry)
                local value = entry:get()
                driverLines[#driverLines+1] = value.DefName:ToString() .. ' => ' .. value.DriverClassName:ToString()
            end)
        end
      end
    end)
    if not ok then driverLines[#driverLines+1] = 'Diagnostic unavailable: ' .. tostring(err) end
    write(home .. 'net-drivers.txt', table.concat(driverLines, '\n'))
end
local function command(pc, cmd)
    -- ConsoleCommand is native/non-reflected in this shipping build. Never call
    -- pc:ConsoleCommand from Lua: UE4SS returns an uncallable TrivialObject.
    local lib = StaticFindObject('/Script/Engine.Default__KismetSystemLibrary')
    local fn = StaticFindObject('/Script/Engine.KismetSystemLibrary:ExecuteConsoleCommand')
    assert(valid(lib) and valid(fn), 'Reflected ExecuteConsoleCommand is unavailable; recording unsupported by this bridge')
    local f = assert(io.open(home .. 'commands.log', 'ab'))
    f:write(os.date('%Y-%m-%d %H:%M:%S') .. ' REQUEST ' .. cmd .. '\n'); f:close()
    lib:CallFunction(fn, pc, cmd, pc)
    -- This UFunction returns void: dispatch has no success acknowledgement.
    return 'Kismet dispatch returned; engine success unknown'
end
local spectatorClass
local function setSpectator(gm)
    if valid(gm) and valid(spectatorClass) then
        gm.ReplaySpectatorPlayerControllerClass = spectatorClass
    end
end
local function prepareSpectator()
    spectatorClass = LoadAsset('/Game/Tempest/Blueprints/Core/TedSpectatorController_BP.TedSpectatorController_BP_C')
    assert(valid(spectatorClass), 'Tempest spectator controller asset could not be loaded')
    for _, path in ipairs({'/Script/Engine.GameModeBase','/Script/Engine.GameMode',
        '/Script/Tempest.TedGameModeBase','/Script/Tempest.TedGameMode_MP',
        '/Script/Tempest.TedGameMode_SP'}) do
        local cls = StaticFindObject(path)
        if valid(cls) then setSpectator(cls:GetCDO()) end
    end
    RegisterInitGameStatePostHook(function(context)
        local ok, err = pcall(function()
            local actor = context
            local got, value = pcall(function() return context:get() end)
            if got then actor = value end
            if valid(actor) then setSpectator(actor:GetWorld().AuthorityGameMode) end
        end)
        if not ok then status('spectator_setup_error', tostring(err)) end
    end)
end
status('loaded', mode .. ' bridge loaded; runtime compatibility not yet verified')
local worldKey, recordingWorld, startedAt, playSent, prepared, hudActivated
local recordingIndex = 0
local recordingRequestedAt, recordingName, recordingVerified, recordingFailed
local pending = false
local errors = 0
LoopAsync(1000, function()
    if pending then return false end
    pending = true
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            local pc = UE.GetPlayerController()
            if not valid(pc) then return end
            local world = pc:GetWorld()
            if not valid(world) then return end
            local key = world:GetFullName()
            if key ~= worldKey then
                if recordingWorld then
                    status('record_session_left', (recordingName or '') .. '; driver verified=' .. tostring(recordingVerified == true))
                end
                worldKey = key; startedAt = os.time(); diagnostics()
                if not recordingWorld then status('world_ready', key) end
                recordingWorld = nil
            end
            if mode == 'probe' then status('probe_ready', key); return end
            local gs = world.GameState
            if mode == 'play' then
                if not prepared then prepareSpectator(); prepared = true end
                if not playSent and os.time() - startedAt >= 3 then
                    assert(replay ~= '', 'Replay name missing')
                    playSent = true -- never retry dispatch: restarting playback loops would lose progress
                    command(pc, 'demoplay ' .. replay)
                    status('play_requested', replay .. '; not a playback success acknowledgement')
                elseif playSent and valid(gs) and gs:IsA('/Script/Tempest.TedGameState') then
                    local driver = member(world, 'DemoNetDriver')
                    if valid(driver) and not hudActivated then
                        local hud = pc:GetHUD()
                        local fn = StaticFindObject('/Script/Tempest.TedHUD:ActivateMatchSpectatorUI')
                        if valid(hud) and valid(fn) then
                            local count = 0
                            fn:ForEachProperty(function() count = count + 1 end)
                            assert(count == 0, 'Spectator HUD signature needs an adapter; see reflection.txt')
                            hud:CallFunction(fn)
                            hudActivated = true
                            status('spectator_ui_requested', 'Verify camera, full map, statistics and timeline in game')
                        end
                    end
                end
            elseif mode == 'record' then
                if not valid(gs) or not gs:IsA('/Script/Tempest.TedGameState') then return end
                local began = pc:HasMatchStarted()
                local ended = pc:HasMatchEnded()
                if ended and recordingWorld == key then
                    command(pc, 'demostop'); recordingWorld = nil
                    status('stop_requested', 'Match ended; verify final replay file')
                elseif began and not ended and recordingWorld ~= key then
                    recordingIndex = recordingIndex + 1
                    local name = 'Tempest_' .. os.date('%Y%m%d_%H%M%S') .. '_' .. session:sub(1,8) .. '_' .. recordingIndex
                    local output = command(pc, 'demorec ' .. name)
                    recordingWorld = key
                    recordingRequestedAt = os.time(); recordingName = name
                    recordingVerified = false; recordingFailed = false
                    status('record_requested', name .. '; ' .. output)
                elseif recordingWorld == key and not recordingVerified and not recordingFailed then
                    local driver = member(world, 'DemoNetDriver')
                    if valid(driver) then
                        recordingVerified = true
                        status('record_driver_active', recordingName .. '; driver active; file/playback validation still required')
                    elseif os.time() - recordingRequestedAt >= 8 then
                        recordingFailed = true
                        status('record_failed', recordingName .. '; DemoNetDriver was not created. See commands.log')
                    end
                end
            end
        end)
        pending = false
        if not ok then
            errors = errors + 1
            status('bridge_error', tostring(err))
        end
    end)
    return errors >= 3 -- fail closed rather than repeatedly issuing incompatible calls
end)
