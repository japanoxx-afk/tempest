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
local function getLocalPlayerController()
    -- UEHelpers.GetPlayerController selects IsPlayerController(), which is also
    -- true for Tempest's BP_BotPlayerController_Skirmish_C. Native console Exec
    -- needs the ULocalPlayer attached to the human controller, never an AI.
    for _, controller in ipairs(FindAllOf('PlayerController') or {}) do
        if valid(controller) then
            local player = member(controller, 'Player')
            if valid(player) and player:IsA('/Script/Engine.LocalPlayer') then
                return controller
            end
        end
    end
    return nil
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
    lib:ExecuteConsoleCommand(pc, cmd, pc)
    -- This UFunction returns void: dispatch has no success acknowledgement.
    return 'Kismet dispatch returned; engine success unknown'
end
local function ensureReplayDriver()
    local engine = UE.GetEngine()
    assert(valid(engine), 'Engine instance unavailable')
    local definitions = engine.NetDriverDefinitions
    local found = false
    definitions:ForEach(function(_, entry)
        if entry:get().DefName:ToString() == 'DemoNetDriver' then found = true end
    end)
    if found then return end
    -- Pinned UE4SS LuaTArray.cpp grows on indexed assignment, and
    -- LuaUObject.cpp push_structproperty accepts a table for struct fields.
    local count = #definitions
    definitions[count + 1] = {
        DefName = FName('DemoNetDriver'),
        DriverClassName = FName('/Script/Engine.DemoNetDriver'),
        DriverClassNameFallback = FName('/Script/Engine.DemoNetDriver')
    }
    assert(#definitions == count + 1 and definitions[count + 1].DefName:ToString() == 'DemoNetDriver',
        'Replay driver registration failed')
    status('replay_driver_registered', 'Added DemoNetDriver; existing network drivers preserved')
end
local spectatorClass
local viewerStopped, travelling = false, false
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
        if viewerStopped then return end
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
-- Reuse a stable game-thread timer. Creating Lua coroutine callbacks from an
-- async loop every 33 ms stresses UE4SS's shared Lua registry/collector.
local function gameLoop(interval, callback)
    local handle
    handle = LoopInGameThreadWithDelay(interval,function()
        local stop = callback()
        if stop then CancelDelayedAction(handle) end
        return stop
    end)
end
local worldKey, recordingWorld, startedAt, playSent, prepared
local viewerInitialized = false
local viewerActors = {}
local cameraIndex = 1
local followTarget
local inputController
local configuredWidgets = {}
local viewerControllerName
local function stopViewer(reason)
    if viewerStopped then return end
    viewerStopped = true
    followTarget = nil
    configuredWidgets = {}
    status('viewer_stopped',reason)
end
if mode == 'play' then
    RegisterLoadMapPreHook(function()
        travelling = true
        followTarget = nil
        if viewerInitialized then
            stopViewer('Replay world is leaving; viewer callbacks disabled before teardown')
        end
    end)
    RegisterLoadMapPostHook(function() travelling = false end)
    RegisterEndPlayPreHook(function(context, reason)
        if not viewerInitialized or viewerStopped then return end
        local why = reason:get()
        if why == 1 or why == 4 then
            stopViewer('Replay EndPlay transition; viewer callbacks disabled before teardown')
        else
            local actor = context:get()
            if valid(actor) and actor:GetFullName() == viewerControllerName then
                stopViewer('Replay controller EndPlay; viewer callbacks disabled before teardown')
            end
        end
    end)
end
local function liveWidgets(className, action)
    for _, widget in ipairs(FindAllOf(className) or {}) do
        if valid(widget) and widget:GetFullName():find('/Engine/Transient',1,true) then action(widget) end
    end
