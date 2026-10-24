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
if mode=='play' then write(home..'startup.txt',session..'\nplay') end
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
local movementIO={}
function movementIO:isDead(actor)
    local name=actor:GetFullName()
    if self.visualDeaths and self.visualDeaths[name] then return true end
    if mode=='play' and self.deadFrame and self.deadFrame[name]~=nil then return self.deadFrame[name] end
    local ok,dead=pcall(function() return actor.PawnDeath.bDied end)
    dead=ok and dead==true
    if mode=='play' and self.deadFrame then self.deadFrame[name]=dead end
    return dead
end
function movementIO:isPresentationPawn(actor)
    local name=actor:GetFullName()
    return not name:find('Ghost') and not name:find('FoWHighlight') and
        (not name:find('Conformation') or actor:IsA('/Script/Tempest.TedConformationBase'))
end
do
    local ok,module=pcall(require,'Movement')
    if ok then movementIO.codec=module else status('movement_error','Movement module unavailable: '..tostring(module)) end
end
function movementIO:identity(actor)
    if not self.codec or not valid(actor) or not actor:IsA('/Script/Tempest.TedPawn') then return nil end
    local name=actor:GetFullName()
    if not self:isPresentationPawn(actor) then return nil end
    local component=actor.EcsActor
    if not valid(component) then return nil end
    if not self.aliasReady then
        local cls=StaticFindObject('/Script/NubECS.EcsActorComponent');local supported=false
        if valid(cls) then cls:ForEachProperty(function(p)
            if p:GetFName():ToString()=='EntityHandle' and p:GetStruct():GetFullName()=='ScriptStruct /Script/NubECS.EcsEntityHandle' then supported=true end
        end) end
        assert(supported,'Unsupported ECS EntityHandle layout')
        -- Read-only alias at the reflected property's start, never a fixed process offset.
        -- EntityHandle identifies a track within the recording only. Playback uses pose binding.
        RegisterCustomProperty({Name='TempestReplayEntityKey',Type=PropertyTypes.IntProperty,
            BelongsToClass='/Script/NubECS.EcsActorComponent',OffsetInternal={Property='EntityHandle',RelativeOffset=0}})
        self.aliasReady=true
    end
    local class=actor:GetClass():GetFName():ToString()
    local owner,entity=actor:GetOwningPlayerID(),component.TempestReplayEntityKey
    return self.codec.key(class,owner,entity),class,owner,entity
end
function movementIO:close()
    if self.audio then self.audio:close();self.audio=nil end
    self.audioController=nil
    self.pendingWrecks=nil;self.wreckPresented=nil;self.deadStatusEpoch=nil;self.deadPresentationActors=nil
    self.animationFrames={}
    self.garrisonFrame=nil;self.appliedPoses=nil;self.locomotionCache=nil;self.nativeHealthCache=nil
    self.healthPanel=nil;self.healthBars=nil;self.healthFailed=nil;self.healthHidden=nil;self.healthOffsets=nil
    self.candidates=nil;self.candidateFrame=nil;self.candidateEpoch=nil;self.catalogClasses=nil
    self.retiredResources=nil;self.retiredResourceKeys=nil;self.retiredResourceCursor=nil;self.projectiles=nil;self.projectileActors=nil;self.projectileTime=nil;self.doctrineApplied=nil
    self.actorCache=nil;self.finishedTracks=nil;self.contained=nil;self.containerEpoch=nil;self.watchedPawns=nil;self.pawnKinds=nil;self.deadFrame=nil;self.markerStates=nil;self.neutralMeshes=nil;self.neutralColors=nil;self.garrisonMeshes=nil;self.disabledTicks=nil;self.corpseQueue=nil;self.doctrineSnapshot=nil;self.doctrineSignature=nil;self.doctrineAssets=nil;self.popupCache=nil
    self.viewerDoctrinePopup=nil
    self.maps=nil -- Widgets belong to their HUD; never touch old-world widgets during teardown.
    if self.writer then
        self.writer:close();self.writer=nil
        write(home..'movement-state.txt',session..'\n'..self.name..'\ncompleted\nframes='..(self.frames or 0)..'\nunits='..(self.units or 0))
    end
    if self.reader then self.reader:close();self.reader=nil end
end
function movementIO:resetMarkers()
    -- A minimap panel can replace its canvas when the spectator HUD toggles.
    -- Cached pins then remain valid UObjects but no longer render on that canvas.
    if self.maps then
        for _,pins in pairs(self.maps) do
            for _,pin in pairs(pins) do
                if valid(pin) then pin:RemoveFromParent() end
            end
        end
    end
    self.maps=nil
    self.markerStates=nil
    self.markerTime=nil
end
function movementIO:updateLocomotion(actor,velocity)
    local name=actor:GetFullName()
    self.locomotionCache=self.locomotionCache or {}
    local cached=self.locomotionCache[name]
    if not cached or cached.epoch~=self.cacheTick or not valid(cached.mesh) or (cached.anim and not valid(cached.anim)) then
        local mesh=actor.MeshComp
        cached={epoch=self.cacheTick,mesh=mesh};self.locomotionCache[name]=cached
        if valid(mesh) then
            local anim=mesh:GetAnimInstance()
            if valid(anim) and anim:IsA('/Script/Tempest.TedAnimInstance_Infantry') then
                local definition=actor:GetDefinitionAsset()
                local speed=valid(definition) and definition.MovementSpeed
                if type(speed)=='number' and speed>0 and speed<=10000 then
                    cached.anim=anim;cached.maxSpeed=speed;cached.animName=anim:GetFullName()
                    anim.bUseMultiThreadedAnimationUpdate=false
                    mesh.bEnableUpdateRateOptimizations=false
                end
            end
        end
    end
    local mesh=cached.mesh
    if not valid(mesh) then return end
    self:presentationTick(actor)
    mesh:SetComponentTickEnabled(true)
    local anim=cached.anim
    if not valid(anim) then return end
    if not self.animationHook then
        local path='/Game/Tempest/Blueprints/Animation/ABP_InfantryBase.ABP_InfantryBase_C:BlueprintThreadSafeUpdateAnimation'
        RegisterHook(path,function(context)
            -- This instance uses game-thread animation. Apply after native update,
            -- which otherwise replaces speed with the replay's missing-ECS default.
            local instance=context:get()
            if not valid(instance) or instance.bUseMultiThreadedAnimationUpdate then return end
            local frame=self.animationFrames and self.animationFrames[instance:GetFullName()]
            if not frame then return end
            instance.Speed=frame.speed;instance.MaxSpeed=frame.maxSpeed
            instance.bIsMoving=frame.speed>instance.IsMovingSpeedThreshold
        end)
        self.animationHook=true
    end
    self.animationFrames[cached.animName]={speed=math.sqrt(velocity.X^2+velocity.Y^2),maxSpeed=cached.maxSpeed}
