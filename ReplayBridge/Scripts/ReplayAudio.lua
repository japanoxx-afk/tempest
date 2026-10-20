-- Presentation-only native impact audio. No attack, damage, hit or gameplay-cue execution.
local M={}
local function valid(o) return o~=nil and o:IsValid() end
local function distance(a,b) return (a.X-b.X)^2+(a.Y-b.Y)^2+(a.Z-b.Z)^2 end
local function point(p) return {X=p.X,Y=p.Y,Z=p.Z} end
function M.new(api)
 local s={api=api,catalog={},pending={},owned={},recent={},hits={},stats={queued=0,played=0,native=0,missing=0,noTag=0,noCue=0,spawnFailed=0,dropped=0},closed=false}
 function s:catalogSounds()
  if self.loaded then return end;self.loaded=true
  api.objects(function(o)
   if o:IsA('/Script/Tempest.TedGameplayCueNotify_HitBurst') or o:IsA('/Script/Tempest.TedGameplayCueNotify_HitActor') then
    local ok,tag=pcall(function()return o.GameplayCueTag.TagName:ToString()end)
    local sound=o.Sound
    if ok and valid(sound) and sound:IsA('/Script/Engine.SoundBase') then
     local path=sound:GetFullName()
     if path:find(' /Game/Tempest/Audio/Effects/',1,true) then self.catalog[tag]=sound end
    end
   end
  end)
 end
 function s:observed(sound,location,time)
  if self.closed or self.spawning or not valid(sound) then return end
  self.recent[#self.recent+1]={sound=sound:GetFullName(),position=point(location),time=time}
 end
 function s:hit(actor,time)
  if self.closed then return end
  local key=actor:GetFullName();local last=self.hits[key]
  if last and time-last<0.03 then return end -- inherited/base callbacks for the same native impact
  self.hits[key]=time
  self:catalogSounds()
  local ok,tag=pcall(function()return actor.HitGameplayCue.GameplayCueTag.TagName:ToString()end)
  if not ok then self.stats.missing=self.stats.missing+1;self.stats.noTag=self.stats.noTag+1;return end
  local target=actor.Target
  local suffix
  if valid(target) then
   if target:IsA('/Script/Tempest.TedInfantry') then suffix='Infantry'
   elseif target:IsA('/Script/Tempest.TedStructureBase') then suffix='Structures'
   elseif target:IsA('/Script/Tempest.TedUnitBase') then suffix='Vehicles' end
  end
  local sound=(suffix and self.catalog[tag:gsub('%.Default$','.'..suffix)]) or self.catalog[tag]
  if not valid(sound) then self.stats.missing=self.stats.missing+1;self.stats.noCue=self.stats.noCue+1;self.lastMissingTag=tag;return end
  if #self.pending>=256 then self.stats.dropped=self.stats.dropped+1;return end
  local location=actor:K2_GetActorLocation()
  -- A post-hit Blueprint may already have returned its pooled actor to storage.
  -- Use the still-recorded target location if the pool reset moved it far away.
  local got,destination=pcall(function()return actor.TargetLocation end)
  if got and destination and type(destination.X)=='number' and distance(location,destination)>1000^2 then location=destination end
  self.pending[#self.pending+1]={sound=sound,position=point(location),time=time}
  self.stats.queued=self.stats.queued+1
 end
 function s:update(time,paused,context)
  if self.closed then return end
  local active={}
  for _,entry in ipairs(self.owned) do
   if valid(entry.component) then
    if entry.paused~=paused then
     entry.component:SetPaused(paused)
     if paused then entry.pauseTime=api.clock() elseif entry.pauseTime then entry.created=entry.created+api.clock()-entry.pauseTime;entry.pauseTime=nil end
     entry.paused=paused
    end
    -- A misconfigured looping asset must not leak from this one-shot path.
    if not paused and api.clock()-entry.created>8 then entry.component:Stop();if api.destroy then api.destroy(entry.component) end
    elseif entry.component:IsPlaying() or paused then active[#active+1]=entry
    elseif api.destroy then api.destroy(entry.component) end
   end
  end
  self.owned=active
  if paused or not valid(context) then return end
  local recent={};for _,entry in ipairs(self.recent) do if time-entry.time<0.5 then recent[#recent+1]=entry end end;self.recent=recent
  local pending={}
  for _,event in ipairs(self.pending) do
   if time-event.time<0.06 then pending[#pending+1]=event
   else
    local duplicate=false;local name=event.sound:GetFullName()
    for i,entry in ipairs(self.recent) do
     if not entry.used and name==entry.sound and math.abs(event.time-entry.time)<=0.2 and distance(event.position,entry.position)<=150^2 then entry.used=true;duplicate=true;break end
    end
    if duplicate then self.stats.native=self.stats.native+1
    elseif time-event.time>1 or #self.owned>=64 then self.stats.dropped=self.stats.dropped+1
    else
     self.spawning=true
     local ok,component=pcall(api.spawn,context,event.sound,event.position)
     self.spawning=false
     if ok and valid(component) then
      self.owned[#self.owned+1]={component=component,created=api.clock(),paused=false};self.stats.played=self.stats.played+1
     else self.stats.missing=self.stats.missing+1;self.stats.spawnFailed=self.stats.spawnFailed+1;self.lastSpawnError=ok and 'invalid audio component' or tostring(component) end
    end
   end
  end
  self.pending=pending
  -- Pooled projectiles may live a long time; retain only recent duplicate keys.
  for key,last in pairs(self.hits)do if time-last>2 then self.hits[key]=nil end end
 end
 function s:close()
  if self.closed then return end;self.closed=true
  for _,entry in ipairs(self.owned)do if valid(entry.component) then entry.component:Stop();if api.destroy then api.destroy(entry.component) end end end
  self.pending={};self.owned={};self.recent={};self.hits={};self.catalog={}
 end
 return s
end
return M