end
local function configureViewer(pc)
    pc.bShowMouseCursor = true
    pc.bEnableClickEvents = true
    pc.bEnableMouseOverEvents = true
    pc.bCanSelectEnemy = true
    pc.bCanClearSelection = true

    local input = StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary')
    if valid(input) and inputController ~= pc:GetFullName() then
        input:SetInputMode_GameAndUIEx(pc,nil,0,false,false)
        inputController = pc:GetFullName()
    end
    liveWidgets('TedThirdPartySpectatorHud',function(widget)
        local name = widget:GetFullName()
        if configuredWidgets[name] then return end
        local slot = widget.Box_StatsOverview.Slot
        slot:SetAnchors({Minimum={X=0,Y=0},Maximum={X=0,Y=0}})
        slot:SetAlignment({X=0,Y=0})
        slot:SetPosition({X=16,Y=90})
        configuredWidgets[name] = true
    end)
    liveWidgets('TedMinimapWidget',function(widget)
        local name = widget:GetFullName()
        if configuredWidgets[name] then return end
        widget.bIgnoreMinimapRequirements = true
        widget:SetMiniMapStateFlag(0,true) -- Enabled
        widget:SetMiniMapStateFlag(1,true) -- Eligible
        widget:SetDrawFogOfWar(false)
        widget:SetDrawTerrain(true)
        widget:SetDrawUnits(true)
        widget:SetDrawStructures(true)
        widget:SetDrawResources(true)
        widget:OnMinimapStateChanged(true)
        configuredWidgets[name] = true
    end)
