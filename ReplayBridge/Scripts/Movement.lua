-- Local, data-only movement companion. No RPCs, engine writes or executable file content.
local M = {}
-- Installed UE local replay container v7: magic, version, custom-version
-- container (GUID + version entries), then recorded length in milliseconds.
-- Unknown/truncated formats deliberately have no guessed end time.
function M.duration(path)
    local f=io.open(path,'rb');if not f then return nil end
    local header=f:read(656) or '';f:close()
    local function uint(offset)
        local a,b,c,d=header:byte(offset+1,offset+4)
        if not d then return nil end
        return a+b*256+c*65536+d*16777216
    end
    if uint(0)~=0x1ca2e27f or uint(4)~=7 then return nil end
    local count=uint(8);if not count or count>32 then return nil end
    local ms=uint(12+count*20)
    if ms and ms>0 and ms<=86400000 then return ms/1000 end
end
function M.velocity(a,b,dt)
    if not b or not dt or dt<=0 then return {X=0,Y=0,Z=0} end
    local v={X=(b.X-a.X)/dt,Y=(b.Y-a.Y)/dt,Z=(b.Z-a.Z)/dt}
    -- Teleports are position changes, not locomotion animation.
    if v.X*v.X+v.Y*v.Y+v.Z*v.Z>10000^2 then return {X=0,Y=0,Z=0} end
    return v
end
local function finite(n) return type(n)=='number' and n==n and math.abs(n)<1e9 end
local function token(s) return type(s)=='string' and #s<=160 and s:match('^[%w_%-]+$') end
function M.assetPath(s)
    return type(s)=='string' and #s<=240 and s:match('^/Game/Tempest/[%w_/]+%.[%w_]+$')~=nil
