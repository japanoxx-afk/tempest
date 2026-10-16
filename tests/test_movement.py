"""Data companion tests. Native/online verification is documented separately."""
import pathlib
import tempfile
import unittest
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

    def test_roundtrip_and_interpolation_use_replay_time(self):
        self.create()
        self.lua.execute("sample=r:at(0.5)['Tank_C:1:2076']")
        self.assertEqual(self.lua.eval('sample.position.X'),50)
        self.assertEqual(abs(self.lua.eval('sample.rotation.Yaw')),180)

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
