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
local movementIO={}
function movementIO:isDead(actor)
    if self.visualDeaths and self.visualDeaths[actor:GetFullName()] then return true end
    local ok,dead=pcall(function() return actor.PawnDeath.bDied end)
    return ok and dead==true
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
    self.animationFrames={}
    self.projectiles=nil;self.projectileTime=nil;self.doctrineApplied=nil
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
    self.markerTime=nil
end
function movementIO:updateLocomotion(actor,velocity)
    local mesh=actor.MeshComp
    if not valid(mesh) then return end
    actor:SetActorTickEnabled(true)
    mesh:SetComponentTickEnabled(true)
    local anim=mesh:GetAnimInstance()
    if not valid(anim) or not anim:IsA('/Script/Tempest.TedAnimInstance_Infantry') then return end
    local definition=actor:GetDefinitionAsset()
    if not valid(definition) then return end
    local maxSpeed=definition.MovementSpeed
    if type(maxSpeed)~='number' or maxSpeed<=0 or maxSpeed>10000 then return end
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
    anim.bUseMultiThreadedAnimationUpdate=false
    mesh.bEnableUpdateRateOptimizations=false
    self.animationFrames[anim:GetFullName()]={speed=math.sqrt(velocity.X^2+velocity.Y^2),maxSpeed=maxSpeed}
