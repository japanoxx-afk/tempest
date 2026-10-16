-- Local, data-only movement companion. No RPCs, engine writes or executable file content.
local M = {}
function M.velocity(a,b,dt)
    if not b or not dt or dt<=0 then return {X=0,Y=0,Z=0} end
    local v={X=(b.X-a.X)/dt,Y=(b.Y-a.Y)/dt,Z=(b.Z-a.Z)/dt}
    -- Teleports are position changes, not locomotion animation.
    if v.X*v.X+v.Y*v.Y+v.Z*v.Z>10000^2 then return {X=0,Y=0,Z=0} end
    return v
end
local function finite(n) return type(n)=='number' and n==n and math.abs(n)<1e9 end
local function token(s) return type(s)=='string' and #s<=160 and s:match('^[%w_%-]+$') end
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
    assert(f:write('TEMPEST_MOVEMENT\t1\t'..name..'\n'));assert(f:flush())
    local w={file=f,ids={},count=0,frames=0,last=-1}
    function w:frame(time,units)
        assert(finite(time) and time>=0 and time>=self.last,'Movement clock went backwards')
        if time==self.last then return end
        assert(#units<=20000,'Too many movement units')
        local rows={string.format('F\t%.6f\n',time)};local seen={}
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
    if (f:read('*l') or ''):gsub('\r$','')~='TEMPEST_MOVEMENT\t1\t'..name then f:close();error('Movement companion header/name mismatch') end
    local r={file=f,definitions={},identities={},tracks={},last=-1,frames=0}
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
                self.last=t;self.frames=self.frames+1;frame={time=t,units={},count=0}
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
        if not a or (not b and time>a.time+0.5) then return {} end
        local result={};local alpha=b and math.min(1,(time-a.time)/(b.time-a.time)) or 0
        for key,u in pairs(a.units) do
            local v=b and b.units[key]
            if v then
                local p,q=u.position,v.position;local x,y=u.rotation,v.rotation
                result[key]={position={X=blend(p.X,q.X,alpha),Y=blend(p.Y,q.Y,alpha),Z=blend(p.Z,q.Z,alpha)},
                    velocity=M.velocity(p,q,b.time-a.time),
                    rotation={Pitch=angle(x.Pitch,y.Pitch,alpha),Yaw=angle(x.Yaw,y.Yaw,alpha),Roll=angle(x.Roll,y.Roll,alpha)}}
            else result[key]={position=u.position,rotation=u.rotation,velocity={X=0,Y=0,Z=0}} end
        end
        return result
    end
    return r
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
        else bound[key]=nil end
    end
    local proposals,competition={},{}
    for key in pairs(samples) do
        if not bound[key] then
            local t=tracks[key];local best,score,runner=nil,math.huge,math.huge
            for _,a in ipairs(actors) do
                if t and t.position and not claimed[a.name] and a.class==t.class and a.owner==t.owner then
                    local p,q=a.position,t.position
                    local d=(p.X-q.X)^2+(p.Y-q.Y)^2+(p.Z-q.Z)^2
                    if d<score then runner=score;score=d;best=a elseif d<runner then runner=d end
                end
            end
            if best and score<=200^2 and runner-score>1 then
                proposals[key]={actor=best,score=score}
                local c=competition[best.name] or {};c[#c+1]={key=key,score=score};competition[best.name]=c
            end
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