end
if mode == 'play' then
    local function bind(key, action)
        RegisterKeyBind(key, function()
            ExecuteInGameThread(function()
                if viewerStopped or travelling then return end
                local ok, err = pcall(function()
                    local subsystem = FindFirstOf('ReplaySubsystem')
                    if not valid(subsystem) or not subsystem:IsPlaying() then return end
                    local pc = getLocalPlayerController()
                    if not valid(pc) then return end
                    if not valid(pc.Pawn) then return end
                    action(pc,pc.Pawn)
                end)
                if not ok then status('viewer_control_error',tostring(err)) end
            end)
        end)
    end
    local function move(pc, pawn, location)
        followTarget = nil
        pawn:K2_SetActorLocation(location,false,{},true)
        pawn.PlayerCameraComponent:InterpolateCameraToLocation(location,0.5,1.0,0.5,0.0,false,false,1.0,false)
        pc:SetViewTargetWithBlend(pawn,0.0,0,0.0,false)
    end
    bind(Key.F6,function(pc,pawn)
        local bases = {}
        for _, actor in ipairs(FindAllOf('TedStructureBase') or {}) do
            local name = actor:GetFullName()
            if name:find('ConstructionYard_C_') and not name:find('Conformation') and not name:find('Ghost') and actor:IsAlive() then bases[#bases+1]=actor end
        end
        table.sort(bases,function(a,b) return a:GetOwningPlayerID()<b:GetOwningPlayerID() end)
        if #bases == 0 then return end
        cameraIndex = cameraIndex % #bases + 1
        move(pc,pawn,bases[cameraIndex]:K2_GetActorLocation())
        status('viewer_camera', 'Focused recorded player '..bases[cameraIndex]:GetOwningPlayerID())
    end)
    bind(Key.I,function()
        liveWidgets('TedThirdPartySpectatorHud',function(widget) widget:SingularStatShow_ButtonClick() end)
    end)
    bind(Key.C,function(pc)
        local selected = pc:GetSelectedPawns()
        local target = selected and selected[1]
        -- UE4SS returns selected array entries as RemoteUnrealParam wrappers.
        local unwrapped,value = pcall(function() return target:get() end)
        if unwrapped then target=value end
        if valid(target) and target:IsAlive() and target ~= followTarget then
            followTarget = target
            status('viewer_tracking',target:GetFullName())
        else
            followTarget = nil
            status('viewer_tracking','Camera tracking off')
        end
    end)
    bind(Key.F8,function(pc) command(pc,'demopause') end)
    local inputPending, inputErrors, mouseWasDown = false, 0, false
    gameLoop(33,function()
        if viewerStopped then return true end
        if travelling or inputPending then return false end
        inputPending = true
        local function tick()
            if viewerStopped or travelling then inputPending=false; return end
            local ok,err = pcall(function()
                local subsystem = FindFirstOf('ReplaySubsystem')
                if not valid(subsystem) or not subsystem:IsPlaying() then followTarget=nil; return end
                local pc = getLocalPlayerController()
                if not valid(pc) or not valid(pc.Pawn) then followTarget=nil; return end
                local down = pc:IsInputKeyDown({KeyName=FName('LeftMouseButton')})
                if down and not mouseWasDown then followTarget = nil end
                mouseWasDown = down
                local x,y,sx,sy = {},{},{},{}
                if not pc:GetMousePosition(x,y) then return end
                pc:GetViewportSize(sx,sy)
                local mx,my,width,height = x.LocationX or x.locationX,y.LocationY or y.locationY,sx.SizeX,sy.SizeY
                if not mx or not my or not width or not height or mx<0 or my<0 or mx>width or my>height then return end
                local dx,dy = 0,0
                if mx<24 then dy=200 elseif mx>width-24 then dy=-200 end
                if my<24 then dx=-200 elseif my>height-24 then dx=200 end
                local position
                if dx~=0 or dy~=0 then
                    followTarget = nil
                    local p=pc.Pawn:K2_GetActorLocation()
                    position={X=p.X+dx,Y=p.Y+dy,Z=p.Z}
                elseif valid(followTarget) then
                    if followTarget:IsAlive() then position=followTarget:K2_GetActorLocation() else followTarget=nil end
                end
                if position then
                    pc.Pawn:K2_SetActorLocation(position,false,{},true)
                end
            end)
            inputPending = false
            if not ok then inputErrors=inputErrors+1; status('viewer_control_error',tostring(err)) end
        end
        tick()
        return inputErrors>=3
    end)
end
local recordingIndex = 0
local recordingRequestedAt, recordingName, recordingVerified, recordingFailed
local waitingWorld, waitingDetail, waitingNotice, attemptedWorld
local pending = false
local errors = 0
gameLoop(1000, function()
    if viewerStopped then return true end
    if travelling or pending then return false end
    pending = true
    local function tick()
        if viewerStopped or travelling then pending=false; return end
        local ok, err = pcall(function()
            if mode == 'play' and viewerInitialized then
                local subsystem = FindFirstOf('ReplaySubsystem')
                if not valid(subsystem) or not subsystem:IsPlaying() then
                    stopViewer('Replay playback ended; viewer callbacks disabled')
                    return
                end
            end
            local pc = getLocalPlayerController()
            if not valid(pc) then return end
            local control = read(home .. 'control.txt')
            if control then
                os.remove(home .. 'control.txt')
                control = control:gsub('\r\n','\n')
                if control == session .. '\nstop\n' then
                    command(pc,'demostop')
                    status('stop_requested','Requested replay/recording stop')
                    return
                end
            end
            local world = pc:GetWorld()
            if not valid(world) then return end
            local key = world:GetFullName()
            if key ~= worldKey then
                local missed = mode == 'record' and waitingWorld ~= nil and waitingWorld == worldKey and attemptedWorld ~= worldKey
                local missedDetail = waitingDetail
                if recordingWorld then
                    if recordingFailed or not recordingVerified then
                        status('record_failed', (recordingName or '') .. '; match left without an active recording driver; no recording success')
                    else
                        status('record_session_left', (recordingName or '') .. '; driver verified=true; validate replay file')
                    end
                end
                worldKey = key; startedAt = os.time(); diagnostics()
                if not recordingWorld then status('world_ready', key) end
                recordingWorld = nil
                waitingWorld, waitingDetail, waitingNotice, attemptedWorld = nil, nil, nil, nil
                if missed then status('record_not_started','Match left without a recording request; ' .. (missedDetail or 'see recording-state.txt')) end
            end
            if mode == 'probe' then status('probe_ready', key); return end
            local gs = world.GameState
            if mode == 'play' then
                local snapshot = {'session=' .. session, 'world=' .. key, 'controller=' .. pc:GetFullName()}
                local function inspect(label, getter)
                    local ok, value = pcall(getter)
                    snapshot[#snapshot+1] = label .. '=' .. (ok and tostring(value) or ('ERROR ' .. tostring(value)))
                end
                inspect('controller_class', function() return pc:GetClass():GetFullName() end)
                inspect('game_state', function() return valid(gs) and gs:GetFullName() or 'none' end)
                inspect('driver', function() local d=member(world,'DemoNetDriver');return valid(d) and d:GetFullName() or 'none' end)
                inspect('hud', function() local h=pc:GetHUD();return valid(h) and h:GetFullName() or 'none' end)
                inspect('hud_spectator', function() local h=pc:GetHUD();return valid(h) and h:IsSpectatorModeActive() or false end)
                inspect('pawn', function() local p=pc.Pawn;return valid(p) and p:GetFullName() or 'none' end)
                inspect('spectator_pawn', function() local p=pc:GetSpectatorPawn();return valid(p) and p:GetFullName() or 'none' end)
                inspect('player_state', function() local p=pc.PlayerState;return valid(p) and p:GetFullName() or 'none' end)
                inspect('game_mode_class', function() return gs.GameModeClass:GetFullName() end)
                inspect('configured_hud_class', function() return gs.GameModeClass:GetCDO().HUDClass:GetFullName() end)
                inspect('configured_spectator_class', function() return gs.SpectatorClass:GetFullName() end)
                inspect('replay_playing', function() return FindFirstOf('ReplaySubsystem'):IsPlaying() end)
                inspect('replay_time', function() return FindFirstOf('ReplaySubsystem'):GetReplayCurrentTime() end)
                inspect('pauser', function() local p=world:K2_GetWorldSettings().PauserPlayerState;return valid(p) and p:GetFullName() or 'none' end)
                inspect('view_target', function() return pc:GetViewTarget():GetFullName() end)
                inspect('camera_location', function() local v=pc.PlayerCameraManager:GetCameraLocation();return v.X..','..v.Y..','..v.Z end)
                inspect('only_spectator', function() return pc:IsOnlyASpectator() end)
                inspect('spectator_mode', function() return pc:GetHUD():GetActiveSpectatorMode() end)
                inspect('loaded_level_count', function() return #world.Levels end)
                local streamOk,streamErr=pcall(function()
                    world.StreamingLevels:ForEach(function(_,entry)
                        local level=entry:get()
                        snapshot[#snapshot+1]='stream='..level:GetFName():ToString()..' loaded='..tostring(level:IsLevelLoaded())..' visible='..tostring(level:IsLevelVisible())
                    end)
                end)
                if not streamOk then snapshot[#snapshot+1]='stream_error='..tostring(streamErr) end
                write(home .. 'playback.txt', table.concat(snapshot,'\n'))
                if not prepared then prepareSpectator(); prepared = true end
                if not playSent and os.time() - startedAt >= 3 then
                    assert(replay ~= '', 'Replay name missing')
                    ensureReplayDriver(); diagnostics()
                    playSent = true -- never retry dispatch: restarting playback loops would lose progress
                    command(pc, 'demoplay ' .. replay)
                    status('play_requested', replay .. '; not a playback success acknowledgement')
                elseif playSent and valid(gs) and gs:IsA('/Script/Tempest.TedGameState') then
                    local driver = member(world, 'DemoNetDriver')
                    local replaySystem = FindFirstOf('ReplaySubsystem')
                    local isPlaying = valid(driver) and valid(replaySystem) and replaySystem:IsPlaying()
                    if isPlaying and not viewerInitialized then
                        local modeClass = gs.GameModeClass
                        if valid(modeClass) then
                            local hudClass = modeClass:GetCDO().HUDClass
                            if valid(hudClass) then pc:ClientSetHUD(hudClass) end
                        end
                        pc:ClientGotoState(FName('Spectating'))
                        local cameraPawn = pc.Pawn
                        if valid(cameraPawn) then
                            for _, actor in ipairs(FindAllOf('TedPawn') or {}) do
                                if actor:GetFullName():find('ConstructionYard_C_') and not actor:GetFullName():find('Conformation') then
                                    cameraPawn.PlayerCameraComponent:InterpolateCameraToLocation(actor:K2_GetActorLocation(),0.5,1.0,0.5,0.0,false,false,1.0,false)
                                    break
                                end
                            end
                            pc:SetViewTargetWithBlend(cameraPawn,0.0,0,0.0,false)
                        end
                        viewerControllerName = pc:GetFullName()
                        viewerInitialized = true
                        status('viewer_initializing', 'Requested recorded game-mode HUD and spectator camera')
                    end
                    if isPlaying then
                        configureViewer(pc)
                        -- A recorded pause references the original player's state. It can
                        -- otherwise suspend demo delivery forever, including its own unpause.
                        -- Preserve a pause requested by the new local replay spectator.
                        local settings = world:K2_GetWorldSettings()
                        local pauser = settings.PauserPlayerState
                        if valid(pauser) and valid(pc.PlayerState) and pauser:GetFullName() ~= pc.PlayerState:GetFullName() then
                            settings.PauserPlayerState = nil
                        end
                        local fog = FindFirstOf('FogOfWarActor')
                        if valid(fog) then fog:K2_SetTemporarilyUnfog(pc,true) end
                        for _, actor in ipairs(FindAllOf('TedPawn') or {}) do
                            local name = actor:GetFullName()
                            if not name:find('Conformation') and not name:find('Ghost') and not name:find('FoWHighlight') and actor:IsAlive() and not actor:IsInContainer() then
                                actor:K2_SetDefaultVisibility(true,true)
                                actor:K2_OnVisibilityChanged(true)
                                if not viewerActors[name] then
                                    -- Replay-created structures otherwise retain their concealed,
                                    -- underground construction pose. Use the game's visibility init.
                                    if actor:IsA('/Script/Tempest.TedStructureBase') then
                                        actor:SetInitiallyVisible()
                                        actor:ReceiveHandleConstructionVisuals(actor:IsConstructing())
                                    end
                                    viewerActors[name] = true
                                end
                                actor:SetActorHiddenInGame(true)
                                actor:SetActorHiddenInGame(false)
                                actor.bHidden = false
                                local mesh = actor.MeshComp
                                if valid(mesh) then
                                    mesh:SetVisibility(false,false)
                                    mesh:SetHiddenInGame(false,false); mesh:SetVisibility(true,false)
                                    mesh:SetComponentTickEnabled(true)
                                    if mesh:IsA('/Script/Engine.SkeletalMeshComponent') then
                                        mesh.VisibilityBasedAnimTickOption = 0
                                        mesh.bPauseAnims = false
                                    end
                                end
                            end
                        end
                    end
                end
            elseif mode == 'record' then
                local isMatch = valid(gs) and gs:IsA('/Script/Tempest.TedGameState')
                local matchState = ''
                if isMatch then
                    local ok,value = pcall(function() return gs.MatchState:ToString() end)
                    if ok then matchState = value end
                end
                local began,ended = false,false
                if isMatch then
                    began = pc:HasMatchStarted()
                    ended = pc:HasMatchEnded()
                    -- On clients the replicated GameState can be InProgress before
                    -- the local controller acknowledges the match. Never override
                    -- the replicated terminal/lobby states with a stale controller.
                    if matchState == 'InProgress' then began=true;ended=false
                    elseif matchState == 'WaitingPostMatch' or matchState == 'LeavingMap' or matchState == 'Aborted' then ended=true
                    elseif matchState == 'WaitingToStart' or matchState == 'EnteringMap' then began=false;ended=false end
                end
                local inMatchMap = key:find('/Maps/Multiplayer/',1,true) ~= nil
                if isMatch or inMatchMap then
                    waitingWorld = key
                    waitingDetail = 'state='..matchState..'; started='..tostring(began)..'; ended='..tostring(ended)..'; game_state='..(valid(gs) and gs:GetFullName() or 'none')
                    write(home..'recording-state.txt','session='..session..'\nworld='..key..'\ncontroller='..pc:GetFullName()..'\n'..waitingDetail)
                    if not recordingWorld and attemptedWorld ~= key and os.time()-startedAt>=10 and waitingNotice~=waitingDetail then
                        status('record_waiting','Recording NOT active; '..waitingDetail)
                        waitingNotice=waitingDetail
                    end
                end
                if not isMatch then return end
                if ended and recordingWorld == key then
                    command(pc, 'demostop'); recordingWorld = nil
                    status('stop_requested', 'Match ended; verify final replay file')
                elseif began and not ended and recordingWorld ~= key then
                    -- Tempest rebuilds NetDriverDefinitions on travel. Register
                    -- in the match world immediately before issuing demorec.
                    ensureReplayDriver(); diagnostics()
                    recordingIndex = recordingIndex + 1
                    local name = 'Tempest_' .. os.date('%Y%m%d_%H%M%S') .. '_' .. session:sub(1,8) .. '_' .. recordingIndex
                    local output = command(pc, 'demorec ' .. name)
                    attemptedWorld = key
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
    end
    tick()
    return errors >= 3 -- fail closed rather than repeatedly issuing incompatible calls
end)