end
local function fields(line)
    line=line:gsub('\r$','')
    if #line>1024 then error('Movement line too long') end
    local out={};for value in (line..'\t'):gmatch('(.-)\t') do out[#out+1]=value end;return out
end
function M.key(class,owner,entity)
    if not token(class) or not finite(owner) or owner%1~=0 or not finite(entity) or entity%1~=0 or entity<=0 then return nil end
    return class..':'..owner..':'..entity
end
function M.writer(path,name)
    assert(token(name),'Invalid replay name')
    local f=assert(io.open(path,'wb'))
    assert(f:write('TEMPEST_MOVEMENT\t4\t'..name..'\n'));assert(f:flush())
    local w={file=f,ids={},count=0,frames=0,last=-1}
    function w:frame(time,units,doctrines)
        assert(finite(time) and time>=0 and time>=self.last,'Movement clock went backwards')
        if time==self.last then return end
        assert(#units<=20000,'Too many movement units')
        local rows={string.format('F\t%.6f\n',time)};local seen={}
        for owner,assets in pairs(doctrines or {}) do
            assert(finite(owner) and owner%1==0 and owner>=0 and owner<256 and #assets<=64,'Invalid doctrine player')
            rows[#rows+1]='S\t'..owner..'\n'
            local seenAssets={}
            for _,path in ipairs(assets) do
                assert(M.assetPath(path) and not seenAssets[path],'Invalid doctrine asset')
                seenAssets[path]=true;rows[#rows+1]='R\t'..owner..'\t'..path..'\n'
            end
        end
        for _,u in ipairs(units) do
            local key=M.key(u.class,u.owner,u.entity)
            assert(key and not seen[key],'Duplicate/invalid movement identity');seen[key]=true
            local id=self.ids[key]
            if not id then
                self.count=self.count+1;id=self.count;self.ids[key]=id
                assert(id<=1000000,'Too many movement identities')
                rows[#rows+1]=table.concat({'U',id,u.class,u.owner,u.entity},'\t')..'\n'
            end
            local p=u.position;local r=u.rotation
            for _,v in ipairs({p.X,p.Y,p.Z,r.Pitch,r.Yaw,r.Roll}) do assert(finite(v),'Invalid movement transform') end
            rows[#rows+1]=string.format('P\t%d\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\n',id,p.X,p.Y,p.Z,r.Pitch,r.Yaw,r.Roll)
            if u.building then
                assert(u.building==1 or u.building==2 or u.building==3,'Invalid building state')
                rows[#rows+1]=string.format('B\t%d\t%d\n',id,u.building)
            end
            if u.dead then rows[#rows+1]='D\t'..id..'\n' end
            if u.site then
                assert(finite(u.site.footprint) and u.site.footprint%1==0 and u.site.footprint>=0 and u.site.footprint<256 and finite(u.site.progress) and u.site.progress>=0 and u.site.progress<=1,'Invalid construction site')
                rows[#rows+1]=string.format('C\t%d\t%d\t%.6f\n',id,u.site.footprint,u.site.progress)
            end
        end
        assert(self.file:write(table.concat(rows)));assert(self.file:flush())
        self.last=time;self.frames=self.frames+1
    end
    function w:close()
        if self.file then
            self.file:write('E\n');self.file:close();self.file=nil
        end
    end
    return w
end
function M.reader(path,name)
    local f=io.open(path,'rb');if not f then return nil end
    local header=(f:read('*l') or ''):gsub('\r$','')
    local version
    for i=1,4 do if header=='TEMPEST_MOVEMENT\t'..i..'\t'..name then version=i end end
    if not version then f:close();error('Movement companion header/name mismatch') end
    local r={file=f,definitions={},identities={},tracks={},deaths={},deliveredDeaths={},last=-1,frames=0}
    function r:close() if self.file then self.file:close();self.file=nil end end
    function r:nextFrame()
        if not self.file then return nil end
        local frame
        while true do
            local line=self.pending or self.file:read('*l');self.pending=nil
            if not line then self:close();return frame end
            local a=fields(line)
            if a[1]=='F' then
                if frame then self.pending=line;return frame end
                local t=tonumber(a[2]);assert(#a==2 and finite(t) and t>=0 and t>self.last,'Invalid movement frame clock')
                self.last=t;self.frames=self.frames+1;frame={time=t,units={},count=0,doctrines={}}
            elseif a[1]=='S' then
                local owner=tonumber(a[2])
                assert(version==4 and frame and #a==2 and finite(owner) and owner%1==0 and owner>=0 and owner<256 and not frame.doctrines[owner],'Invalid doctrine player record')
                frame.doctrines[owner]={}
            elseif a[1]=='R' then
                local owner=tonumber(a[2]);local assets=frame and frame.doctrines[owner]
                assert(version==4 and #a==3 and assets and #assets<64 and M.assetPath(a[3]),'Invalid doctrine asset record')
                for _,path in ipairs(assets) do assert(path~=a[3],'Duplicate doctrine asset') end
                assets[#assets+1]=a[3]
            elseif a[1]=='U' then
                local id,owner,entity=tonumber(a[2]),tonumber(a[4]),tonumber(a[5]);local key=M.key(a[3],owner,entity)
                assert(frame and #a==5 and id and id%1==0 and id>0 and id<=1000000 and key and not self.definitions[id] and not self.identities[key],'Invalid movement unit definition')
                self.definitions[id]=key;self.identities[key]=id;self.tracks[key]={class=a[3],owner=owner}
            elseif a[1]=='P' then
                local id=tonumber(a[2]);local key=id and self.definitions[id]
                assert(frame and #a==8 and key and not frame.units[key],'Invalid movement sample identity')
                local v={};for i=3,8 do v[i]=tonumber(a[i]);assert(finite(v[i]),'Invalid movement coordinate') end
                frame.count=frame.count+1;assert(frame.count<=20000,'Too many movement samples')
                frame.units[key]={position={X=v[3],Y=v[4],Z=v[5]},rotation={Pitch=v[6],Yaw=v[7],Roll=v[8]}}
                if not self.tracks[key].position then self.tracks[key].position=frame.units[key].position;self.tracks[key].time=frame.time end
            elseif a[1]=='B' then
                local id,state=tonumber(a[2]),tonumber(a[3]);local key=id and self.definitions[id]
                local unit=frame and key and frame.units[key]
                assert(version>=2 and #a==3 and unit and not unit.building and (state==1 or state==2 or state==3),'Invalid building state record')
                unit.building=state
            elseif a[1]=='D' then
                local key=self.definitions[tonumber(a[2])];local unit=frame and key and frame.units[key]
                assert(version>=3 and #a==2 and unit and not unit.dead,'Invalid death record');unit.dead=true
                if not self.deliveredDeaths[key] and not self.deaths[key] then self.deaths[key]={time=frame.time,unit=unit} end
            elseif a[1]=='C' then
                local key=self.definitions[tonumber(a[2])];local unit=frame and key and frame.units[key]
                local footprint,progress=tonumber(a[3]),tonumber(a[4])
                assert(version>=3 and #a==4 and unit and not unit.site and finite(footprint) and footprint%1==0 and footprint>=0 and footprint<256 and finite(progress) and progress>=0 and progress<=1,'Invalid construction site record')
                unit.site={footprint=footprint,progress=progress}
            elseif a[1]=='E' and #a==1 then self:close();return frame
            else error('Invalid movement record') end
        end
    end
    local function blend(a,b,t) return a+(b-a)*t end
    local function angle(a,b,t) return a+((b-a+180)%360-180)*t end
    function r:at(time)
        assert(finite(time) and time>=0,'Invalid movement playback clock')
        if self.previous and time<self.previous.time then error('Movement seeking is unsupported') end
        if not self.following then self.following=self:nextFrame() end
        while self.following and self.following.time<=time do
            self.previous=self.following;self.following=self:nextFrame()
        end
        local a,b=self.previous,self.following
        self.doctrines=a and a.doctrines or {}
        if not a or (not b and time>a.time+0.5) then return {} end
        local result={};local alpha=b and math.min(1,(time-a.time)/(b.time-a.time)) or 0
        for key,u in pairs(a.units) do
            local v=b and b.units[key]
            if v then
                local p,q=u.position,v.position;local x,y=u.rotation,v.rotation
                result[key]={position={X=blend(p.X,q.X,alpha),Y=blend(p.Y,q.Y,alpha),Z=blend(p.Z,q.Z,alpha)},
                    building=u.building,dead=u.dead,site=u.site,velocity=M.velocity(p,q,b.time-a.time),
                    rotation={Pitch=angle(x.Pitch,y.Pitch,alpha),Yaw=angle(x.Yaw,y.Yaw,alpha),Roll=angle(x.Roll,y.Roll,alpha)}}
            else result[key]={position=u.position,rotation=u.rotation,building=u.building,dead=u.dead,site=u.site,velocity={X=0,Y=0,Z=0}} end
        end
        -- A fast playback frame can cross the one-shot death sample. Deliver
        -- every reached tombstone once even if its frame was skipped entirely.
        for key,event in pairs(self.deaths) do
            if event.time<=time and not self.deliveredDeaths[key] then
                local u=event.unit
                result[key]={position=u.position,rotation=u.rotation,building=u.building,
                    dead=true,site=u.site,velocity={X=0,Y=0,Z=0}}
                self.deliveredDeaths[key]=true
                self.deaths[key]=nil -- consumed tombstones need no per-frame scan
            end
        end
        return result
    end
    return r
end
-- Construction-site actors are reused for different products and positions.
-- Index each stationary segment, then resolve only a unique completed structure
-- at that position. This recovers old v1/v2 files without guessing build order.
function M.catalog(path,name)
    local reader=M.reader(path,name);if not reader then return {} end
    local tracks={}
    while true do
        local frame=reader:nextFrame();if not frame then break end
        for key,u in pairs(frame.units) do
            local t=tracks[key]
            if not t then
                local d=reader.tracks[key]
                t={class=d.class,owner=d.owner,time=frame.time,position=u.position,segments={}};tracks[key]=t
            end
            t.last=frame.time;t.building=t.building or u.building~=nil
            if t.class:find('ConstructionSite',1,true) then
                local s=t.segments[#t.segments];local p=u.position
                if not s or (s.position.X-p.X)^2+(s.position.Y-p.Y)^2>1 then
                    s={time=frame.time,position=p};t.segments[#t.segments+1]=s
                end
                s.last=frame.time
            end
        end
    end
    for _,site in pairs(tracks) do
        for _,s in ipairs(site.segments) do
            local matches={}
            for _,target in pairs(tracks) do
                local p,q=s.position,target.position
                if target.building and not target.class:find('ConstructionSite',1,true) and target.owner==site.owner and
                   target.time>s.time and target.time<=s.last+0.5 and (p.X-q.X)^2+(p.Y-q.Y)^2+(p.Z-q.Z)^2<=200^2 then
                    matches[#matches+1]=target
                end
            end
            if #matches==1 then s.target=matches[1] end
        end
    end
    return tracks
end
-- Entity handles are local runtime IDs, not stable replay IDs. Bind by a unique
-- class/owner/initial pose match, then retain the same actor for that track.
-- Ambiguous co-located spawns remain native rather than swapping units.
function M.match(tracks,samples,actors,bound)
    local byName,result,claimed={},{},{}
    for _,a in ipairs(actors) do byName[a.name]=a end
    for key,name in pairs(bound) do
        local a=byName[name];local t=tracks[key]
        if a and t and a.class==t.class and a.owner==t.owner then
            claimed[name]=true;if samples[key] then result[key]=a end
        end -- Retired tracks must never attach to a newly produced actor.
    end
    local proposals,competition,cohorts={},{},{}
    for key in pairs(samples) do
        if not bound[key] and not samples[key].dead and samples[key].building~=3 then
            local t=tracks[key];local best,score,runner=nil,math.huge,math.huge;local ties={}
            for _,a in ipairs(actors) do
                if t and t.position and a.eligible~=false and not claimed[a.name] and a.class==t.class and a.owner==t.owner then
                    local p,q=a.position,t.position
                    local distance=(p.X-q.X)^2+(p.Y-q.Y)^2+(p.Z-q.Z)^2
                    -- Repeated production uses the same exit pose. Native actor
                    -- arrival time disambiguates those otherwise identical spawns.
                    local dt=a.born and t.time and math.abs(a.born-t.time)
                    if distance<=200^2 or (dt and dt<=30 and distance<=1000^2) then
                        local d=distance+(dt and math.min(90000,dt*dt*100) or 0)
                        if d<score-1 then runner=score;score=d;best=a;ties={a}
                        elseif math.abs(d-score)<=1 then runner=score;ties[#ties+1]=a
                        elseif d<runner then runner=d end
                    end
                end
            end
            if best and runner-score>1 then
                proposals[key]={actor=best,score=score}
                local c=competition[best.name] or {};c[#c+1]={key=key,score=score};competition[best.name]=c
            elseif best and #ties>1 then
                table.sort(ties,function(a,b)return a.name<b.name end)
                local names={};for _,a in ipairs(ties) do names[#names+1]=a.name end
                local signature=table.concat(names,'|')
                local group=cohorts[signature] or {actors=ties,keys={}};cohorts[signature]=group
                group.keys[#group.keys+1]=key
            end
        end
    end
    -- A complete co-located production cohort can be paired in stable creation
    -- order. Partial cohorts stay unresolved; never assign one actor twice.
    for _,group in pairs(cohorts) do
        if #group.keys==#group.actors then
            table.sort(group.keys,function(a,b)
                if tracks[a].time~=tracks[b].time then return (tracks[a].time or 0)<(tracks[b].time or 0) end
                return a<b
            end)
            table.sort(group.actors,function(a,b)
                if a.born~=b.born then return (a.born or 0)<(b.born or 0) end
                return a.name>b.name
            end)
            local available=true
            for _,a in ipairs(group.actors) do if claimed[a.name] or competition[a.name] then available=false end end
            if available then for i,key in ipairs(group.keys) do
                local a=group.actors[i];bound[key]=a.name;result[key]=a;claimed[a.name]=true
            end end
        end
    end
    for key,p in pairs(proposals) do
        local unique=true
        for _,other in ipairs(competition[p.actor.name]) do
            if other.key~=key and other.score<=p.score+1 then unique=false end
        end
        if unique then bound[key]=p.actor.name;result[key]=p.actor end
    end
    return result
end
return M