end
function movementIO:record(subsystem,name,actors)
    if not self.codec or self.failed then return end
    if self.name~=name then
        self:close();self.name=name;self.frames=0;self.units=0;self.recordedBuildings={};self.recordedPawns={};self.pendingDeaths={};self.emittedDeaths={}
        local path=os.getenv('LOCALAPPDATA')..'/Tempest/Saved/Demos/'..name..'.movement'
        self.writer=self.codec.writer(path,name)
        status('movement_recording','Local received unit movement companion: '..path)
    end
    local units,seen={},{}
    for _,actor in ipairs(actors) do
        if valid(actor) then self:watchDeath(actor) end
        local structure=valid(actor) and actor:IsA('/Script/Tempest.TedStructureBase') and not actor:IsA('/Script/Tempest.TedConformationBase')
        local constructing=structure and actor:IsConstructing()
        if valid(actor) and not self:isDead(actor) and (actor:IsAlive() or constructing) and not actor:IsInContainer() then
            local key,class,owner,entity=self:identity(actor)
            if key then
                assert(not seen[key],'Duplicate ECS identity; refusing ambiguous movement recording');seen[key]=true
                local p=actor:K2_GetActorLocation();local r=actor:K2_GetActorRotation()
                -- Cached building poses must not retain native struct wrappers.
                local unit={class=class,owner=owner,entity=entity,
                    position={X=p.X,Y=p.Y,Z=p.Z},rotation={Pitch=r.Pitch,Yaw=r.Yaw,Roll=r.Roll}}
                -- Read received attributes only. Never change health/replication
                -- or reveal information the recording client did not receive.
                local ok,hp,maximum=pcall(function()return actor:GetHealth(),actor:GetHealthMax()end)
                if ok and type(hp)=='number' and type(maximum)=='number' and hp==hp and maximum==maximum and maximum>0 and maximum<1e9 and hp>=0 and hp<=maximum then
                    unit.health={current=hp,maximum=maximum}
                end
                if structure then
                    unit.building=constructing and 1 or 2
                    self.recordedBuildings[actor:GetFullName()]=unit
                end
                if actor:IsA('/Script/Tempest.TedConstructionSite') then
                    unit.site={footprint=actor.ActiveFootprintConfig,progress=math.max(0,math.min(1,actor:GetConstructionProgress()))}
                end
                self.recordedPawns[actor:GetFullName()]=unit
                units[#units+1]=unit
            end
        elseif valid(actor) and self.recordedBuildings[actor:GetFullName()] and self:isDead(actor) then
            -- Keep an explicit death sample. Disappearance/fog is not death.
            local unit=self.recordedBuildings[actor:GetFullName()]
            local key=self.codec.key(unit.class,unit.owner,unit.entity)
            if not seen[key] and not self.emittedDeaths[actor:GetFullName()] then unit.building=3;units[#units+1]=unit;seen[key]=true end
        end
        if valid(actor) and self.recordedPawns[actor:GetFullName()] and self:isDead(actor) and not self.emittedDeaths[actor:GetFullName()] then
            self.pendingDeaths[actor:GetFullName()]=self.recordedPawns[actor:GetFullName()]
        end
    end
    for name,unit in pairs(self.pendingDeaths) do
        if not self.emittedDeaths[name] then
        local key=self.codec.key(unit.class,unit.owner,unit.entity)
        unit.dead=true
        if not seen[key] then units[#units+1]=unit;seen[key]=true
        else
            for _,present in ipairs(units) do
                if self.codec.key(present.class,present.owner,present.entity)==key then present.dead=true;break end
            end
        end
        self.emittedDeaths[name]=true
        end
        self.pendingDeaths[name]=nil
    end
    local doctrines={}
    for _,data in ipairs(FindAllOf('TedPlayerData') or {}) do
        if valid(data) then
            local owner=data:GetOwningPlayerState()
            if valid(owner) then
                local id=owner:GetTedPlayerID()
                if type(id)=='number' and id>=0 and id<256 then
                    local assets={}
                    data.ResearchedDoctrines:ForEach(function(_,entry)
                        local asset=entry:get()
                        if valid(asset) then
                            local path=asset:GetFullName():match('^[^ ]+ (.+)$')
                            if self.codec.assetPath(path) then assets[#assets+1]=path end
                        end
                    end)
                    doctrines[id]=assets
                end
            end
        end
    end
    self.writer:frame(subsystem:GetReplayCurrentTime(),units,doctrines)
    self.frames=self.writer.frames;self.units=#units
    if self.frames%10==0 then write(home..'movement-state.txt',session..'\n'..name..'\nrecording\nframes='..self.frames..'\nunits='..self.units) end
end
function movementIO:watchDeath(actor)
    self.deathHooks=self.deathHooks or {};self.deathPresented=self.deathPresented or {}
    if mode=='play' and not self.wreckHook and valid(StaticFindObject('/Script/Tempest.TedVehicle:SpawnWreck')) then
        self.wreckHook=true;self.wreckPresented=self.wreckPresented or {}
        RegisterHook('/Script/Tempest.TedVehicle:SpawnWreck',function(context)
            if viewerStopped or travelling or not self.wreckPresented then return end
            local pawn=context:get()
            if valid(pawn) then self.wreckPresented[pawn:GetFullName()]=true end
        end)
    end
    local function install(path)
        if self.deathHooks[path] then return end
        self.deathHooks[path]=true
        local ok,err=pcall(RegisterHook,path,function(context)
            local pawn=context:get();if not valid(pawn) then return end
            local name=pawn:GetFullName()
            if mode=='record' and self.recordedPawns and self.recordedPawns[name] then
                self.pendingDeaths[name]=self.recordedPawns[name]
            elseif mode=='play' then self.deathPresented[name]=true end
        end)
        if not ok then status('death_hook_error',path..': '..tostring(err)) end
    end
    install('/Script/Tempest.TedPawn:ReceiveOnDeath')
    local cls=actor:GetClass()
    if self.deathHooks[cls:GetFullName()] then return end
    self.deathHooks[cls:GetFullName()]=true
    cls:ForEachFunction(function(fn)
        if fn:GetFName():ToString()=='ReceiveOnDeath' then
            install(cls:GetFullName():gsub('^BlueprintGeneratedClass ',''):gsub('^Class ','')..':ReceiveOnDeath')
        end
    end)
end
function movementIO:retireDeadStatus()
    if mode~='play' or self.deadStatusEpoch==self.cacheTick then return end
    self.deadStatusEpoch=self.cacheTick
    if not self.visualDeaths or not next(self.visualDeaths) then return end
    for name,actor in pairs(self.deadPresentationActors or {}) do
        if not valid(actor) then self.deadPresentationActors[name]=nil
        else
            -- Presentation policy only. Never remove gameplay effects/abilities.
            actor.bDisableHUDBars=true;actor.bDisableStatusEffects=true
            actor.bCanEverBeSelected=false
            local decal=member(actor,'SelectionDecal')
            if valid(decal) then decal:SetHiddenInGame(true,false);decal:SetVisibility(false,false) end
        end
    end
    for _,cue in ipairs(self:cachedActors('GameplayCueNotify_Actor')) do
        if valid(cue) then
            -- Resolve current ownership every time: cues can be pooled and
            -- transferred to living targets. Never retain a quarantine for them.
            local owner=cue:GetOwner()
            if valid(owner) and self.visualDeaths[owner:GetFullName()] then
                local tag=cue.GameplayCueTag.TagName:ToString()
                if tag:find('.Status.',1,true) then
                    cue:K2_EndGameplayCue() -- native recycle path cancels effects/timers
                end
            end
        end
    end
end
function movementIO:restoreWrecks(time)
    if mode~='play' then return end
    local existing
    for name,entry in pairs(self.pendingWrecks or {}) do
        if time>=entry.at then
            self.pendingWrecks[name]=nil
            if valid(entry.actor) and not (self.wreckPresented and self.wreckPresented[name]) then
                -- Direct native C++ calls can bypass a reflected function hook.
                -- Respect already spawned wrecks with an explicit pawn owner;
                -- do not guess ownership from distance in crowded battles.
                if not existing then
                    existing={}
                    for _,wreck in ipairs(FindAllOf('TedVehicleWreckActor') or {}) do
                        if valid(wreck) then
                            local owner=wreck:GetOwner()
                            if valid(owner) then existing[owner:GetFullName()]=true end
                        end
                    end
                end
                self.wreckPresented=self.wreckPresented or {};self.wreckPresented[name]=true
                -- Dedicated cosmetic native function. Do not invoke Die,
                -- OnRep_PawnDeath, NetMulticast_Died, damage or attack paths.
                if not existing[name] then entry.actor:SpawnWreck() end
            end
        end
    end
end
-- Replay-only caches expire independently of the demo clock (which can pause).
function movementIO:cachedActors(className)
    self.actorCache=self.actorCache or {}
    local entry=self.actorCache[className]
    if not entry or entry.tick~=(self.cacheTick or 0) then
        entry={tick=self.cacheTick or 0,items=FindAllOf(className) or {}}
        self.actorCache[className]=entry
    end
    return entry.items
end
function movementIO:retireScene(actor)
    if mode~='play' then return end
    local cls=StaticFindObject('/Script/Engine.SceneComponent')
    if not valid(cls) then return end
    local function stop(owner)
        local ok,components=pcall(function()return owner:K2_GetComponentsByClass(cls)end)
        if not ok then return end
        for _,entry in ipairs(components) do
            local got,c=pcall(function()return entry:get()end);if not got then c=entry end
            if valid(c) then
                local niagara=c:IsA('/Script/Niagara.NiagaraComponent')
                local audio=c:IsA('/Script/Engine.AudioComponent')
                local fx=c:IsA('/Script/Engine.FXSystemComponent')
                c:SetHiddenInGame(true,false);c:SetVisibility(false,false)
                c:SetComponentTickEnabled(false)
                if fx then
                    c:Deactivate()
                    -- Niagara can remain logically active while draining. A
                    -- retained demo corpse must not keep its shared simulation
                    -- running after the original destruction grace period.
                    if niagara and valid(c) then c:SetPaused(true);c:SetRenderingEnabled(false) end
                elseif audio then c:SetVolumeMultiplier(0);c:Stop() end
                local kind=niagara and 'niagara' or (audio and 'audio')
                if kind and valid(c) then
                    self.retiredResources=self.retiredResources or {};self.retiredResourceKeys=self.retiredResourceKeys or {}
                    local key=c:GetFullName()
                    if not self.retiredResourceKeys[key] then
                        self.retiredResourceKeys[key]=true
                        self.retiredResources[#self.retiredResources+1]={key=key,component=c,owner=actor:GetFullName(),kind=kind}
                    end
                end
            end
        end
    end
    stop(actor)
    -- Separate cue actors may be pooled/re-attached to living targets. Their
    -- lifecycle is independent; quarantine only components owned by this pawn.
end
function movementIO:maintainRetiredResources(limit)
    if mode~='play' then return end
    local resources=self.retiredResources or {}
    for _=1,math.min(limit or 16,#resources) do
        local i=self.retiredResourceCursor or 1;if i>#resources then i=1 end
        local e=resources[i];local c=e.component
        local owner
        if valid(c) then owner=c:GetOwner() end
        if not valid(owner) or owner:GetFullName()~=e.owner then
            self.retiredResourceKeys[e.key]=nil;table.remove(resources,i)
        else
            -- Demo/ECS updates can restart a stopped movement loop or unpause
            -- Niagara after retirement. Keep work bounded instead of rescanning
            -- every corpse/component each frame.
            if e.kind=='audio' then
                if c.VolumeMultiplier~=0 then c:SetVolumeMultiplier(0) end
                if c:IsPlaying() then c:Stop() end
            elseif not c:IsPaused() then c:Deactivate();if valid(c) then c:SetPaused(true);c:SetRenderingEnabled(false);c:SetComponentTickEnabled(false) end end
            i=i+1
        end
        self.retiredResourceCursor=i
    end
end
function movementIO:retireCorpses(time)
    for name,entry in pairs(self.corpseQueue or {}) do
        local actor=entry.actor
        if not valid(actor) then self.corpseQueue[name]=nil
        elseif time>=entry.untilTime then
            -- Keep the demo actor/net GUID alive. Destroying replicated actors
            -- makes later demo property/weapon references unsafe.
            actor:SetActorEnableCollision(false)
            actor:SetActorHiddenInGame(true)
            local mesh=actor.MeshComp
            if valid(mesh) then mesh:SetHiddenInGame(true,true);mesh:SetComponentTickEnabled(false) end
            self:retireScene(actor) -- after the existing native death-presentation grace period
            actor:SetActorTickEnabled(false)
            self.corpseQueue[name]=nil
            if self.garrisonMeshes then self.garrisonMeshes[name]=nil end
            self.retiredCorpses=(self.retiredCorpses or 0)+1
        end
    end
end
function movementIO:presentationTick(actor)
    -- A client demo may spawn pawns without their native combat attribute set.
    -- Their primary tick can then enter native weapon evaluation with null data.
    -- Mesh/timeline components retain their own ticks for visual playback.
    self.disabledTicks=self.disabledTicks or {}
    local name=actor:GetFullName()
    if not self.disabledTicks[name] and not valid(member(actor,'DefaultAttributeSet')) then
        actor:SetActorTickEnabled(false);self.disabledTicks[name]=true
    end
end
function movementIO:neutralMesh(actor)
    if not actor:IsA('/Script/Tempest.TedConformationBase') or self:isDead(actor) then return end
    local mesh=actor.MeshComp
    local deployed=member(actor,'Mesh_Deployed')
    if not valid(mesh) or not valid(deployed) then return end
    if mesh:IsA('/Script/Engine.SkeletalMeshComponent') and deployed:IsA('/Script/Engine.SkeletalMesh') then
        if not valid(mesh.SkeletalMesh) then mesh:SetSkeletalMesh(deployed,true) end
    elseif mesh:IsA('/Script/Engine.StaticMeshComponent') and deployed:IsA('/Script/Engine.StaticMesh') then
        if not valid(mesh.StaticMesh) then mesh:SetStaticMesh(deployed) end
    elseif deployed:IsA('/Script/Engine.StaticMesh') then
        -- Conformations in this client demo can have an empty skeletal proxy,
        -- while their healthy model is a StaticMesh asset. Keep the game's
        -- proxy intact and add a collision-free presentation component.
        self.neutralMeshes=self.neutralMeshes or {}
        local name=actor:GetFullName();local component=self.neutralMeshes[name]
        if not valid(component) then
            local cls=StaticFindObject('/Script/Engine.StaticMeshComponent')
            if not valid(cls) then return end
            component=actor:AddComponentByClass(cls,false,{
                Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}},false)
            if not valid(component) then return end
            component:SetStaticMesh(deployed);component:SetCollisionEnabled(0)
            component:SetHiddenInGame(false,false);component:SetVisibility(true,false)
            self.neutralMeshes[name]=component
        end
        component:SetHiddenInGame(false,true);component:SetVisibility(true,true)
        self:neutralColor(actor,component)
    end
end
function movementIO:neutralColor(actor,component)
    if mode~='play' then return end
    local owner=actor:GetOwningPlayerID()
    self.neutralColors=self.neutralColors or {}
    local name=actor:GetFullName();local state=self.neutralColors[name]
    if state and state.owner==owner and state.component==component then return end
    local utils=StaticFindObject('/Script/Tempest.Default__TedUtils')
    local colors=StaticFindObject('/Script/RTSColor.Default__RTSColorSubsystem')
    if not valid(utils) or not valid(colors) then return end
    local primary,secondary={R=0.65,G=0.65,B=0.65,A=1},{R=0.65,G=0.65,B=0.65,A=1}
    if owner>=0 and owner<8 then
        local preset=utils:GetPlayerColorPreset(actor,owner)
        if not preset then return end
        primary,secondary=preset.PrimaryColor,preset.SecondaryColor
    end
    local mids=state and state.mids or {}
    for i=0,component:GetNumMaterials()-1 do
        local mid=mids[i]
        if not valid(mid) then mid=component:CreateDynamicMaterialInstance(i,nil,FName('None'));mids[i]=mid end
        if valid(mid) then
            mid:SetVectorParameterValue(colors.PrimaryPlayerColorParamName,primary)
            mid:SetVectorParameterValue(colors.SecondaryPlayerColorParamName,secondary)
        end
    end
    self.neutralColors[name]={owner=owner,component=component,mids=mids}
end
function movementIO:isGarrisoned(actor)
    if mode~='play' then return false end
    local name=actor:GetFullName()
    if self.garrisonFrame and self.garrisonFrame[name]~=nil then return self.garrisonFrame[name] end
    local contained=self.contained and self.contained[name]~=nil or false
    if not contained and actor:IsInContainer() then
        local ok,owner=pcall(function() return actor:GetPawnContainerOwner() end)
        contained=ok and valid(owner) and (owner:IsA('/Script/Tempest.TedConformationBase') or owner:IsA('/Script/Tempest.TedUnitBase')) or false
    end
    -- Production buildings can retain a stale container flag in client demos.
    -- A real bunker/transport owner is different: never pull its occupant out
    -- to a companion pose or make it visible to the spectator/minimap.
    if self.garrisonFrame then self.garrisonFrame[name]=contained end
    return contained
end
function movementIO:refreshContainers()
    if mode~='play' or self.containerEpoch==self.cacheTick then return end
    self.containerEpoch=self.cacheTick;self.contained={}
    for _,component in ipairs(self:cachedActors('TedPawnContainerComponent')) do
        if valid(component) then
            local owner=component:GetOwner()
            -- Factories also have container components. Only actual garrisons
            -- and transports may override a missing pawn-side replicated flag.
            if valid(owner) and (owner:IsA('/Script/Tempest.TedConformationBase') or owner:IsA('/Script/Tempest.TedUnitBase')) then
                for _,entry in ipairs(component:GetStoredPawns()) do
                    local ok,pawn=pcall(function()return entry:get()end);if not ok then pawn=entry end
                    if valid(pawn) then self.contained[pawn:GetFullName()]=owner end
                end
            end
        end
    end
    if not self.containerHook and valid(StaticFindObject('/Script/Tempest.TedPawnContainerComponent:OnRep_PawnsInContainer')) then
        self.containerHook=true
        RegisterHook('/Script/Tempest.TedPawnContainerComponent:OnRep_PawnsInContainer',function()self.containerEpoch=nil;self.garrisonFrame={};self.candidateEpoch=nil end)
    end
end
function movementIO:garrisonVisuals(actor)
    if mode~='play' then return end
    self.garrisonMeshes=self.garrisonMeshes or {}
    local name=actor:GetFullName();local state=self.garrisonMeshes[name]
    local function restore(entry)
        local c=entry.component
        if valid(c) then local hidden=entry.hidden==true;if entry.primary then hidden=false end;c:SetHiddenInGame(hidden,false);c:SetVisibility(entry.primary or entry.visible~=false,false) end
    end
    if self:isGarrisoned(actor) then
        actor:SetActorHiddenInGame(true)
        if not state then
            state={actor=actor,components={},actors={}};self.garrisonMeshes[name]=state
            local ok,enabled=pcall(function()return actor:GetActorEnableCollision()end)
            if ok and enabled==true then state.collision=true end -- never own the game's already-disabled collision
        end
        if state.collision~=nil then actor:SetActorEnableCollision(false) end
        if state.epoch~=self.cacheTick or not state.discovered then
            state.epoch=self.cacheTick;state.discovered=true
            local oldComponents,oldActors={},{}
            for _,e in ipairs(state.components) do if valid(e.component) then oldComponents[e.component:GetFullName()]=e end end
            for _,e in ipairs(state.actors) do if valid(e.actor) then oldActors[e.actor:GetFullName()]=e end end
            state.components={};state.actors={}
            local primary=valid(actor.MeshComp) and actor.MeshComp:GetFullName()
            local collected={}
            local function collect(c)
                if not valid(c) then return end
                local key=c:GetFullName();if collected[key] then return end;collected[key]=true
                local e=oldComponents[key] or {component=c,hidden=c.bHiddenInGame,visible=c.bVisible,primary=key==primary}
                oldComponents[key]=nil;state.components[#state.components+1]=e
            end
            local function remember(owner)
                -- Decals are SceneComponents, not PrimitiveComponents. Include
                -- selection rings, widget components and attached FX as well.
                local cls=StaticFindObject('/Script/Engine.SceneComponent')
                if not valid(cls) then return end
                local got,components=pcall(function()return owner:K2_GetComponentsByClass(cls)end)
                if not got then return end
                for _,entry in ipairs(components) do
                    local ok,c=pcall(function()return entry:get()end);if not ok then c=entry end
                    collect(c)
                end
            end
            remember(actor)
            collect(member(actor,'SelectionDecal')) -- pooled selection decals need not be owned by the pawn
            local attached={};local ok=pcall(function()actor:GetAttachedActors(attached,true,false)end)
            if ok then for _,entry in ipairs(attached) do
                local got,child=pcall(function()return entry:get()end);if not got then child=entry end
                if valid(child) and not child:IsA('/Script/Tempest.TedPawn') and not child:IsA('/Script/Tempest.TedProjectile') then
                    local key=child:GetFullName();local e=oldActors[key] or {actor=child,hidden=child.bHidden};oldActors[key]=nil
                    state.actors[#state.actors+1]=e;remember(child)
                end
            end end
            for _,e in pairs(oldComponents) do restore(e) end
            for _,e in pairs(oldActors) do if valid(e.actor) then e.actor:SetActorHiddenInGame(e.hidden==true) end end
            if #state.components==0 and valid(actor.MeshComp) then state.components[1]={component=actor.MeshComp,hidden=false,visible=true,primary=true} end
        end
        for _,e in ipairs(state.components) do if valid(e.component) then e.component:SetHiddenInGame(true,false);e.component:SetVisibility(false,false) end end
        for _,e in ipairs(state.actors) do if valid(e.actor) then e.actor:SetActorHiddenInGame(true) end end
    elseif state then
        self.garrisonMeshes[name]=nil
        if not self:isDead(actor) then
            actor:SetActorHiddenInGame(false)
            if state.collision~=nil then actor:SetActorEnableCollision(state.collision) end
            for _,e in ipairs(state.components) do restore(e) end
            for _,e in ipairs(state.actors) do if valid(e.actor) then e.actor:SetActorHiddenInGame(e.hidden==true) end end
        end
    end
end
function movementIO:deathVisuals(actor,dead)
    if not dead then return end
    self.visualDeaths=self.visualDeaths or {};self.deathPresented=self.deathPresented or {}
    local name=actor:GetFullName()
    if not self.deathPresented[name] then
        if self.absent and self.absent[name] then actor:SetActorHiddenInGame(false);self.absent[name]=nil end
        self:presentationTick(actor)
        local mesh=actor.MeshComp
        if valid(mesh) then mesh:SetComponentTickEnabled(true) end
        -- Native death state and cosmetic delivery are separate: bDied can be
        -- replicated even though the Blueprint effect never ran in this demo.
        self.deathPresented[name]=true
        actor:ReceiveOnDeath()
    end
    if not self.visualDeaths[name] then
        self.deadPresentationActors=self.deadPresentationActors or {};self.deadPresentationActors[name]=actor
        self.corpseQueue=self.corpseQueue or {}
        local delay=member(actor,'DestroyActorDelay')
        if type(delay)~='number' or delay<=0 then delay=8 end
        local clock=self.playTime or 0
        self.corpseQueue[name]={actor=actor,untilTime=clock+delay}
        if actor:IsA('/Script/Tempest.TedVehicle') and valid(member(actor,'WreckMesh')) then
            self.pendingWrecks=self.pendingWrecks or {}
            -- Allow native death delivery in the current frame to spawn first.
            self.pendingWrecks[name]={actor=actor,at=clock+0.1}
        end
        actor.bDisableHUDBars=true;actor.bDisableStatusEffects=true;actor.bCanEverBeSelected=false
        -- Dead presentation actors must not intercept selection or minimap hits.
        actor:SetActorEnableCollision(false)
        local neutral=self.neutralMeshes and self.neutralMeshes[name]
        if valid(neutral) then neutral:SetVisibility(false,true) end
    end
    self.visualDeaths[name]=true
end
function movementIO:buildingVisuals(actor,state)
    if not actor:IsA('/Script/Tempest.TedStructureBase') or actor:IsA('/Script/Tempest.TedConformationBase') then return end
    self.buildingStates=self.buildingStates or {};self.visualDeaths=self.visualDeaths or {}
    local name=actor:GetFullName()
    if state==3 then
        self:deathVisuals(actor,true)
        self.buildingStates[name]=3
    elseif not self:isDead(actor) then
        local value=state or (actor:IsConstructing() and 1 or 2)
        if self.buildingStates[name]~=value then
            self:presentationTick(actor)
            actor:ReceiveHandleConstructionVisuals(value==1)
            -- IsConstructing describes the factory's production queue. Finishing
            -- a queue item must never replay the producer's placement montage.
            self.buildingStates[name]=value
        end
    end
end
function movementIO:siteVisuals(actor,key,sample,time)
    if not actor:IsA('/Script/Tempest.TedConstructionSite') then return true end
    local state=sample.site
    local catalog=self.catalog and self.catalog[key]
    if catalog then
        for _,segment in ipairs(catalog.segments) do
            if time>=segment.time and time<=segment.last+0.5 and segment.target then
                if time>=segment.target.time then return false end
                if not state then
                    local c=segment.target.class
                    if c:match('^BP_BD_GDF_') then
                        self.siteClasses=self.siteClasses or {}
                        if self.siteClasses[c]==nil then
                            local asset=c:gsub('_C$','')
                            self.siteClasses[c]=LoadAsset('/Game/Tempest/GDF/Structures/'..asset..'.'..c)
                        end
                        local cls=self.siteClasses[c]
                        if valid(cls) then
                            local grid=cls:GetCDO().StructureGridSize;local selected
                            actor.FootprintConfigs:ForEach(function(i,entry)
                                local size=entry:get().GridSize
                                if size.X==grid.X and size.Y==grid.Y then selected=i-1 end
                            end)
                            if selected then state={footprint=selected,progress=math.min(0.99,(time-segment.time)/(segment.target.time-segment.time))} end
                        end
                    end
                end
                break
            end
        end
    end
    if state then
        if actor.ActiveFootprintConfig~=state.footprint then
            actor.ActiveFootprintConfig=state.footprint;actor:OnRep_ActiveFootprint()
        end
        actor.LastConstructionProgress=state.progress;actor:OnRep_ConstructionProgress()
    end
    return true
end
function movementIO:restoreDoctrines(snapshot)
    if mode~='play' or not snapshot or not next(snapshot) then return end
    if self.doctrineSnapshot==snapshot then return end
    self.doctrineSnapshot=snapshot
    local parts={}
    for owner,paths in pairs(snapshot) do parts[#parts+1]=owner..':'..table.concat(paths,'|') end
    table.sort(parts);local snapshotSignature=table.concat(parts,';')
    if self.doctrineSignature==snapshotSignature then return end
    local allApplied=true;local found={}
    self.doctrineApplied=self.doctrineApplied or {};self.doctrineAssets=self.doctrineAssets or {}
    for _,data in ipairs(self:cachedActors('TedPlayerData')) do
        if valid(data) then
            local owner=data:GetOwningPlayerState()
            local paths=valid(owner) and snapshot[owner:GetTedPlayerID()]
            if paths then
                found[owner:GetTedPlayerID()]=true
                local key=data:GetFullName();local signature=table.concat(paths,'|')
                if self.doctrineApplied[key]~=signature then
                    local assets={};local complete=true
                    for _,path in ipairs(paths) do
                        local asset=self.doctrineAssets[path]
                        if not valid(asset) then asset=LoadAsset(path);self.doctrineAssets[path]=asset end
                        if valid(asset) and asset:IsA('/Script/Tempest.TedDoctrineDefinition') then assets[#assets+1]=asset else complete=false end
                    end
                    if complete then
                        -- UI-readable replay state only: do not grant research,
                        -- apply gameplay effects or dispatch player commands.
                        data.ResearchedDoctrines=assets
                        for _,widget in ipairs(self:cachedActors('TedPlayerDataWidget')) do
                            if valid(widget) then
                                local target=widget:GetTargetPlayerData()
                                if valid(target) and target:GetFullName()==key then widget:OnResearchedDoctrinesChange_Handler_Native(data) end
                            end
                        end
                        self.doctrineApplied[key]=signature
                    else allApplied=false end
                end
            end
        end
    end
    for owner in pairs(snapshot) do if not found[owner] then allApplied=false end end
    if allApplied then self.doctrineSignature=snapshotSignature end
end
function movementIO:updateProjectiles(time)
    if mode~='play' then return end
    self.projectiles=self.projectiles or {}
    self.projectileActors=self.projectileActors or {}
    self.projectileHooks=self.projectileHooks or {}
    local function install(path,hit)
        if self.projectileHooks[path] then return end
        self.projectileHooks[path]=true
        RegisterHook(path,function(context)
            if not self.projectiles then return end
            local actor=context:get();if not valid(actor) then return end
            if hit then
                if self.audio and not self.audio.closed then
                    local rs=FindFirstOf('ReplaySubsystem')
                    if valid(rs) and rs:IsPlaying() then
                        local ok,err=pcall(function()self.audio:hit(actor,rs:GetReplayCurrentTime())end)
                        if not ok then status('audio_error',tostring(err)) end
                    end
                end
                return
            end
            local key=actor:GetFullName();local old=self.projectiles[key]
            if old and old.retired and valid(actor.ProjectileMovement) then
                actor:SetActorTickEnabled(true);actor.ProjectileMovement:SetComponentTickEnabled(true)
            end
            self.projectiles[key]=nil -- pooled actor, new shot
        end)
    end
    install('/Script/Tempest.TedProjectile:ReceiveOnProjectileFired')
    install('/Script/Tempest.TedProjectile:ReceiveOnProjectileHit',true)
    if self.projectileTime and time-self.projectileTime<0.05 then return end
    self.projectileTime=time
    local active={}
    local seen={}
    for _,actor in ipairs(self:cachedActors('TedProjectile')) do
        local key=valid(actor) and actor:GetFullName()
        local info=key and self.projectileActors[key]
        if key then seen[key]=true end
        if key and (not info or not valid(info.movement)) then
            info={movement=actor.ProjectileMovement};self.projectileActors[key]=info
            local cls=actor:GetClass();local classPath=cls:GetFullName()
            if not self.projectileHooks[classPath] then
                self.projectileHooks[classPath]=true
                cls:ForEachFunction(function(fn)
                    local name=fn:GetFName():ToString()
                    if name=='ReceiveOnProjectileFired' or name=='ReceiveOnProjectileHit' then
                        install(classPath:gsub('^BlueprintGeneratedClass ',''):gsub('^Class ','')..':'..name,name=='ReceiveOnProjectileHit')
                    end
                end)
            end
        end
        -- Tracer Blueprints can keep bHidden=true while their FX components are
        -- visible. Movement activity, rather than actor visibility, owns a shot.
        if info and valid(info.movement) and info.movement:IsActive() then
            local p=actor:K2_GetActorLocation()
            local start=actor.StartLocation;local dest=actor.TargetLocation
            local shot=self.projectiles[key]
            if not shot or shot.sx~=start.X or shot.sy~=start.Y or shot.sz~=start.Z or shot.dx~=dest.X or shot.dy~=dest.Y or shot.dz~=dest.Z then
                shot={sx=start.X,sy=start.Y,sz=start.Z,dx=dest.X,dy=dest.Y,dz=dest.Z,time=time};self.projectiles[key]=shot
            end
            active[key]=shot
            local targetActor=actor.Target
            local target=valid(targetActor) and targetActor:K2_GetActorLocation() or dest
            local dx,dy,dz=target.X-start.X,target.Y-start.Y,target.Z-start.Z
            local range=math.sqrt(dx*dx+dy*dy+dz*dz)
            local x,y,z=p.X-start.X,p.Y-start.Y,p.Z-start.Z
            -- Only retire overshot presentation actors. Never call damage/hit
            -- gameplay functions or destroy pooled actors needed by later shots.
            local passed=range>1 and (x*dx+y*dy+z*dz)/(range*range)>1.05
            if not shot.retired and (passed or time-shot.time>30) then
                actor:SetActorHiddenInGame(true)
                info.movement:Deactivate();info.movement:SetComponentTickEnabled(false)
                local fxClass=StaticFindObject('/Script/Engine.FXSystemComponent')
                if valid(fxClass) then
                    local components=actor:K2_GetComponentsByClass(fxClass)
                    local function stopFX(entry)
                        -- UE4SS can return direct objects or wrapped array values.
                        local ok,fx=pcall(function() return entry:get() end)
                        if not ok then fx=entry end
                        local checked,isValid=pcall(function() return valid(fx) end)
                        if checked and isValid then fx:Deactivate() end
                    end
                    if type(components)=='table' then
                        for _,entry in pairs(components) do stopFX(entry) end
                    else
                        components:ForEach(function(_,entry) stopFX(entry) end)
                    end
                end
                shot.retired=true
                self.retiredProjectileCount=(self.retiredProjectileCount or 0)+1
            end
        end
    end
    -- Keep retired entries for pooled-fire reactivation, discard unrelated old shots.
    for key,shot in pairs(self.projectiles) do
        if not active[key] and (not shot.retired or time-shot.time>35) then self.projectiles[key]=nil end
    end
    for key in pairs(self.projectileActors) do if not seen[key] then self.projectileActors[key]=nil end end
end
function movementIO:updateReplayAudio(time)
    if mode~='play' or self.audioFailed or type(ForEachUObject)~='function' then return end
    if not self.audio then
        local ok,module=pcall(require,'ReplayAudio')
        if not ok then self.audioFailed=true;status('audio_error',tostring(module));return end
        self.audio=module.new({objects=ForEachUObject,clock=os.time,destroy=function(component)
            if valid(component) then component:K2_DestroyComponent(component:GetOwner()) end
        end,spawn=function(pc,sound,position)
            local util=StaticFindObject('/Script/Engine.Default__GameplayStatics')
            local component=util:SpawnSoundAtLocation(pc,sound,position,{Pitch=0,Yaw=0,Roll=0},1,1,0,nil,nil,true)
            if valid(component) then return component end
            -- The demo world rejects the native location factory even at the
            -- listener. Create an idle component, then configure positional
            -- playback BEFORE Play; retain the asset's native attenuation.
            component=util:CreateSound2D(pc,sound,1,1,0,nil,false,true)
            if valid(component) then
                component.bAllowSpatialization=true;component.bIsUISound=false
                component.bOverrideAttenuation=false
                component:K2_SetWorldLocation(position,false,{},false)
                component:Play(0)
            end
            return component
        end})
        if not self.audioObserver then
            self.audioObserver=true
            for _,name in ipairs({'PlaySoundAtLocation','SpawnSoundAtLocation','SpawnSoundAttached'}) do
                local attached=name=='SpawnSoundAttached'
                local path='/Script/Engine.GameplayStatics:'..name
                if valid(StaticFindObject(path)) then RegisterHook(path,function(context,...)
                    if not self.audio or self.audio.closed or self.audio.spawning then return end
                    local args={...}
                    pcall(function()
                        local sound=args[attached and 1 or 2]:get()
                        local position
                        if attached then local component=args[2]:get();if not valid(component) then return end;position=component:K2_GetComponentLocation()
                        else position=args[3]:get() end
                        local rs=FindFirstOf('ReplaySubsystem')
                        if valid(rs) and rs:IsPlaying() then self.audio:observed(sound,position,rs:GetReplayCurrentTime()) end
                    end)
                end) end
            end
        end
    end
    local pc=self.audioController
    if not valid(pc) then return end
    self.audio:catalogSounds() -- warm the immutable sound lookup outside impact callbacks
    local paused=valid(pc:GetWorld():K2_GetWorldSettings().PauserPlayerState)
    self.audio:update(time,paused,pc)
    if not self.audioReportTime or time-self.audioReportTime>=1 then
        self.audioReportTime=time;local s=self.audio.stats
        write(home..'audio-state.txt',session..'\ntime='..time..'\nplayed='..s.played..'\nnative_duplicates='..s.native..'\nmissing='..s.missing..'\nqueued='..s.queued..'\nno_tag='..s.noTag..'\nno_cue='..s.noCue..'\nspawn_failed='..s.spawnFailed..'\nlast_missing_tag='..tostring(self.audio.lastMissingTag)..'\nlast_spawn_error='..tostring(self.audio.lastSpawnError)..'\ndropped='..s.dropped..'\nactive='..#self.audio.owned..'\npaused='..tostring(paused))
    end
end
function movementIO:updateHealthBars(actors,samples)
    if mode~='play' then return end
    if self.healthHidden then actors={} end
    local pc=self.audioController
    if not valid(pc) then return end
    local panel=self.healthPanel
    if not valid(panel) then
        for _,hud in ipairs(self:cachedActors('TedThirdPartySpectatorHud')) do
            if valid(hud) and hud:IsInViewport() then
                local parent=hud.VerticalBox_Minimap
                for _=1,12 do
                    if not valid(parent) then break end
                    if parent:IsA('/Script/UMG.CanvasPanel') then panel=parent end
                    parent=parent:GetParent()
                end
                if valid(panel) then self.healthPanel=panel;self.healthBars={} end
                break
            end
        end
    end
    if not valid(panel) then return end
    local layout=StaticFindObject('/Script/UMG.Default__WidgetLayoutLibrary')
    local cls=StaticFindObject('/Script/UMG.ProgressBar')
    if not valid(layout) or not valid(cls) then return end
    self.healthBars=self.healthBars or {}
    local seen={};local sx,sy={},{};pc:GetViewportSize(sx,sy)
    local scale=layout:GetViewportScale(pc)
    local width,height=(sx.SizeX or 0)/scale,(sy.SizeY or 0)/scale
    for key,actor in pairs(actors) do
        local sample=samples[key]
        local hp=sample and sample.health
        -- Legacy client demos may have no attribute set. Unknown is not full
        -- health; never synthesize a percentage or write native attributes.
        if not hp then
            self.nativeHealthCache=self.nativeHealthCache or {}
            local cached=self.nativeHealthCache[key]
            if not cached or cached.epoch~=self.cacheTick then
                cached={epoch=self.cacheTick};self.nativeHealthCache[key]=cached
                if valid(member(actor,'DefaultAttributeSet')) then
                    local current,maximum=actor:GetHealth(),actor:GetHealthMax()
                    if maximum>0 and current>=0 and current<=maximum then cached.health={current=current,maximum=maximum} end
                end
            end
            hp=cached.health
        end
        if hp and hp.maximum>0 and hp.current>0 and sample and not sample.dead and sample.building~=3 and not self:isDead(actor) and not self:isGarrisoned(actor) and self.visible[actor:GetFullName()] then
            local p=sample.position
            self.healthOffsets=self.healthOffsets or {}
            local offset=self.healthOffsets[key]
            if not offset or offset.building~=sample.building then
                offset={building=sample.building,z=sample.building and 300 or 140}
                local ok,top=pcall(function()
                    local origin,extent={},{};actor:GetActorBounds(false,origin,extent,false)
                    return origin.Z+extent.Z-p.Z+40
                end)
                if ok and top>0 and top<5000 then offset.z=top end
                self.healthOffsets[key]=offset
            end
            local position={X=p.X,Y=p.Y,Z=p.Z+offset.z}
            local screen={}
            if layout:ProjectWorldLocationToWidgetPosition(pc,position,screen,true) and screen.X>=0 and screen.X<=width and screen.Y>=0 and screen.Y<=height then
                local bar=self.healthBars[key]
                if not valid(bar) then
                    bar=StaticConstructObject(cls,panel);panel:AddChildToCanvas(bar)
                    bar.Slot:SetSize({X=sample.building and 72 or 48,Y=5});bar.Slot:SetAlignment({X=0.5,Y=1});bar.Slot:SetZOrder(-1)
                    self.healthBars[key]=bar
                end
                local pct=hp.current/hp.maximum
                bar:SetPercent(pct);bar:SetFillColorAndOpacity(pct>0.5 and {R=0.1,G=0.8,B=0.1,A=1} or (pct>0.25 and {R=1,G=0.7,B=0,A=1} or {R=1,G=0.1,B=0.1,A=1}))
                bar.Slot:SetPosition({X=screen.X,Y=screen.Y});bar:SetVisibility(3)
                -- The demo's native bar can report zero or duplicate this one.
                -- Suppress it only after a known-health replacement is visible.
                if not actor.bDisableHUDBars then actor.bDisableHUDBars=true end
                seen[key]=true
            end
        end
    end
    for key,bar in pairs(self.healthBars) do
        if not seen[key] then
            if valid(bar) then bar:RemoveFromParent() end
            self.healthBars[key]=nil
        end
    end
end
function movementIO:applyPose(actor,name,sample)
    -- Moving poses still update every playback callback. Stationary buildings
    -- and idle units need no repeated teleport/rotation/render invalidation.
    -- A cache epoch refresh repairs any native demo transform overwrite.
    self.appliedPoses=self.appliedPoses or {}
    local previous=self.appliedPoses[name]
    local p,r=sample.position,sample.rotation
    local refresh=not previous or previous.epoch~=self.cacheTick
    if refresh or previous.x~=p.X or previous.y~=p.Y or previous.z~=p.Z then
        actor:K2_SetActorLocation(p,false,{},true)
    end
    if refresh or previous.pitch~=r.Pitch or previous.yaw~=r.Yaw or previous.roll~=r.Roll then
        actor:K2_SetActorRotation(r,true)
    end
    self.appliedPoses[name]={x=p.X,y=p.Y,z=p.Z,pitch=r.Pitch,yaw=r.Yaw,roll=r.Roll,epoch=self.cacheTick}
end
function movementIO:play(subsystem)
    self.animationFrames={}
    self.deadFrame={}
    self.garrisonFrame={}
    if mode~='play' or not valid(subsystem) or not subsystem:IsPlaying() then return end
    self.playTime=subsystem:GetReplayCurrentTime()
    self.playTicks=(self.playTicks or 0)+1
    self.cacheTick=math.floor(self.playTicks/15)
    self:refreshContainers()
    local audioOK,audioError=pcall(function()self:updateReplayAudio(self.playTime)end)
    if not audioOK then
        if self.audio then self.audio:close() end
        self.audioFailed=true;status('audio_error',tostring(audioError))
    end
    self:retireCorpses(self.playTime)
    self:restoreWrecks(self.playTime)
    self:retireDeadStatus()
    self:maintainRetiredResources()
    if not self.projectileFailed then
        local ok,err=pcall(function() self:updateProjectiles(subsystem:GetReplayCurrentTime()) end)
        if not ok then self.projectileFailed=true;status('projectile_visual_error',tostring(err)) end
    end
    if not self.codec or self.failed then return end
    if not self.opened then
        self.opened=true
        local path=os.getenv('LOCALAPPDATA')..'/Tempest/Saved/Demos/'..replay..'.movement'
        self.catalog=self.codec.catalog(path,replay)
        self.catalogClasses={}
        for _,track in pairs(self.catalog) do self.catalogClasses[track.class]=true end
        self.reader=self.codec.reader(path,replay)
        if self.reader then status('movement_playback','Applying received unit transforms from '..replay..'.movement')
        else status('movement_missing','No movement companion; using native replay data only') end
    end
    if not self.reader then return end
    local time=subsystem:GetReplayCurrentTime()
    local samples=self.reader:at(time);local actors={}
    self.finishedTracks=self.finishedTracks or {}
    for key,sample in pairs(samples) do
        if self.finishedTracks[key] and (sample.dead or sample.building==3) then samples[key]=nil end
    end
    if not self.doctrineFailed then
        local ok,err=pcall(function() self:restoreDoctrines(self.reader.doctrines) end)
        if not ok then self.doctrineFailed=true;status('doctrine_visual_error',tostring(err)) end
    end
    if not self.reader.following and self.reader.previous and time>self.reader.previous.time+0.5 then
        self.visible={};self.absent={};self.applied=0;return
    end
    self.origins=self.origins or {};self.bindings=self.bindings or {};self.births=self.births or {}
    local candidates=self.candidates
    -- Identity discovery/binding inputs change at recorded snapshot boundaries.
    -- Keep per-render interpolation below, but do not rebuild the entire native
    -- pawn census multiple times for the same data frame. Container replication
    -- invalidates its epoch independently of the recorded clock.
    if not candidates or self.candidateFrame~=self.reader.previous or self.candidateEpoch~=self.cacheTick or self.candidateContainerEpoch~=self.containerEpoch then
    candidates={}
    for _,actor in ipairs(self:cachedActors('TedPawn')) do
        if valid(actor) then
            local actorName=actor:GetFullName()
            if self.visualDeaths and self.visualDeaths[actorName] and self.garrisonMeshes and self.garrisonMeshes[actorName] then self:garrisonVisuals(actor) end
            if not (self.visualDeaths and self.visualDeaths[actorName]) then
            self:garrisonVisuals(actor)
            self:presentationTick(actor)
            self.watchedPawns=self.watchedPawns or {}
            if not self.watchedPawns[actorName] then self:watchDeath(actor);self.watchedPawns[actorName]=true end
            if self:isDead(actor) then self:deathVisuals(actor,true) end
            local name=actor:GetFullName()
            if self:isPresentationPawn(actor) then
                self.pawnKinds=self.pawnKinds or {}
                local kind=self.pawnKinds[name]
                if not kind then
                    kind={class=actor:GetClass():GetFName():ToString(),unit=actor:IsA('/Script/Tempest.TedUnitBase'),
                        structure=actor:IsA('/Script/Tempest.TedStructureBase'),site=actor:IsA('/Script/Tempest.TedConstructionSite')}
                    self.pawnKinds[name]=kind -- UObject class traits cannot change during this actor's lifetime.
                end
                if not self.catalogClasses or self.catalogClasses[kind.class] then
                self.births[name]=self.births[name] or time
                -- Unbound actors can initially have an unreplicated spawn pose.
                -- Refresh that pose until matched; never remap a bound actor.
                if not self.managed or not self.managed[name] then
                    local p=actor:K2_GetActorLocation()
                    self.origins[name]={X=p.X,Y=p.Y,Z=p.Z}
                end
                candidates[#candidates+1]={name=name,actor=actor,position=self.origins[name],
                    class=kind.class,kind=kind,owner=actor:GetOwningPlayerID(),born=self.births[name],eligible=not self:isDead(actor)}
                end
            end
        end
    end
    end
    self.candidates=candidates;self.candidateFrame=self.reader.previous;self.candidateEpoch=self.cacheTick;self.candidateContainerEpoch=self.containerEpoch
    end
    for _,entry in pairs(self.garrisonMeshes or {}) do
        if valid(entry.actor) then self:garrisonVisuals(entry.actor) end
    end
    -- Actors can disappear between snapshots. Never pass stale native objects
    -- to binding or transform application, even while the demo is paused.
    local current={}
    for _,candidate in ipairs(candidates) do
        if valid(candidate.actor) then
            candidate.eligible=not self:isDead(candidate.actor)
            current[#current+1]=candidate
        end
    end
    candidates=current
    local matched=self.codec.match(self.reader.tracks,samples,candidates,self.bindings)
    for key,candidate in pairs(matched) do actors[key]=candidate.actor end
    local applied,visible,absent,containerCorrections=0,{},{},0
    self.managed=self.managed or {}
    for key,sample in pairs(samples) do
        local actor=actors[key]
        local kind=matched[key] and matched[key].kind
        if actor then
            self:deathVisuals(actor,sample.dead or sample.building==3 or self:isDead(actor))
            if sample.dead or sample.building==3 then self.finishedTracks[key]=true end
        end
        if actor and (not kind or kind.structure) then self:buildingVisuals(actor,sample.building) end
        if actor and not self:isDead(actor) and not self:isGarrisoned(actor) and (kind and not kind.site or self:siteVisuals(actor,key,sample,time)) then
            local name=actor:GetFullName();visible[name]=true;self.managed[name]=true
            if actor:IsInContainer() then containerCorrections=containerCorrections+1 end
            if not self.visible or not self.visible[name] then
                if self.appliedPoses then self.appliedPoses[name]=nil end
                actor:K2_SetDefaultVisibility(true,true)
                actor:K2_OnVisibilityChanged(true)
            end
            if actor.bHidden then actor:SetActorHiddenInGame(false) end
            self:applyPose(actor,name,sample)
            if (kind and kind.unit) or (not kind and actor:IsA('/Script/Tempest.TedUnitBase')) then
                -- Native animation reads UnitMovement.Velocity. Teleporting the
                -- actor alone leaves it zero and produces frozen-pose sliding.
                local movement=actor:GetMovementComponent()
                if valid(movement) then movement.Velocity=sample.velocity end
                if not self.animationFailed then
                    local ok,err=pcall(function() self:updateLocomotion(actor,sample.velocity) end)
                    if not ok then self.animationFailed=true;status('animation_error',tostring(err)) end
                end
            end
            applied=applied+1
        end
    end
    for _,candidate in ipairs(candidates) do
        local actor=candidate.actor;local name=candidate.name
        if self.managed[name] and not visible[name] and not actor:IsA('/Script/Tempest.TedConformationBase') then
            absent[name]=true
            -- Explicit native death owns its wreck/effects lifecycle. Absence alone
            -- may mean fog, garrison or replacement, and is never a death event.
            if not self:isDead(actor) then actor:SetActorHiddenInGame(true) end
        end
    end
    self.visible=visible
    self.absent=absent
    self.applied=applied
    if not self.healthFailed then
        local ok,err=pcall(function()self:updateHealthBars(actors,samples)end)
        if not ok then self.healthFailed=true;status('health_display_error',tostring(err)) end
    end
    if not self.proofTime or time-self.proofTime>=1 then
        self.proofTime=time
        write(home..'playback-state.txt',session..'\ntime='..time..'\napplied='..applied..'\nstale_container_overrides='..containerCorrections..'\nretired_projectiles='..(self.retiredProjectileCount or 0)..'\nretired_corpses='..(self.retiredCorpses or 0))
    end
    local markerNow=os.clock()
    if not self.markerFailed and (not self.markerTime or markerNow-self.markerTime>=0.1) then
        self.markerTime=markerNow -- UI redraw cadence is real time, including 4x playback.
        local ok,err=pcall(function() self:updateMarkers(actors,samples) end)
        if not ok then self.markerFailed=true;status('minimap_marker_error',tostring(err)) end
    end
end
function movementIO:updateMarkers(actors,samples)
    -- Presentation-only pins: client demos can have visible buildings but no
    -- ECS alive state for the native minimap renderer. Never fabricate health.
    local utils=StaticFindObject('/Script/Tempest.Default__TedUtils')
    local ui=StaticFindObject('/Script/Tempest.Default__TedUIFunctionsLibrary')
    local imageClass=StaticFindObject('/Script/UMG.Image')
    if not valid(utils) or not valid(ui) or not valid(imageClass) then return end
    self.maps=self.maps or {}
    self.markerStates=self.markerStates or {}
    local colors={}
    for _,widget in ipairs(FindAllOf('TedMinimapWidget') or {}) do
        if valid(widget) and valid(widget.MinimapImage) then
            local canvas=widget.MinimapImage:GetParent()
            if valid(canvas) and canvas:IsA('/Script/UMG.CanvasPanel') then
                local name=widget:GetFullName();local pins=self.maps[name] or {};self.maps[name]=pins
                local states=self.markerStates[name] or {};self.markerStates[name]=states
                local bounds=utils:GetWorldBounds(widget);local size=widget:GetMinimapSize();local seen={}
                local origin=widget.MinimapImage.Slot:GetPosition()
                local signature=table.concat({size.X,size.Y,origin.X,origin.Y},':') -- world bounds are fixed for this replay map
                for key,actor in pairs(actors) do
                    local sample=samples[key]
                    if sample and not actor:IsAlive() and not self:isDead(actor) and not self:isGarrisoned(actor) and not (self.absent and self.absent[actor:GetFullName()]) then
                        seen[key]=true
                        local pin=pins[key]
                        local state=states[key]
                        if not valid(pin) then
                            pin=StaticConstructObject(imageClass,widget)
                            assert(valid(pin),'Minimap image allocation failed')
                            canvas:AddChildToCanvas(pin);pin:SetVisibility(3) -- HitTestInvisible: clicks pass through
                            pins[key]=pin
                            state={};states[key]=state
                            local width=actor:IsA('/Script/Tempest.TedStructureBase') and 5 or 3
                            state.width=width;pin.Slot:SetSize({X=width,Y=width});pin.Slot:SetZOrder(10)
                        end
                        local owner=actor:GetOwningPlayerID()
                        if state.owner~=owner then
                            local color=colors[owner]
                            if not color then
                                color={R=0.65,G=0.65,B=0.65,A=1}
                                if owner>=0 and owner<8 then local preset=utils:GetPlayerColorPreset(widget,owner);if preset then color=preset.PrimaryColor end end
                                colors[owner]=color
                            end
                            pin:SetColorAndOpacity(color);state.owner=owner
                        end
                        -- Stationary buildings do not need material/Slate writes
                        -- on every pass. Still re-project on geometry changes.
                        if state.x~=sample.position.X or state.y~=sample.position.Y or state.geometry~=signature then
                            local result={X=0,Y=0}
                            ui:CalculateMinimapLocation(bounds,{X=sample.position.X,Y=sample.position.Y},size,result)
                            pin.Slot:SetPosition({X=origin.X+result.X-state.width/2,Y=origin.Y+result.Y-state.width/2})
                            state.x=sample.position.X;state.y=sample.position.Y;state.geometry=signature
                        end
                    end
                end
                for key,pin in pairs(pins) do
                    if not seen[key] then if valid(pin) then pin:RemoveFromParent() end;pins[key]=nil;states[key]=nil end
                end
            end
        end
    end
end
function movementIO:fail(err)
    self:close();self.failed=true
    write(home..'movement-state.txt',session..'\n'..(self.name or replay)..'\nerror\n'..tostring(err))
    status('movement_error',tostring(err)..'; native replay continues without companion movement')
end
function movementIO:alive(actor)
    if self:isDead(actor) then return false end
    if self:isGarrisoned(actor) then return false end
    local name=actor:GetFullName()
    if self.absent and self.absent[name] then return false end
    return (self.visible and self.visible[name]) or actor:IsAlive()
end
local viewerInitialized = false
local viewerActors = {}
local hudVisibilityRefresh = false
local cameraIndex = 1
local followTarget
local viewerSpeed, appliedSpeed = 1, nil
local speeds = {0.5,1,2,4}
local function setViewerSpeed(pc,value)
    local allowed=false
    for _,speed in ipairs(speeds) do if value==speed then allowed=true end end
    local subsystem=FindFirstOf('ReplaySubsystem')
    if mode~='play' or not valid(subsystem) or not subsystem:IsPlaying() or not allowed then return end
    viewerSpeed=value
    pc:GetWorld():K2_GetWorldSettings().DemoPlayTimeDilation=value
    appliedSpeed=value
    status('viewer_speed',tostring(value)..'x')
end
local inputController
local configuredWidgets = {}
local viewerControllerName
local viewerFinished=false
local replayDuration
local pendingExitMenu,pendingExitShutdown,confirmedExitQueued
local function stopViewer(reason)
    if viewerStopped then return end
    viewerStopped = true
    pendingExitMenu=nil
    followTarget = nil
    configuredWidgets = {}
    movementIO:close()
    write(home..'close-viewer.txt',session)
    status('viewer_stopped',reason)
end
local function exitViewer(closeApplication)
    if mode~='play' or not viewerInitialized or viewerStopped then return end
    local pc=getLocalPlayerController()
    local subsystem=FindFirstOf('ReplaySubsystem')
    if not valid(pc) or not valid(subsystem) or (not subsystem:IsPlaying() and not viewerFinished) then return end
    pc:GetWorld():K2_GetWorldSettings().PauserPlayerState=nil
    stopViewer('Replay exit requested; callbacks released')
    -- Use local engine exit/travel without depending on live-match surrender
    -- acknowledgement, including when the replay is paused at EOF.
    -- This protected process belongs exclusively to the replay viewer. Never
    -- restore the null guard while old replay combat jobs can still execute,
    -- and never expose a live-game menu in this process.
    write(home..'shutdown.txt',session)
    command(pc,'exit')
end
if mode == 'play' then
    RegisterULocalPlayerExecPreHook(function(context,world,cmd)
        local exitCommand=cmd:lower():match('^%s*(.-)%s*$')
        if exitCommand=='quit' or exitCommand=='exit' then
            stopViewer('Local game exit command; viewer callbacks released')
            write(home..'shutdown.txt',session)
        end
        -- Observe the confirmed engine command without suppressing native exit.
        return nil,true
    end)
    -- A spectator has no live server to acknowledge the game's normal shutdown
    -- request. Clear our paused end state and use the engine's local quit path.
    RegisterHook('/Script/Tempest.TedPlayerController:ExitCurrentGame',function(context,shutdown)
        if not viewerInitialized or viewerStopped or confirmedExitQueued then return end
        local pc=context:get();local localPC=getLocalPlayerController()
        if not valid(pc) or not valid(localPC) or pc:GetFullName()~=localPC:GetFullName() then return end
        exitViewer(shutdown:get())
    end)
    -- Native menu handling does not call ExitCurrentGame through ProcessEvent.
    -- Quit/surrender open a native confirmation first. Do not tear down the
    -- viewer until that exact popup receives its confirm action.
    RegisterHook('/Script/Tempest.TedPauseMenuScreen:OnPauseMenuButtonSlotAction',function(context,panel,slot,action)
        if not viewerInitialized or viewerStopped or action:get()~=0 then return end
        local menu=context:get();local selected=slot:get()
        if not valid(menu) or not valid(selected) then return end
        local name=selected:GetFullName()
        local quit=valid(menu.Slot_Quit) and name==menu.Slot_Quit:GetFullName()
        local main=valid(menu.Slot_MainMenu) and name==menu.Slot_MainMenu:GetFullName()
        local surrender=valid(menu.Slot_RestartOrSurrender) and name==menu.Slot_RestartOrSurrender:GetFullName()
        pendingExitMenu=nil
        if main or quit or surrender then
            pendingExitMenu=menu;pendingExitShutdown=quit
            status('viewer_exit_confirmation','Waiting for replay exit confirmation')
        end
    end)
    RegisterHook('/Script/Tempest.TedContentPanelSlotBase:TriggerAction',function(context,action)
        if not viewerInitialized or viewerStopped or confirmedExitQueued or action:get()~=0 then return end
        local slot=context:get();if not valid(slot) then return end
        local pc=getLocalPlayerController();if not valid(pc) then return end
        -- Some Blueprint menu paths call the native handler directly. The slot
        -- action itself still passes through ProcessEvent, so arm that path too.
        local name=slot:GetFullName()
        for _,menu in ipairs(FindAllOf('TedPauseMenuScreen') or {}) do
            if valid(menu) then
                local owner=menu:GetOwningPlayer()
                if valid(owner) and owner:GetFullName()==pc:GetFullName() then
                    for _,field in ipairs({'Slot_Quit','Slot_MainMenu','Slot_RestartOrSurrender'}) do
                        if valid(menu[field]) and menu[field]:GetFullName()==name then
                            pendingExitMenu=menu;pendingExitShutdown=field=='Slot_Quit';return
                        end
                    end
                end
            end
        end
        if not valid(pendingExitMenu) then return end
        local popup=pendingExitMenu:GetPauseMenuPopup()
        local panel=slot:GetParentContentPanel()
        if not valid(popup) or not popup:IsVisible() or not valid(panel) or not valid(popup.ButtonsPanel) or
           panel:GetFullName()~=popup.ButtonsPanel:GetFullName() or panel:GetContentSlotsCount()~=2 then return end
        local owner=pendingExitMenu:GetOwningPlayer();local pc=getLocalPlayerController()
        if not valid(owner) or not valid(pc) or owner:GetFullName()~=pc:GetFullName() then return end
        local index=slot:GetSlotIndex()
        if index==0 then pendingExitMenu=nil;return end -- native Cancel
        if index~=1 then return end -- native Confirm
        local shutdown=pendingExitShutdown
        pendingExitMenu=nil;confirmedExitQueued=true
        -- Complete native button/delegate dispatch before quitting/travelling.
        gameLoop(1,function() exitViewer(shutdown);return true end)
    end)
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
function movementIO:clearDoctrinePopup()
    local h=self.viewerDoctrinePopup
    self.viewerDoctrinePopup=nil
    if not h then return end
    if valid(h.description) then h.description:SetVisibility(1) end
    if valid(h.tip) then h.tip:SetVisibility(1) end
    if valid(h.source) then h.source.CustomTooltipClass=h.sourceClass end
end
function movementIO:underCursor(widget)
    if not valid(widget) then return false end
    local slate=StaticFindObject('/Script/UMG.Default__SlateBlueprintLibrary')
    local layout=StaticFindObject('/Script/UMG.Default__WidgetLayoutLibrary')
    if valid(slate) and valid(layout) then
        -- Native HUD hover tracking can stay latched after suppressing its
        -- automatic tooltip. Test actual Slate bounds against the desktop cursor.
        local geometry=widget:GetCachedGeometry()
        local size=slate:GetLocalSize(geometry)
        if size.X<=0 or size.Y<=0 then
            local root=member(widget,'Root_SizeBox')
            if not valid(root) then root=member(widget,'Image_Icon') end
            if not valid(root) then
                local tree=member(widget,'WidgetTree');root=nil
                if valid(tree) then root=member(tree,'RootWidget') end
            end
            if valid(root) then geometry=root:GetCachedGeometry();size=slate:GetLocalSize(geometry) end
        end
        -- Some UE4SS builds expose an empty const-reference FGeometry. Do not
        -- close a visible popup just because its geometry cannot be marshalled.
        if size.X<=0 or size.Y<=0 then return widget:IsHovered() end
        local cursor=layout:GetMousePositionOnPlatform()
        local under=slate:IsUnderLocation(geometry,cursor)
        return under
    end
    return widget:IsHovered()
end
function movementIO:activateDoctrineTooltip(hud,source,original,cls)
    if self.creatingDoctrine or not valid(source) then return end
    local previous=self.viewerDoctrinePopup
    if previous and valid(previous.source) and previous.source:GetFullName()==source:GetFullName() then
        original:SetVisibility(2);return
    end
    self:clearDoctrinePopup()
    local library=StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary')
    if not valid(library) then return end
    self.creatingDoctrine=true
    self.popupCache=self.popupCache or {}
    local sourceKey=source:GetFullName()
    local cached=self.popupCache[sourceKey]
    local tip=cached and cached.tip
    if not valid(tip) then tip=library:Create(source:GetOwningPlayer(),cls,source:GetOwningPlayer()) end
    tip.TargetWidget=source
    tip.DesiredDisplayParams=original.DesiredDisplayParams
    tip:OnTooltipShown()
    self.creatingDoctrine=false
    tip:AddToViewport(100);tip:SetVisibility(4)
    tip.bTrackAsWidgetUnderCursor=true
    if valid(tip.Root_SizeBox) then tip.Root_SizeBox:SetVisibility(4) end
    local panels,icons,classes={},{},{}
    for _,name in ipairs({'DoctrinePanelA','DoctrinePanelB','DoctrinePanelC'}) do
        local panel=tip[name]
        if valid(panel) then
            panel.bResearchable=false;panel:SetVisibility(4)
            panels[panel:GetFullName()]=true
        end
    end
    for _,slot in ipairs(FindAllOf('TedDoctrineSlot') or {}) do
        if valid(slot) then
            local panel=slot:GetDoctrinePanel()
            if valid(panel) and panels[panel:GetFullName()] then
                slot:SetVisibility(0);slot:SetIsEnabled(true)
                local name=slot:GetFullName()
                classes[name]=(cached and cached.classes and cached.classes[name]) or slot.CustomTooltipClass
                -- This read-only clone owns its detail popup. The native HUD's
                -- automatic tooltip must not compete with it for hover/focus.
                slot.CustomTooltipClass=StaticFindObject('/Script/Tempest.ReplayDisabledTooltip')
                slot.bTrackAsWidgetUnderCursor=false
                icons[#icons+1]=slot
            end
        end
    end
    original:SetVisibility(2)
    local sourceClass=source.CustomTooltipClass
    source.CustomTooltipClass=StaticFindObject('/Script/Tempest.ReplayDisabledTooltip')
    local descriptions=cached and cached.descriptions or {}
    self.popupCache[sourceKey]={tip=tip,descriptions=descriptions,classes=classes}
    self.viewerDoctrinePopup={source=source,sourceClass=sourceClass,original=original,tip=tip,icons=icons,classes=classes,descriptions=descriptions,misses=0}
end
function movementIO:installDoctrineHover()
    if not self.doctrineHook then
        self.doctrineHook=true
        gameLoop(50,function()
            if viewerStopped or travelling then self:clearDoctrinePopup();return viewerStopped end
            local h=self.viewerDoctrinePopup
            if not h then
                -- This Blueprint event is invoked directly on some builds and
                -- does not enter UE4SS's ProcessEvent hook. Discover only this
                -- small tooltip class, twice per second, until it is shown.
                self.doctrinePoll=(self.doctrinePoll or 0)+1
                if self.doctrinePoll%10==0 then
                    local tips=FindAllOf('WBP_ThirdPartySpectator_Doctrines_Tooltip_C') or {}
                    for _,tip in ipairs(tips) do
                        if valid(tip) and tip:IsVisible() and tip:GetVisibility()~=1 and tip:GetVisibility()~=2 then
                            local source=tip:GetTargetWidget()
                            if valid(source) then
                                local ok,err=pcall(function() self:activateDoctrineTooltip(source:GetHUD(),source,tip,source.CustomTooltipClass) end)
                                if not ok then self.creatingDoctrine=false;status('doctrine_visual_error',tostring(err)) end
                                break
                            end
                        end
                    end
                end
                h=self.viewerDoctrinePopup
            end
            if h then
                if not valid(h.source) or not valid(h.tip) then self:clearDoctrinePopup();return false end
                -- The native manager can add its automatic widget to the
                -- viewport after OnTooltipShown returns. Remove that duplicate
                -- on the next tick; the clone owns all overview/detail painting.
                if valid(h.original) and (h.original:IsInViewport() or valid(h.original:GetParent())) then h.original:RemoveFromParent() end
                local hovered
                for _,icon in ipairs(h.icons) do if valid(icon) and self:underCursor(icon) then hovered=icon;break end end
                if self:underCursor(h.source) or self:underCursor(h.tip) or hovered then h.misses=0 else h.misses=h.misses+1 end
                local iconKey=hovered and hovered:GetFullName() or nil
                h.iconMisses=hovered and 0 or (h.iconMisses or 0)+1
                if iconKey~=h.iconKey and (hovered or h.iconMisses>=3) then
                    if valid(h.description) then h.description:SetVisibility(1) end
                    h.description=nil;h.icon=hovered;h.iconKey=iconKey
                    local cls=iconKey and h.classes[iconKey]
                    if hovered and valid(cls) then
                        local library=StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary')
                        local description=h.descriptions[iconKey]
                        local fresh=not valid(description)
                        if fresh then description=library:Create(h.source:GetOwningPlayer(),cls,h.source:GetOwningPlayer()) end
                        description.TargetWidget=hovered
                        description.DesiredDisplayParams=hovered.CustomTooltipDefaultDisplayParams
                        if fresh then description:OnTooltipShown() end
                        -- This tooltip's native content cache is initialized for
                        -- the player's own doctrine tree. Read the actual hovered
                        -- spectator slot instead of displaying that stale cache.
                        if valid(description.TextBlock_Name) then description.TextBlock_Name:SetText(hovered:GetTitle()) end
                        if valid(description.TextBlock_Description) then description.TextBlock_Description:SetText(hovered:GetDescription()) end
                        if valid(description.Image_Icon) and valid(hovered.Image_Icon) then description.Image_Icon:SetBrush(hovered.Image_Icon.Brush) end
                        if valid(description.TextBlock_CostValue_Credits) then description.TextBlock_CostValue_Credits:SetText(FText(tostring(hovered:GetResearchCostCredits()))) end
                        if valid(description.TextBlock_CostValue_Time) then description.TextBlock_CostValue_Time:SetText(FText(tostring(hovered:GetResearchTime()))) end
                        if valid(description.Panel_ExtendedDescriptions) then description.Panel_ExtendedDescriptions:SetVisibility(2) end
                        if valid(description.ExtendedDescriptionsSeparator) then description.ExtendedDescriptionsSeparator:SetVisibility(2) end
                        description.bTrackAsWidgetUnderCursor=false
                        description:AddToViewport(101);description:SetVisibility(3)
                        h.descriptions[iconKey]=description;h.description=description
                    end
                end
                if h.misses>=6 then self:clearDoctrinePopup() end
            end
            return false
        end)
    end
    local path='/Game/Tempest/UI/ThirdPartySpectator/DoctrinesWidget/WBP_ThirdPartySpectator_Doctrines_Tooltip.WBP_ThirdPartySpectator_Doctrines_Tooltip_C:OnTooltipShown'
    if not self.doctrineShownHook and valid(StaticFindObject(path)) then
        self.doctrineShownHook=true
        RegisterHook(path,function(context)
            if viewerStopped or travelling or self.creatingDoctrine then return end
            local tip=context:get();if not valid(tip) then return end
            local source=tip:GetTargetWidget()
            if valid(source) then self:activateDoctrineTooltip(source:GetHUD(),source,tip,source.CustomTooltipClass) end
        end)
    end
end
local function finishReplay(pc)
    if viewerFinished then return end
    viewerFinished=true;followTarget=nil
    if movementIO.audio then movementIO.audio:close() end
    movementIO:maintainRetiredResources(#(movementIO.retiredResources or {}))
    local settings=pc:GetWorld():K2_GetWorldSettings()
    if not valid(settings.PauserPlayerState) then command(pc,'demopause') end
    gameLoop(100,function()
        if not viewerStopped then movementIO:maintainRetiredResources(#(movementIO.retiredResources or {})) end
        return true -- catch presentation restarts queued by the last demo frame
    end)
    local ok,err=pcall(function()
        liveWidgets('TedThirdPartySpectatorHud',function(hud)
            if not hud:IsInViewport() then return end
            local canvas=hud.Box_StatsOverview:GetParent()
            if not valid(canvas) or not canvas:IsA('/Script/UMG.CanvasPanel') then return end
            local label=StaticConstructObject(StaticFindObject('/Script/UMG.TextBlock'),hud)
            canvas:AddChildToCanvas(label)
            label:SetText(FText('리플레이 종료 · 3초 후 게임이 종료됩니다'))
            label:SetColorAndOpacity({SpecifiedColor={R=1,G=1,B=1,A=1},ColorUseRule=0})
            local font=label.Font;font.Size=24;label:SetFont(font)
            label:SetVisibility(3)
            label.Slot:SetAnchors({Minimum={X=0.5,Y=0.12},Maximum={X=0.5,Y=0.12}})
            label.Slot:SetAlignment({X=0.5,Y=0})
            label.Slot:SetAutoSize(true);label.Slot:SetPosition({X=0,Y=0});label.Slot:SetZOrder(100)
        end)
    end)
    status('viewer_finished','리플레이 종료 · 3초 후 재생용 게임을 종료합니다. 새 경기는 런처의 게임 실행을 사용하세요.'..(ok and '' or ' / banner: '..tostring(err)))
    -- Real-time callback: demo pause/speed must not delay the terminal exit.
    gameLoop(3000,function()
        if not viewerStopped then
            stopViewer('Replay completed; closing the replay-only game process')
            write(home..'shutdown.txt',session)
            -- The session-bound watcher also closes this exact process if the
            -- engine cannot service exit while its demo world is paused.
            if valid(pc) then pcall(command,pc,'exit') end
        end
        return true
    end)
end
local function configureViewer(pc)
    movementIO.audioController=pc
    movementIO:installDoctrineHover()
    pc.bShowMouseCursor = true
    pc.bEnableClickEvents = true
    pc.bEnableMouseOverEvents = true
    pc.bCanSelectEnemy = true
    pc.bCanClearSelection = true

    local input = StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary')
    if valid(input) and inputController ~= pc:GetFullName() then
        input:SetInputMode_GameAndUIEx(pc,nil,2,false,false) -- LockAlways; Alt+Tab releases focus
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
    movementIO:installDoctrineHover()
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
            if name:find('ConstructionYard_C_') and not name:find('Conformation') and not name:find('Ghost') and movementIO:alive(actor) then bases[#bases+1]=actor end
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
    for index,key in ipairs({Key.Q,Key.W,Key.E,Key.R,Key.T,Key.Y,Key.A,Key.S}) do
        bind(key,function()
            liveWidgets('TedThirdPartySpectatorHud',function(hud)
                if not hud:IsInViewport() then return end
                local selector=hud.StatsOverview.StatsSelector
                if valid(selector) and selector:GetOptionsCount()>=index then
                    selector:SelectOptionByIndex(index-1)
                end
            end)
        end)
    end
    local hudHidden=false
    bind(Key.U,function()
        movementIO:clearDoctrinePopup()
        local panels={{'VerticalBox_Minimap','MinimapShow_ButtonClick'},
            {'PlayerInfoPanel','PlayerListShow_ButtonClick'},{'StatsOverview','SingularStatShow_ButtonClick'}}
        liveWidgets('TedThirdPartySpectatorHud',function(widget)
            if not widget:IsInViewport() then return end
            for _,panel in ipairs(panels) do
                local visibility=widget[panel[1]]:GetVisibility()
                local shown=visibility~=1 and visibility~=2
                if shown~=hudHidden then widget[panel[2]](widget) end
            end
        end)
        hudHidden=not hudHidden
        movementIO.healthHidden=hudHidden
        -- Panel callbacks can invalidate the replay visibility channels even
        -- while the HUD is hidden; the world itself must remain visible.
        movementIO.visible={}
        hudVisibilityRefresh=true
        if not hudHidden then
            -- Game HUD show buttons may rebuild their minimap and refresh the
            -- native visibility channels. Replay presentation must follow them.
            movementIO:resetMarkers()
            configuredWidgets={} -- rebuilt widgets may reuse their old names
        end
        status('viewer_hud',hudHidden and 'Observer panels hidden through their buttons' or 'Observer panels shown through their buttons')
    end)
    bind(Key.C,function(pc)
        local selected = pc:GetSelectedPawns()
        local target = selected and selected[1]
        -- UE4SS returns selected array entries as RemoteUnrealParam wrappers.
        local unwrapped,value = pcall(function() return target:get() end)
        if unwrapped then target=value end
        if valid(target) and movementIO:alive(target) and target ~= followTarget then
            followTarget = target
            status('viewer_tracking',target:GetFullName())
        else
            followTarget = nil
            status('viewer_tracking','Camera tracking off')
        end
    end)
    bind(Key.F7,function(pc)
        if viewerFinished then return end
        local index=2
        for i,speed in ipairs(speeds) do if speed==viewerSpeed then index=i end end
        setViewerSpeed(pc,speeds[index % #speeds + 1])
    end)
    for _,speed in ipairs({1,2,4}) do
        bind(0x30+speed,function(pc)
            if not viewerFinished then setViewerSpeed(pc,speed) end
        end)
    end
    bind(Key.F8,function(pc) if not viewerFinished then command(pc,'demopause') end end)
    local inputPending, inputErrors, mouseWasDown = false, 0, false
    gameLoop(16,function()
        if viewerStopped or viewerFinished then return true end
        if travelling or inputPending then return false end
        inputPending = true
        local function tick()
            if viewerStopped or travelling then inputPending=false; return end
            local ok,err = pcall(function()
                local subsystem = FindFirstOf('ReplaySubsystem')
                if not valid(subsystem) or not subsystem:IsPlaying() then followTarget=nil; return end
                local movementOK,movementError=pcall(function() movementIO:play(subsystem) end)
                if not movementOK then movementIO:fail(movementError) end
                local pc = movementIO.audioController
                if not valid(pc) then pc=getLocalPlayerController() end
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
                    if movementIO:alive(followTarget) then position=followTarget:K2_GetActorLocation() else followTarget=nil end
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
gameLoop(100,function()
    if mode ~= 'record' then return true end
    if recordingWorld then
        local ok,err=pcall(function()
            local pc=getLocalPlayerController()
            if not valid(pc) or pc:GetWorld():GetFullName()~=recordingWorld then movementIO:close();return end
            local subsystem=FindFirstOf('ReplaySubsystem')
            if not valid(subsystem) or not subsystem:IsRecording() then movementIO:close();return end
            local actors=FindAllOf('TedPawn') or {}
            movementIO:record(subsystem,recordingName,actors)
        end)
        if not ok then movementIO:fail(err);return true end
    end
    return false
end)
local pending = false
local errors = 0
gameLoop(1000, function()
    if viewerStopped or viewerFinished then return true end
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
            if mode=='play' and viewerInitialized and movementIO.codec then
                if replayDuration==nil then replayDuration=movementIO.codec.duration(os.getenv('LOCALAPPDATA')..'/Tempest/Saved/Demos/'..replay..'.replay') or false end
                if replayDuration and FindFirstOf('ReplaySubsystem'):GetReplayCurrentTime()>=replayDuration-0.02 then
                    finishReplay(pc);return
                end
            end
            local control = read(home .. 'control.txt')
            if control then
                os.remove(home .. 'control.txt')
                control = control:gsub('\r\n','\n')
                local speed = control:match('^'..session..'\nspeed=([%d.]+)\n$')
                if mode == 'play' and speed then
                    local value=tonumber(speed)
                    for _,allowed in ipairs(speeds) do if value==allowed then viewerSpeed=value;appliedSpeed=nil end end
                end
                if control == session .. '\nstop\n' then
                    movementIO:close()
                    command(pc,'demostop')
                    status('stop_requested','Requested replay/recording stop')
                    return
                end
            end
            local world = pc:GetWorld()
            if not valid(world) then return end
            local key = world:GetFullName()
            if key ~= worldKey then
                if mode=='record' then movementIO:close() end
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
                inspect('movement_units',function() return movementIO.applied or 0 end)
                if movementIO.reader and not movementIO.failed then
                    write(home..'movement-state.txt',session..'\n'..replay..'\nplaying\nframes='..movementIO.reader.frames..'\nunits='..(movementIO.applied or 0))
                end
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
                if not playSent then
                    local safety=(read(home..'safety.txt') or ''):gsub('\r\n','\n')
                    if not safety:find(session..'\nready\n',1,true) then
                        if safety:find(session..'\nerror\n',1,true) then
                            if not movementIO.safetyReported then
                                movementIO.safetyReported=true
                                status('viewer_safety_error',safety:gsub('\n',' · '))
                            end
                        end
                        return false
                    end
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
                        if appliedSpeed ~= viewerSpeed then setViewerSpeed(pc,viewerSpeed) end
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
                            local neutral=actor:IsA('/Script/Tempest.TedConformationBase')
                            if movementIO:isGarrisoned(actor) then actor:SetActorHiddenInGame(true) end
                            if movementIO:isPresentationPawn(actor) and not movementIO:isDead(actor) and not movementIO:isGarrisoned(actor) and (neutral or actor:IsAlive() or (movementIO.visible and movementIO.visible[name])) and (neutral or not (movementIO.absent and movementIO.absent[name])) and (neutral or not actor:IsInContainer()) then
                                local first=not viewerActors[name]
                                if first or actor.bHidden or hudVisibilityRefresh then
                                    actor:K2_SetDefaultVisibility(true,true)
                                    actor:K2_OnVisibilityChanged(true)
                                end
                                if not viewerActors[name] then
                                    -- Replay-created structures otherwise retain their concealed,
                                    -- underground construction pose. Use the game's visibility init.
                                    if actor:IsA('/Script/Tempest.TedStructureBase') then
                                        actor:SetInitiallyVisible()
                                        if not movementIO.buildingStates or not movementIO.buildingStates[name] then movementIO:buildingVisuals(actor) end
                                    end
                                    viewerActors[name] = true
                                end
                                if first then actor:SetActorHiddenInGame(true) end
                                actor:SetActorHiddenInGame(false)
                                actor.bHidden = false
                                local mesh = actor.MeshComp
                                if valid(mesh) then
                                    if first then mesh:SetVisibility(false,false) end
                                    mesh:SetHiddenInGame(false,false); mesh:SetVisibility(true,false)
                                    mesh:SetComponentTickEnabled(true)
                                    if mesh:IsA('/Script/Engine.SkeletalMeshComponent') then
                                        mesh.VisibilityBasedAnimTickOption = 0
                                        mesh.bPauseAnims = false
                                    end
                                end
                                if neutral then movementIO:neutralMesh(actor) end
                            end
                        end
                        hudVisibilityRefresh=false
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
                    if movementIO.writer then
                        local ok,err=pcall(function()
                            local subsystem=FindFirstOf('ReplaySubsystem')
                            if valid(subsystem) and subsystem:IsRecording() then movementIO:record(subsystem,recordingName,FindAllOf('TedPawn') or {}) end
                        end)
                        if not ok then status('movement_error',tostring(err)) end
                    end
                    movementIO:close(); command(pc, 'demostop'); recordingWorld = nil
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