end
function movementIO:record(subsystem,name,actors)
    if not self.codec or self.failed then return end
    if self.name~=name then
        self:close();self.name=name;self.frames=0;self.units=0;self.recordedBuildings={};self.recordedPawns={};self.pendingDeaths={}
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
            if not seen[key] then unit.building=3;units[#units+1]=unit;seen[key]=true end
        end
        if valid(actor) and self.recordedPawns[actor:GetFullName()] and self:isDead(actor) then
            self.pendingDeaths[actor:GetFullName()]=self.recordedPawns[actor:GetFullName()]
        end
    end
    for _,unit in pairs(self.pendingDeaths) do
        local key=self.codec.key(unit.class,unit.owner,unit.entity)
        unit.dead=true
        if not seen[key] then units[#units+1]=unit;seen[key]=true
        else
            for _,present in ipairs(units) do
                if self.codec.key(present.class,present.owner,present.entity)==key then present.dead=true;break end
            end
        end
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
function movementIO:deathVisuals(actor,dead)
    if not dead then return end
    self.visualDeaths=self.visualDeaths or {};self.deathPresented=self.deathPresented or {}
    local name=actor:GetFullName()
    if not self.deathPresented[name] then
        if self.absent and self.absent[name] then actor:SetActorHiddenInGame(false);self.absent[name]=nil end
        actor:SetActorTickEnabled(true)
        local mesh=actor.MeshComp
        if valid(mesh) then mesh:SetComponentTickEnabled(true) end
        -- Native death state and cosmetic delivery are separate: bDied can be
        -- replicated even though the Blueprint effect never ran in this demo.
        self.deathPresented[name]=true
        actor:ReceiveOnDeath()
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
            actor:SetActorTickEnabled(true)
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
    self.doctrineApplied=self.doctrineApplied or {}
    for _,data in ipairs(FindAllOf('TedPlayerData') or {}) do
        if valid(data) then
            local owner=data:GetOwningPlayerState()
            local paths=valid(owner) and snapshot[owner:GetTedPlayerID()]
            if paths then
                local key=data:GetFullName();local signature=table.concat(paths,'|')
                if self.doctrineApplied[key]~=signature then
                    local assets={};local complete=true
                    for _,path in ipairs(paths) do
                        local asset=LoadAsset(path)
                        if valid(asset) and asset:IsA('/Script/Tempest.TedDoctrineDefinition') then assets[#assets+1]=asset else complete=false end
                    end
                    if complete then
                        -- UI-readable replay state only: do not grant research,
                        -- apply gameplay effects or dispatch player commands.
                        data.ResearchedDoctrines=assets
                        for _,widget in ipairs(FindAllOf('TedPlayerDataWidget') or {}) do
                            if valid(widget) then
                                local target=widget:GetTargetPlayerData()
                                if valid(target) and target:GetFullName()==key then widget:OnResearchedDoctrinesChange_Handler_Native(data) end
                            end
                        end
                        self.doctrineApplied[key]=signature
                    end
                end
            end
        end
    end
end
function movementIO:updateProjectiles(time)
    if mode~='play' then return end
    self.projectiles=self.projectiles or {}
    self.projectileHooks=self.projectileHooks or {}
    local function install(path)
        if self.projectileHooks[path] then return end
        self.projectileHooks[path]=true
        RegisterHook(path,function(context)
            if not self.projectiles then return end
            local actor=context:get();if not valid(actor) then return end
            local key=actor:GetFullName();local old=self.projectiles[key]
            if old and old.retired and valid(actor.ProjectileMovement) then
                actor:SetActorTickEnabled(true);actor.ProjectileMovement:SetComponentTickEnabled(true)
            end
            self.projectiles[key]=nil -- pooled actor, new shot
        end)
    end
    install('/Script/Tempest.TedProjectile:ReceiveOnProjectileFired')
    if self.projectileTime and time-self.projectileTime<0.05 then return end
    self.projectileTime=time
    local active={}
    for _,actor in ipairs(FindAllOf('TedProjectile') or {}) do
        if valid(actor) and valid(actor.ProjectileMovement) then
            local cls=actor:GetClass();local classPath=cls:GetFullName()
            if not self.projectileHooks[classPath] then
                self.projectileHooks[classPath]=true
                cls:ForEachFunction(function(fn)
                    if fn:GetFName():ToString()=='ReceiveOnProjectileFired' then
                        install(classPath:gsub('^BlueprintGeneratedClass ',''):gsub('^Class ','')..':ReceiveOnProjectileFired')
                    end
                end)
            end
        end
        -- Tracer Blueprints can keep bHidden=true while their FX components are
        -- visible. Movement activity, rather than actor visibility, owns a shot.
        if valid(actor) and valid(actor.ProjectileMovement) and actor.ProjectileMovement:IsActive() then
            local key=actor:GetFullName();local p=actor:K2_GetActorLocation()
            local start=actor.StartLocation;local dest=actor.TargetLocation
            local signature=table.concat({start.X,start.Y,start.Z,dest.X,dest.Y,dest.Z},':')
            local shot=self.projectiles[key]
            if not shot or shot.signature~=signature then shot={signature=signature,time=time};self.projectiles[key]=shot end
            active[key]=shot
            local target=valid(actor.Target) and actor.Target:K2_GetActorLocation() or dest
            local dx,dy,dz=target.X-start.X,target.Y-start.Y,target.Z-start.Z
            local range=math.sqrt(dx*dx+dy*dy+dz*dz)
            local x,y,z=p.X-start.X,p.Y-start.Y,p.Z-start.Z
            -- Only retire overshot presentation actors. Never call damage/hit
            -- gameplay functions or destroy pooled actors needed by later shots.
            local passed=range>1 and (x*dx+y*dy+z*dz)/(range*range)>1.05
            if passed or time-shot.time>30 then
                actor:SetActorHiddenInGame(true)
                actor.ProjectileMovement:Deactivate();actor.ProjectileMovement:SetComponentTickEnabled(false)
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
    for key,shot in pairs(self.projectiles) do if not active[key] and not shot.retired then self.projectiles[key]=nil end end
end
function movementIO:play(subsystem)
    self.animationFrames={}
    if mode~='play' or not valid(subsystem) or not subsystem:IsPlaying() then return end
    if not self.projectileFailed then
        local ok,err=pcall(function() self:updateProjectiles(subsystem:GetReplayCurrentTime()) end)
        if not ok then self.projectileFailed=true;status('projectile_visual_error',tostring(err)) end
    end
    if not self.codec or self.failed then return end
    if not self.opened then
        self.opened=true
        local path=os.getenv('LOCALAPPDATA')..'/Tempest/Saved/Demos/'..replay..'.movement'
        self.catalog=self.codec.catalog(path,replay)
        self.reader=self.codec.reader(path,replay)
        if self.reader then status('movement_playback','Applying received unit transforms from '..replay..'.movement')
        else status('movement_missing','No movement companion; using native replay data only') end
    end
    if not self.reader then return end
    local time=subsystem:GetReplayCurrentTime()
    local samples=self.reader:at(time);local actors={}
    if not self.doctrineFailed then
        local ok,err=pcall(function() self:restoreDoctrines(self.reader.doctrines) end)
        if not ok then self.doctrineFailed=true;status('doctrine_visual_error',tostring(err)) end
    end
    if not self.reader.following and self.reader.previous and time>self.reader.previous.time+0.5 then
        self.visible={};self.absent={};self.applied=0;return
    end
    self.origins=self.origins or {};self.bindings=self.bindings or {};self.births=self.births or {}
    local candidates={}
    for _,actor in ipairs(FindAllOf('TedPawn') or {}) do
        if valid(actor) then
            self:watchDeath(actor)
            local ok,dead=pcall(function() return actor.PawnDeath.bDied end)
            if ok and dead then self:deathVisuals(actor,true) end
            local name=actor:GetFullName()
            if self:isPresentationPawn(actor) then
                self.births[name]=self.births[name] or time
                -- Unbound actors can initially have an unreplicated spawn pose.
                -- Refresh that pose until matched; never remap a bound actor.
                if not self.managed or not self.managed[name] then
                    local p=actor:K2_GetActorLocation()
                    self.origins[name]={X=p.X,Y=p.Y,Z=p.Z}
                end
                candidates[#candidates+1]={name=name,actor=actor,position=self.origins[name],
                    class=actor:GetClass():GetFName():ToString(),owner=actor:GetOwningPlayerID(),born=self.births[name],eligible=not self:isDead(actor)}
            end
        end
    end
    local matched=self.codec.match(self.reader.tracks,samples,candidates,self.bindings)
    for key,candidate in pairs(matched) do actors[key]=candidate.actor end
    local applied,visible,absent,containerCorrections=0,{},{},0
    self.managed=self.managed or {}
    for key,sample in pairs(samples) do
        local actor=actors[key]
        if actor then self:deathVisuals(actor,sample.dead or sample.building==3) end
        if actor then self:buildingVisuals(actor,sample.building) end
        if actor and not self:isDead(actor) and self:siteVisuals(actor,key,sample,time) then
            local name=actor:GetFullName();visible[name]=true;self.managed[name]=true
            if actor:IsInContainer() then containerCorrections=containerCorrections+1 end
            if not self.visible or not self.visible[name] then
                actor:K2_SetDefaultVisibility(true,true)
                actor:K2_OnVisibilityChanged(true)
            end
            actor:SetActorHiddenInGame(false)
            actor:K2_SetActorLocation(sample.position,false,{},true)
            actor:K2_SetActorRotation(sample.rotation,true)
            if actor:IsA('/Script/Tempest.TedUnitBase') then
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
        if self.managed[name] and not visible[name] then
            absent[name]=true
            -- Explicit native death owns its wreck/effects lifecycle. Absence alone
            -- may mean fog, garrison or replacement, and is never a death event.
            if not self:isDead(actor) then actor:SetActorHiddenInGame(true) end
        end
    end
    self.visible=visible
    self.absent=absent
    self.applied=applied
    if not self.proofTime or time-self.proofTime>=1 then
        self.proofTime=time
        write(home..'playback-state.txt',session..'\ntime='..time..'\napplied='..applied..'\nstale_container_overrides='..containerCorrections..'\nretired_projectiles='..(self.retiredProjectileCount or 0))
    end
    if not self.markerFailed and (not self.markerTime or time-self.markerTime>=0.1) then
        self.markerTime=time
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
    for _,widget in ipairs(FindAllOf('TedMinimapWidget') or {}) do
        if valid(widget) and valid(widget.MinimapImage) then
            local canvas=widget.MinimapImage:GetParent()
            if valid(canvas) and canvas:IsA('/Script/UMG.CanvasPanel') then
                local name=widget:GetFullName();local pins=self.maps[name] or {};self.maps[name]=pins
                local bounds=utils:GetWorldBounds(widget);local size=widget:GetMinimapSize();local seen={}
                local origin=widget.MinimapImage.Slot:GetPosition()
                for key,actor in pairs(actors) do
                    local sample=samples[key]
                    if sample and not actor:IsAlive() and not self:isDead(actor) and not (self.absent and self.absent[actor:GetFullName()]) then
                        seen[key]=true
                        local pin=pins[key]
                        if not valid(pin) then
                            pin=StaticConstructObject(imageClass,widget)
                            assert(valid(pin),'Minimap image allocation failed')
                            canvas:AddChildToCanvas(pin);pin:SetVisibility(3) -- HitTestInvisible: clicks pass through
                            pins[key]=pin
                        end
                        local color=utils:GetPlayerColorPreset(widget,actor:GetOwningPlayerID())
                        pin:SetColorAndOpacity(color.PrimaryColor)
                        local result={X=0,Y=0}
                        ui:CalculateMinimapLocation(bounds,{X=sample.position.X,Y=sample.position.Y},size,result)
                        local width=actor:IsA('/Script/Tempest.TedStructureBase') and 5 or 3
                        pin.Slot:SetSize({X=width,Y=width})
                        pin.Slot:SetPosition({X=origin.X+result.X-width/2,Y=origin.Y+result.Y-width/2})
                        pin.Slot:SetZOrder(10)
                    end
                end
                for key,pin in pairs(pins) do
                    if not seen[key] then if valid(pin) then pin:RemoveFromParent() end;pins[key]=nil end
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
    status('viewer_stopped',reason)
end
local function exitViewer(closeApplication)
    if mode~='play' or not viewerInitialized or viewerStopped then return end
    local pc=getLocalPlayerController()
    local subsystem=FindFirstOf('ReplaySubsystem')
    if not valid(pc) or not valid(subsystem) or not subsystem:IsPlaying() then return end
    pc:GetWorld():K2_GetWorldSettings().PauserPlayerState=nil
    stopViewer('Replay exit requested; callbacks released')
    -- Use local engine exit/travel without depending on live-match surrender
    -- acknowledgement, including when the replay is paused at EOF.
    if closeApplication then write(home..'shutdown.txt',session) end
    command(pc,closeApplication and 'exit' or 'open /Game/Tempest/Maps/MainMenu/MAP_MainMenu_P')
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
    if valid(h.description) then h.description:RemoveFromParent() end
    if valid(h.tip) then h.tip:RemoveFromParent() end
end
function movementIO:activateDoctrineTooltip(hud,source,original,cls)
    if self.creatingDoctrine or not valid(source) or not source:IsHovered() then return end
    local previous=self.viewerDoctrinePopup
    if previous and valid(previous.source) and previous.source:GetFullName()==source:GetFullName() then
        original:SetVisibility(2);return
    end
    self:clearDoctrinePopup()
    local library=StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary')
    if not valid(library) then return end
    self.creatingDoctrine=true
    local tip=library:Create(source:GetOwningPlayer(),cls,source:GetOwningPlayer())
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
                classes[name]=slot.CustomTooltipClass
                -- This read-only clone owns its detail popup. The native HUD's
                -- automatic tooltip must not compete with it for hover/focus.
                slot.CustomTooltipClass=StaticFindObject('/Script/Tempest.ReplayDisabledTooltip')
                slot.bTrackAsWidgetUnderCursor=false
                icons[#icons+1]=slot
            end
        end
    end
    original:SetVisibility(2)
    self.viewerDoctrinePopup={source=source,tip=tip,icons=icons,classes=classes,misses=0}
end
function movementIO:installDoctrineHover()
    if not self.doctrineHook then
        self.doctrineHook=true
        gameLoop(50,function()
            if viewerStopped or travelling then self:clearDoctrinePopup();return viewerStopped end
            local h=self.viewerDoctrinePopup
            if h then
                if not valid(h.source) or not valid(h.tip) then self:clearDoctrinePopup();return false end
                local hovered
                for _,icon in ipairs(h.icons) do if valid(icon) and icon:IsHovered() then hovered=icon;break end end
                if h.source:IsHovered() or h.tip:IsHovered() or hovered then h.misses=0 else h.misses=h.misses+1 end
                local iconKey=hovered and hovered:GetFullName() or nil
                h.iconMisses=hovered and 0 or (h.iconMisses or 0)+1
                if iconKey~=h.iconKey and (hovered or h.iconMisses>=3) then
                    if valid(h.description) then h.description:RemoveFromParent() end
                    h.description=nil;h.icon=hovered;h.iconKey=iconKey
                    local cls=iconKey and h.classes[iconKey]
                    if hovered and valid(cls) then
                        local library=StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary')
                        local description=library:Create(h.source:GetOwningPlayer(),cls,h.source:GetOwningPlayer())
                        description.TargetWidget=hovered
                        description.DesiredDisplayParams=hovered.CustomTooltipDefaultDisplayParams
                        description:OnTooltipShown()
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
                        h.description=description
                    end
                end
                if h.misses>=6 then self:clearDoctrinePopup() end
            else
                local subsystem=FindFirstOf('ReplaySubsystem')
                if not valid(subsystem) or not subsystem:IsPlaying() then return false end
                for _,tip in ipairs(FindAllOf('WBP_ThirdPartySpectator_Doctrines_Tooltip_C') or {}) do
                    if valid(tip) and tip:IsInViewport() then
                        local source=tip:GetTargetWidget()
                        if valid(source) and source:IsHovered() and source:IsCustomTooltipShown() then
                            self:activateDoctrineTooltip(source:GetHUD(),source,tip,source.CustomTooltipClass);break
                        end
                    end
                end
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
    local settings=pc:GetWorld():K2_GetWorldSettings()
    if not valid(settings.PauserPlayerState) then command(pc,'demopause') end
    local ok,err=pcall(function()
        liveWidgets('TedThirdPartySpectatorHud',function(hud)
            if not hud:IsInViewport() then return end
            local canvas=hud.Box_StatsOverview:GetParent()
            if not valid(canvas) or not canvas:IsA('/Script/UMG.CanvasPanel') then return end
            local label=StaticConstructObject(StaticFindObject('/Script/UMG.TextBlock'),hud)
            canvas:AddChildToCanvas(label)
            label:SetText(FText('리플레이 종료 · 기록된 마지막 시점입니다'))
            label:SetColorAndOpacity({SpecifiedColor={R=1,G=1,B=1,A=1},ColorUseRule=0})
            local font=label.Font;font.Size=24;label:SetFont(font)
            label:SetVisibility(3)
            label.Slot:SetAnchors({Minimum={X=0.5,Y=0.12},Maximum={X=0.5,Y=0.12}})
            label.Slot:SetAlignment({X=0.5,Y=0})
            label.Slot:SetAutoSize(true);label.Slot:SetPosition({X=0,Y=0});label.Slot:SetZOrder(100)
        end)
    end)
    status('viewer_finished','리플레이 종료 · 저장된 마지막 시점. 승패 정보가 없는 파일에서는 결과를 추정하지 않습니다.'..(ok and '' or ' / banner: '..tostring(err)))
end
local function configureViewer(pc)
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
                            if movementIO:isPresentationPawn(actor) and not movementIO:isDead(actor) and (neutral or actor:IsAlive() or (movementIO.visible and movementIO.visible[name])) and not (movementIO.absent and movementIO.absent[name]) and not actor:IsInContainer() then
                                local first=not viewerActors[name]
                                if first or actor.bHidden or hudVisibilityRefresh then
                                    actor:K2_SetDefaultVisibility(true,true)
                                    actor:K2_OnVisibilityChanged(true)
                                end
                                if not viewerActors[name] then
                                    -- Replay-created structures otherwise retain their concealed,
                                    -- underground construction pose. Use the game's visibility init.
                                    if not neutral and actor:IsA('/Script/Tempest.TedStructureBase') then
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
