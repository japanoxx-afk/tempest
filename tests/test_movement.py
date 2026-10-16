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
