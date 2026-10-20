"""Data/cosmetic scheduling tests; native listening is validated separately."""
import pathlib
import unittest
from lupa import LuaRuntime

class AudioTests(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().module=self.lua.execute((pathlib.Path(__file__).parents[1]/'ReplayBridge/Scripts/ReplayAudio.lua').read_text(encoding='utf-8'))
        self.lua.execute('''
        local v=function()return true end
        invalid={IsValid=function()return false end}
        clock=0;spawned=0;stopped=0;pauseCalls=0;playing=true
        sound={IsValid=v,IsA=function()return true end,GetFullName=function()return 'SoundCue /Game/Tempest/Audio/Effects/Hit/Metal.Metal' end}
        flesh={IsValid=v,IsA=function()return true end,GetFullName=function()return 'SoundCue /Game/Tempest/Audio/Effects/Hit/Flesh.Flesh' end}
        local function cue(tag,snd)return {IsA=function()return true end,Sound=snd,GameplayCueTag={TagName={ToString=function()return tag end}}} end
        api={clock=function()return clock end,objects=function(cb)cb(cue('GameplayCue.Impact.Bullet.Default',sound));cb(cue('GameplayCue.Impact.Bullet.Infantry',flesh))end,
          spawn=function(context,snd,pos)
            spawned=spawned+1;lastSound=snd;lastPos=pos
            return {IsValid=v,IsPlaying=function()return playing end,Stop=function()stopped=stopped+1;playing=false end,
              SetPaused=function(self,p)pauseCalls=pauseCalls+1;lastPause=p end}
          end}
        s=module.new(api);context={IsValid=v};target=invalid
        actor={GetFullName=function()return 'projectile1' end,Target=target,
          HitGameplayCue={GameplayCueTag={TagName={ToString=function()return 'GameplayCue.Impact.Bullet.Default' end}}},
          K2_GetActorLocation=function()return {X=10,Y=20,Z=30}end}
        ''')
    def test_native_impact_queues_once_then_spawns_only_audio(self):
        self.lua.execute('s:hit(actor,1);s:hit(actor,1.01);s:update(1.02,false,context);assert(spawned==0);s:update(1.1,false,context);assert(spawned==1 and lastSound==sound and lastPos.X==10);s:update(1.2,false,context);assert(spawned==1)')
    def test_reused_projectile_can_sound_again(self):
        self.lua.execute('s:hit(actor,1);s:update(1.1,false,context);s:hit(actor,1.3);s:update(1.4,false,context);assert(spawned==2)')
    def test_native_sound_is_deduplicated_once(self):
        self.lua.execute('s:hit(actor,1);s:observed(sound,{X=10,Y=20,Z=30},1.02);s:update(1.1,false,context);assert(spawned==0 and s.stats.native==1)')
    def test_unrelated_sound_does_not_suppress_hit(self):
        self.lua.execute('s:hit(actor,1);s:observed(flesh,{X=10,Y=20,Z=30},1.02);s:update(1.1,false,context);assert(spawned==1)')
    def test_pause_defers_dispatch_and_preserves_tail_duration(self):
        self.lua.execute('s:hit(actor,1);s:update(1.1,true,context);assert(spawned==0);s:update(1.1,false,context);assert(spawned==1);clock=1;s:update(1.1,true,context);assert(lastPause);clock=100;s:update(1.1,false,context);assert(not lastPause and stopped==0);clock=110;s:update(2,false,context);assert(stopped==1)')
    def test_close_stops_owned_audio_and_rejects_late_callbacks(self):
        self.lua.execute('s:hit(actor,1);s:update(1.1,false,context);s:close();s:close();s:hit(actor,2);s:update(2.1,false,context);assert(stopped==1 and spawned==1 and #s.pending==0)')
    def test_stale_audio_is_dropped_instead_of_played_late(self):
        self.lua.execute('s:hit(actor,1);s:update(3,false,context);assert(spawned==0 and s.stats.dropped==1)')
    def test_missing_cue_is_reported_without_guessing_a_sound(self):
        self.lua.execute("actor.HitGameplayCue.GameplayCueTag.TagName.ToString=function()return 'Unsupported' end;s:hit(actor,1);assert(s.stats.missing==1 and #s.pending==0)")
    def test_spawn_error_is_reported_separately_from_missing_cue(self):
        self.lua.execute("api.spawn=function()error('factory failed')end;s:hit(actor,1);s:update(1.1,false,context);assert(s.stats.spawnFailed==1 and s.stats.noCue==0 and s.lastSpawnError:find('factory failed'));assert(not s.spawning)")
    def test_finished_owned_component_is_explicitly_released(self):
        self.lua.execute('destroyed=0;api.destroy=function()destroyed=destroyed+1 end;s:hit(actor,1);s:update(1.1,false,context);playing=false;s:update(1.2,false,context);s:close();assert(destroyed==1 and #s.owned==0)')
    def test_pool_reset_uses_retained_target_position(self):
        self.lua.execute('actor.TargetLocation={X=5000,Y=20,Z=30};s:hit(actor,1);s:update(1.1,false,context);assert(lastPos.X==5000)')
    def test_target_specific_cue_is_preferred(self):
        self.lua.execute("actor.Target={IsValid=function()return true end,IsA=function(self,c)return c=='/Script/Tempest.TedInfantry' end};s:hit(actor,1);s:update(1.1,false,context);assert(lastSound==flesh)")
    def test_spawn_observation_does_not_deduplicate_its_own_fallback(self):
        self.lua.execute('s.spawning=true;s:observed(sound,{X=10,Y=20,Z=30},1);assert(#s.recent==0)')
    def test_wrong_asset_root_is_rejected(self):
        self.lua.execute("sound.GetFullName=function()return 'SoundCue /Game/Unrelated/Voice.Voice' end;flesh.GetFullName=sound.GetFullName;s:hit(actor,1);assert(s.stats.missing==1)")
    def test_speed_independent_replay_clock_scheduling(self):
        for speed in (1,2,4):
            self.setUp()
            self.lua.execute(f's:hit(actor,10);s:update(10+0.016*{speed},false,context);s:update(10+0.12*{speed},false,context);assert(spawned==1)')

if __name__=='__main__': unittest.main()
