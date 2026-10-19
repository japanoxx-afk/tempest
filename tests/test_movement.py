"""Data companion tests. Native/online verification is documented separately."""
import pathlib
import tempfile
import unittest
import struct
from lupa import LuaRuntime, LuaError

SOURCE=(pathlib.Path(__file__).parents[1]/'ReplayBridge/Scripts/Movement.lua').read_text()

class MovementTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.path=pathlib.Path(self.temp.name)/'Test.movement'
        self.lua=LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().M=self.lua.execute(SOURCE)
        self.lua.globals().path=self.path.as_posix()
        self.lua.execute("""
        function unit(x,yaw,entity)
          return {class='Tank_C',owner=1,entity=entity or 2076,
            position={X=x,Y=20,Z=30},rotation={Pitch=0,Yaw=yaw or 0,Roll=0}}
        end
        """)

    def tearDown(self):
        self.lua.execute('if w then w:close() end;if r then r:close() end')
        self.temp.cleanup()

    def create(self):
        self.lua.execute("w=M.writer(path,'Test');w:frame(0,{unit(0,170)});w:frame(1,{unit(100,-170)});w:frame(2,{});w:close();r=M.reader(path,'Test')")

    def test_one_shot_death_is_delivered_when_fast_playback_skips_its_frame(self):
        self.lua.execute('''
        w=M.writer(path,'Test');w:frame(0,{unit(0,0)})
        u=unit(10,0);u.dead=true;w:frame(1,{u});w:frame(2,{});w:frame(3,{});w:close()
        r=M.reader(path,'Test');assert(not r:at(0.5)['Tank_C:1:2076'].dead)
        local sample=r:at(2.1)['Tank_C:1:2076'];assert(sample.dead and sample.position.X==10)
        assert(r:at(2.2)['Tank_C:1:2076']==nil);r:close()
        ''')

    def test_building_states_change_at_recorded_time_without_interpolation(self):
        self.lua.execute("""
        w=M.writer(path,'Test');u=unit(0,0);u.building=1;w:frame(0,{u})
        u.building=2;w:frame(1,{u});u.building=3;w:frame(2,{u});w:close()
        r=M.reader(path,'Test');assert(r:at(0.9)['Tank_C:1:2076'].building==1)
        assert(r:at(1)['Tank_C:1:2076'].building==2)
        assert(r:at(2)['Tank_C:1:2076'].building==3)
        """)

    def test_rejects_invalid_building_state(self):
        self.path.write_text('TEMPEST_MOVEMENT\t2\tTest\nF\t0\nU\t1\tTank_C\t1\t2076\nP\t1\t0\t0\t0\t0\t0\t0\nB\t1\t4\nE\n')
        with self.assertRaises(LuaError): self.lua.execute("r=M.reader(path,'Test');r:at(0)")

    def test_v3_death_and_site_state_are_discrete(self):
        self.lua.execute("""
        w=M.writer(path,'Test');u=unit(0);u.site={footprint=6,progress=0.2};w:frame(0,{u})
        u.dead=true;u.site={footprint=9,progress=0.8};w:frame(1,{u});w:close()
        r=M.reader(path,'Test');local a=r:at(0.9)['Tank_C:1:2076'];assert(not a.dead and a.site.footprint==6)
        local b=r:at(1)['Tank_C:1:2076'];assert(b.dead and b.site.footprint==9)
        """)

    def test_catalog_resolves_reused_site_by_position_segment(self):
        self.lua.execute("""
        w=M.writer(path,'Test')
        s=unit(0,0,1);s.class='BP_GDF_ConstructionSite_C';s.building=2
        a=unit(0,0,2);a.class='Power_C';a.building=2
        b=unit(1000,0,3);b.class='Barracks_C';b.building=2
        w:frame(0,{s});w:frame(1,{s,a});s.position.X=1000
        w:frame(2,{s,a});w:frame(3,{s,a,b});w:close()
        local c=M.catalog(path,'Test')['BP_GDF_ConstructionSite_C:1:1']
        assert(#c.segments==2 and c.segments[1].target.class=='Power_C' and c.segments[2].target.class=='Barracks_C')
        """)

    def test_legacy_file_rejects_new_death_record(self):
        self.path.write_text('TEMPEST_MOVEMENT\t2\tTest\nF\t0\nU\t1\tTank_C\t1\t1\nP\t1\t0\t0\t0\t0\t0\t0\nD\t1\nE\n')
        with self.assertRaises(LuaError): self.lua.execute("r=M.reader(path,'Test');r:at(0)")

    def test_replay_duration_reads_custom_version_container(self):
        self.path.write_bytes(struct.pack('<III',0x1ca2e27f,7,1)+bytes(16)+struct.pack('<II',7,217047))
        self.assertAlmostEqual(self.lua.globals().M.duration(str(self.path)),217.047)

    def test_replay_duration_rejects_unknown_truncated_and_unbounded_headers(self):
        for data in [b'',struct.pack('<III',0x1ca2e27f,8,0),
                     struct.pack('<III',0x1ca2e27f,7,33),
                     struct.pack('<IIII',0x1ca2e27f,7,0,0xffffffff)]:
            self.path.write_bytes(data)
            self.assertIsNone(self.lua.globals().M.duration(str(self.path)))

    def test_pose_binding_ignores_different_runtime_entity_numbers_and_stays_attached(self):
        self.create()
        self.lua.execute("""
        samples=r:at(0);bound={}
        actors={{name='actor999',class='Tank_C',owner=1,position={X=0,Y=20,Z=30}}}
        result=M.match(r.tracks,samples,actors,bound)
        assert(result['Tank_C:1:2076'].name=='actor999')
        samples=r:at(0.5);actors[1].position.X=5000
        result=M.match(r.tracks,samples,actors,bound)
        assert(result['Tank_C:1:2076'].name=='actor999')
        """)

    def test_pose_binding_rejects_ambiguous_spawns_wrong_owner_and_far_actors(self):
        self.create()
        self.lua.execute("""
        samples=r:at(0);bound={}
        function actor(name,x,owner) return {name=name,class='Tank_C',owner=owner,position={X=x,Y=20,Z=30}} end
        assert(next(M.match(r.tracks,samples,{actor('a',0,1),actor('b',0,1)},bound))==nil)
        assert(next(M.match(r.tracks,samples,{actor('a',0,0)},bound))==nil)
        assert(next(M.match(r.tracks,samples,{actor('a',5000,1)},bound))==nil)
        """)

    def test_pose_binding_never_assigns_one_actor_to_two_tracks(self):
        self.lua.execute("""
        w=M.writer(path,'Test');w:frame(0,{unit(0,0,1),unit(0,0,2)});w:close();r=M.reader(path,'Test')
        samples=r:at(0);bound={}
        result=M.match(r.tracks,samples,{{name='one',class='Tank_C',owner=1,position={X=0,Y=20,Z=30}}},bound)
        assert(next(result)==nil and next(bound)==nil)
        """)

    def test_roundtrip_and_interpolation_use_replay_time(self):
        self.create()
        self.lua.execute("sample=r:at(0.5)['Tank_C:1:2076']")
        self.assertEqual(self.lua.eval('sample.position.X'),50)
        self.assertEqual(abs(self.lua.eval('sample.rotation.Yaw')),180)

    def test_retired_and_dead_tracks_never_claim_new_production(self):
        self.lua.execute("""
        t={old={class='Tank_C',owner=1,position={X=0,Y=0,Z=0}},new={class='Tank_C',owner=1,position={X=0,Y=0,Z=0}}}
        a={{name='newPawn',class='Tank_C',owner=1,position={X=0,Y=0,Z=0}}}
        bound={old='removedPawn'};s={old={dead=true},new={}}
        result=M.match(t,s,a,bound);assert(bound.old=='removedPawn' and result.new.name=='newPawn' and not result.old)
        bound={};result=M.match(t,{old={dead=true}},a,bound);assert(next(result)==nil)
        """)

    def test_repeated_exit_pose_uses_actor_arrival_time(self):
        self.lua.execute("""
        t={first={class='Tank_C',owner=1,time=10,position={X=0,Y=0,Z=0}},second={class='Tank_C',owner=1,time=20,position={X=0,Y=0,Z=0}}}
        a={{name='a',class='Tank_C',owner=1,born=10,position={X=0,Y=0,Z=0}},
           {name='b',class='Tank_C',owner=1,born=20,position={X=0,Y=0,Z=0}}}
        local r=M.match(t,{first={},second={}},a,{})
        assert(r.first.name=='a' and r.second.name=='b')
        """)

    def test_complete_production_cohort_is_one_to_one_but_partial_stays_unbound(self):
        self.lua.execute("""
        local p={X=0,Y=0,Z=0}
        local t={a={class='Tank_C',owner=1,time=10,position=p},b={class='Tank_C',owner=1,time=10,position=p}}
        local actors={{name='actor2',class='Tank_C',owner=1,born=10,position=p},{name='actor1',class='Tank_C',owner=1,born=10,position=p}}
        local bound={};local r=M.match(t,{a={},b={}},actors,bound)
        assert(r.a and r.b and r.a.name~=r.b.name)
        assert(next(M.match(t,{a={}},actors,{}))==nil)
        """)

    def test_factory_center_can_bind_recent_exit_but_not_unrelated_far_actor(self):
        self.lua.execute("""
        local t={a={class='Tank_C',owner=1,time=30,position={X=800,Y=0,Z=0}}}
        local a={{name='factorySpawn',class='Tank_C',owner=1,born=20,position={X=0,Y=0,Z=0}}}
        assert(M.match(t,{a={}},a,{}).a)
        a[1].born=100;assert(not M.match(t,{a={}},a,{}).a)
        """)

    def test_doctrine_snapshot_is_discrete_and_can_remove_research(self):
        self.lua.execute("""
        local path='/Game/Tempest/DataAssets/Doctrine/GDF/DD_Test.DD_Test'
        w=M.writer(_G.path,'Test');w:frame(0,{}, {[0]={}});w:frame(1,{}, {[0]={path}});w:frame(2,{}, {[0]={}});w:close()
        r=M.reader(_G.path,'Test');r:at(0.99);assert(#r.doctrines[0]==0)
        r:at(1);assert(r.doctrines[0][1]==path);r:at(2);assert(#r.doctrines[0]==0)
        assert(not M.assetPath('/Game/Tempest/../Commands.Cmd'))
        """)

    def test_doctrine_reader_rejects_paths_and_orphan_records(self):
        for row in ['R\\t0\\t/Game/Tempest/A.A', 'S\\t-1', 'S\\t0\\nR\\t0\\t/Script/Engine.Foo']:
            self.path.write_text('TEMPEST_MOVEMENT\t4\tTest\nF\t0\n'+row.replace('\\t','\t').replace('\\n','\n')+'\nE\n')
            with self.assertRaises(LuaError): self.lua.execute("r=M.reader(path,'Test');r:at(0)")
            self.lua.execute('r:close()')

    def test_velocity_uses_recorded_clock_and_stops_at_last_sample(self):
        self.create()
        self.assertEqual(self.lua.eval("r:at(0.25)['Tank_C:1:2076'].velocity.X"),100)
        self.assertEqual(self.lua.eval("r:at(1.25)['Tank_C:1:2076'].velocity.X"),0)

    def test_teleport_and_zero_interval_do_not_trigger_running_animation(self):
        self.lua.execute("a={X=0,Y=0,Z=0};b={X=20000,Y=0,Z=0}")
        self.assertEqual(self.lua.eval('M.velocity(a,b,0.1).X'),0)
        self.assertEqual(self.lua.eval('M.velocity(a,b,0).X'),0)

    def test_missing_spawn_and_removed_unit_are_not_extrapolated(self):
        self.create()
        self.assertEqual(self.lua.eval("next(r:at(2))"),None)
        self.assertEqual(self.lua.eval("next(r:at(100))"),None)

    def test_does_not_move_units_before_first_recorded_sample(self):
        self.lua.execute("w=M.writer(path,'Test');w:frame(10,{unit(5)});w:close();r=M.reader(path,'Test')")
        self.assertIsNone(self.lua.eval('next(r:at(9))'))

    def test_writer_flushed_frames_survive_without_final_trailer(self):
        self.lua.execute("w=M.writer(path,'Test');w:frame(0,{unit(17)});r=M.reader(path,'Test')")
        self.assertEqual(self.lua.eval("r:at(0)['Tank_C:1:2076'].position.X"),17)

    def test_rejects_wrong_companion_name(self):
        self.create()
        with self.assertRaises(LuaError):self.lua.execute("M.reader(path,'Other')")

    def test_missing_companion_is_optional(self):
        self.assertIsNone(self.lua.eval("M.reader(path,'Test')"))

    def test_duplicate_identity_cannot_silently_swap_units(self):
        self.lua.execute("w=M.writer(path,'Test')")
        with self.assertRaises(LuaError):self.lua.execute('w:frame(0,{unit(1),unit(2)})')

    def test_owner_and_class_are_part_of_identity(self):
        self.assertNotEqual(self.lua.eval("M.key('Tank_C',0,2076)"),self.lua.eval("M.key('Tank_C',1,2076)"))
        self.assertNotEqual(self.lua.eval("M.key('Tank_C',1,2076)"),self.lua.eval("M.key('Other_C',1,2076)"))

    def test_rejects_nan_and_backward_clock(self):
        self.lua.execute("w=M.writer(path,'Test');w:frame(1,{unit(1)})")
        with self.assertRaises(LuaError):self.lua.execute('w:frame(0,{unit(2)})')
        with self.assertRaises(LuaError):self.lua.execute('w:frame(2,{unit(0/0)})')

    def test_invalid_text_is_data_not_executable(self):
        self.path.write_text("TEMPEST_MOVEMENT\t1\tTest\nos.execute('bad')\n")
        self.lua.execute("r=M.reader(path,'Test')")
        with self.assertRaises(LuaError):self.lua.execute('r:at(0)')

    def test_malformed_identity_or_coordinate_is_rejected(self):
        for line in ['U\t1\tTank_C\t1\t0','P\t1\tNaN\t0\t0\t0\t0\t0']:
            self.path.write_text('TEMPEST_MOVEMENT\t1\tTest\nF\t0\n'+line+'\n')
            self.lua.execute("r=M.reader(path,'Test')")
            with self.assertRaises(LuaError):self.lua.execute('r:at(0)')
            self.lua.execute('r:close()')

    def test_playback_reads_incrementally_instead_of_loading_entire_match(self):
        self.lua.execute("w=M.writer(path,'Test');for i=0,1000 do w:frame(i,{unit(i)}) end;w:close();r=M.reader(path,'Test');r:at(2.5)")
        self.assertLess(self.lua.eval('r.frames'),10)

if __name__=='__main__':unittest.main()
