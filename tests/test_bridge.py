"""Control-flow tests with a mocked UE4SS host; these do NOT validate game compatibility."""
import pathlib
import tempfile
import unittest
from lupa import LuaRuntime

SOURCE = (pathlib.Path(__file__).parents[1] / 'ReplayBridge/Scripts/main.lua').read_text()
MOCK = r'''
now = 1000; commands = {}; began = false; ended = false
invalid = {IsValid=function() return false end}
gs = {IsValid=function() return true end, IsA=function() return true end,
 HasMatchStarted=function() return began end, HasMatchEnded=function() return ended end}
world = {GameState=gs, IsValid=function() return true end,
 GetFullName=function() return worldName end}
worldName='World_A'
pc = {IsValid=function() return true end, GetWorld=function() return world end,
 HasMatchStarted=function() return began end, HasMatchEnded=function() return ended end,
 ConsoleCommand={type='TrivialObject'}}
consoleFunction={IsValid=function() return true end}
lib = {IsValid=function() return true end,
 CallFunction=function() error('Unbound UFunction context') end,
 ExecuteConsoleCommand=function(self, context, cmd, player) table.insert(commands,cmd) end}
FName=function(text) return {ToString=function() return text end} end
definitions = {{DefName=FName('GameNetDriver'),DriverClassName=FName('Hydra.RedstoneNetDriver')}}
definitions.ForEach=function(self, callback)
 for index, value in ipairs(self) do callback(index,{get=function() return value end}) end
end
engine={IsValid=function() return true end, NetDriverDefinitions=definitions}
os.getenv=function() return testRoot end
os.time=function() return now end
os.date=function() return '20261016_120000' end
print=function() end
package.preload.UEHelpers=function() return {GetPlayerController=function() return pc end, GetEngine=function() return engine end} end
StaticFindObject=function(path)
 if path=='/Script/Engine.Default__KismetSystemLibrary' then return lib end
 if path=='/Script/Engine.KismetSystemLibrary:ExecuteConsoleCommand' then return consoleFunction end
 return invalid
end
LoadAsset=function() return {IsValid=function() return true end} end
RegisterInitGameStatePostHook=function(callback) initHook=callback end
LoopAsync=function(interval, callback) loop=callback end
ExecuteInGameThread=function(callback) callback() end
'''


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.data = self.root / 'TempestReplayLauncher/bridge'
        self.data.mkdir(parents=True)
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().testRoot = self.root.as_posix()
        self.lua.execute(MOCK)

    def tearDown(self):
        self.temp.cleanup()

    def start(self, mode='record', expiry=1100, replay=''):
        (self.data / 'request.txt').write_text(f'{mode}\nsession123\n{expiry}\n{replay}\n')
        self.lua.execute(SOURCE)

    def commands(self):
        return list(self.lua.globals().commands.values())

    def tick(self):
        return self.lua.globals().loop()

    def test_normal_launch_is_idle(self):
        self.lua.execute(SOURCE)
        self.assertIsNone(self.lua.globals().loop)

    def test_expired_request_is_idle(self):
        self.start(expiry=900)
        self.assertIsNone(self.lua.globals().loop)

    def test_future_request_is_rejected(self):
        self.start(expiry=9000)
        self.assertIsNone(self.lua.globals().loop)

    def test_probe_never_sends_game_commands(self):
        self.start('probe')
        self.lua.globals().began = True
        self.tick()
        self.assertEqual(self.commands(), [])
        self.assertIn('probe_ready', (self.data / 'status.txt').read_text())
        self.assertTrue((self.data / 'reflection.txt').exists())

    def test_auto_record_waits_for_match_and_dispatches_once(self):
        self.start()
        self.assertFalse((self.data / 'request.txt').exists())
        self.tick()
        self.assertEqual(self.commands(), [])
        self.lua.globals().began = True
        self.tick()
        self.tick()
        self.assertEqual(len(self.commands()), 1)
        self.assertTrue(self.commands()[0].startswith('demorec Tempest_'))
        self.assertIn('record_requested', (self.data / 'status.txt').read_text())
        self.lua.globals().ended = True
        self.tick()
        self.tick()
        self.assertEqual(self.commands()[-1], 'demostop')
        self.assertEqual(len(self.commands()), 2)

    def test_new_world_starts_another_recording(self):
        self.start()
        self.lua.globals().began = True
        self.tick()
        self.lua.globals().worldName = 'World_B'
        self.lua.globals().now = 1005
        self.tick()
        self.assertEqual(len(self.commands()), 2)
        self.assertNotEqual(self.commands()[0], self.commands()[1])

    def test_playback_is_dispatched_only_once(self):
        self.start('play', replay='TestReplay')
        self.tick()
        self.lua.globals().now = 1004
        self.tick()
        self.tick()
        self.assertEqual(self.commands(), ['demoplay TestReplay'])

    def test_incompatible_api_stops_after_three_errors(self):
        self.start()
        self.lua.execute('pc.HasMatchStarted=function() error("incompatible API") end')
        self.tick()
        self.tick()
        self.tick()
        self.assertTrue(self.tick())
        self.assertEqual(self.commands(), [])
        self.assertIn('bridge_error', (self.data / 'status.txt').read_text())

    def test_no_driver_is_reported_as_failure(self):
        self.start()
        self.lua.globals().began = True
        self.tick()
        self.lua.globals().now = 1010
        self.tick()
        self.assertIn('record_failed', (self.data / 'status.txt').read_text())
        self.assertIn('REQUEST demorec', (self.data / 'commands.log').read_text())
        self.assertEqual(len(self.commands()), 1)

    def test_driver_activation_is_reported_separately(self):
        self.start()
        self.lua.globals().began = True
        self.tick()
        self.lua.execute('world.DemoNetDriver={IsValid=function() return true end}')
        self.tick()
        self.assertIn('record_driver_active', (self.data / 'status.txt').read_text())

    def test_non_reflected_console_command_is_never_called(self):
        self.start()
        self.lua.globals().began = True
        self.tick()
        self.assertEqual(len(self.commands()), 1)
        self.assertNotIn('bridge_error', (self.data / 'status.txt').read_text())

    def test_missing_kismet_function_fails_before_dispatch(self):
        self.lua.globals().consoleFunction = self.lua.globals().invalid
        self.start()
        self.lua.globals().began = True
        self.tick()
        self.assertEqual(self.commands(), [])
        self.assertIn('unavailable', (self.data / 'status.txt').read_text())

    def test_live_driver_registration_preserves_game_driver(self):
        self.start()
        self.tick()
        self.tick()
        self.assertEqual(self.lua.eval('#definitions'), 2)
        self.assertEqual(self.lua.eval('definitions[1].DefName:ToString()'), 'GameNetDriver')
        self.assertEqual(self.lua.eval('definitions[1].DriverClassName:ToString()'), 'Hydra.RedstoneNetDriver')
        self.assertEqual(self.lua.eval('definitions[2].DriverClassName:ToString()'), '/Script/Engine.DemoNetDriver')

    def test_probe_does_not_register_driver(self):
        self.start('probe')
        self.tick()
        self.assertEqual(self.lua.eval('#definitions'), 1)


if __name__ == '__main__':
    unittest.main()
