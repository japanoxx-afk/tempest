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
 K2_GetWorldSettings=function() return worldSettings end,
 GetFullName=function() return worldName end}
worldSettings={PauserPlayerState=invalid}
worldName='World_A'
pc = {IsValid=function() return true end, GetWorld=function() return world end,
 GetFullName=function() return 'HumanPlayerController' end,
 HasMatchStarted=function() return began end, HasMatchEnded=function() return ended end,
 ConsoleCommand={type='TrivialObject'}}
pc.Player={IsValid=function() return true end,IsA=function(self,cls) return cls=='/Script/Engine.LocalPlayer' end}
bot={IsValid=function() return true end,Player=invalid}
controllers={bot,pc}
FindAllOf=function() return controllers end
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
RegisterLoadMapPreHook=function(callback) loadPre=callback end
RegisterLoadMapPostHook=function(callback) loadPost=callback end
RegisterEndPlayPreHook=function(callback) endPre=callback end
loops={}; LoopAsync=function(interval, callback) loops[interval]=callback; if interval==1000 then loop=callback end end
LoopInGameThreadWithDelay=function(interval,callback) loops[interval]=callback; if interval==1000 then loop=callback end;return interval end
CancelDelayedAction=function() return true end
ExecuteInGameThread=function(callback) callback() end
Key={F6=117,F8=119,I=73,C=67,J=74,K=75,L=76}; keybinds={}
RegisterKeyBind=function(key,callback) keybinds[key]=callback end
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
        self.lua.globals().began = True
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

    def test_travel_reset_is_repaired_before_next_recording(self):
        self.start()
        self.lua.globals().began = True
        self.tick()
        self.lua.execute("definitions[2]=nil; worldName='World_B'")
        self.tick()
        self.assertEqual(self.lua.eval('#definitions'), 2)
        self.assertEqual(self.lua.eval('definitions[2].DefName:ToString()'), 'DemoNetDriver')
        self.assertEqual(len(self.commands()), 2)

    def test_match_exit_preserves_recording_failure(self):
        self.start()
        self.lua.globals().began = True
        self.tick()
        self.lua.globals().now = 1010
        self.tick()
        self.lua.execute("worldName='MainMenu'; began=false; gs.IsA=function() return false end")
        self.tick()
        self.assertIn('record_failed', (self.data / 'status.txt').read_text())

    def test_bot_before_human_is_never_used_as_command_context(self):
        self.lua.execute("lib.ExecuteConsoleCommand=function(self,context,cmd,player) assert(context==pc and player==pc,'AI selected');table.insert(commands,cmd) end")
        self.start()
        self.lua.globals().began = True
        self.tick()
        self.assertEqual(len(self.commands()),1)

    def test_no_human_controller_sends_no_commands(self):
        self.lua.execute('controllers={bot}')
        self.start()
        self.lua.globals().began = True
        self.tick()
        self.assertEqual(self.commands(),[])

    def setup_viewer(self):
        self.lua.execute('''
        replayPlaying=false; hiddenCalls=0; viewerStarts=0
        actor={IsValid=function() return true end,GetFullName=function() return 'RealPawn' end,
          IsAlive=function() return true end,IsInContainer=function() return false end,
          IsA=function() return false end,MeshComp=invalid,
          K2_SetDefaultVisibility=function() end,K2_OnVisibilityChanged=function() end,
          SetActorHiddenInGame=function() hiddenCalls=hiddenCalls+1 end}
        placeholder=setmetatable({GetFullName=function() return 'ConformationPawn' end},{__index=actor})
        dead=setmetatable({GetFullName=function() return 'DeadPawn' end,IsAlive=function() return false end},{__index=actor})
        FindAllOf=function(cls) if cls=='PlayerController' then return controllers else return {actor,placeholder,dead} end end
        replaySystem={IsValid=function() return true end,IsPlaying=function() return replayPlaying end}
        pc.PlayerState={IsValid=function() return true end,GetFullName=function() return 'ReplaySpectatorState' end}
        FindFirstOf=function(cls) if cls=='ReplaySubsystem' then return replaySystem else return invalid end end
        pc.ClientGotoState=function() viewerStarts=viewerStarts+1 end
        pc.GetSpectatorPawn=function() return invalid end
        world.DemoNetDriver={IsValid=function() return true end}
        ''')

    def test_viewer_requires_actual_replay_playback(self):
        self.setup_viewer()
        self.start('play', replay='TestReplay')
        self.tick()
        self.lua.globals().now = 1004
        self.tick()
        self.tick()
        self.assertEqual(self.lua.globals().viewerStarts, 0)
        self.assertEqual(self.lua.globals().hiddenCalls, 0)
        self.lua.globals().replayPlaying = True
        self.tick()
        self.assertEqual(self.lua.globals().viewerStarts, 1)
        self.assertEqual(self.lua.globals().hiddenCalls, 2)  # real pawn only
        self.tick()
        self.assertEqual(self.lua.globals().viewerStarts, 1)

    def test_record_mode_never_changes_pawn_visibility(self):
        self.setup_viewer()
        self.lua.globals().replayPlaying = True
        self.start()
        self.lua.globals().began = True
        self.tick()
        self.assertEqual(self.lua.globals().hiddenCalls, 0)
        self.assertEqual(self.lua.globals().viewerStarts, 0)

    def test_recorded_pause_is_cleared_but_local_replay_pause_is_preserved(self):
        self.setup_viewer()
        self.start('play', replay='TestReplay')
        self.tick()
        self.lua.globals().now = 1004
        self.tick()
        self.lua.execute("replayPlaying=true;worldSettings.PauserPlayerState={IsValid=function() return true end,GetFullName=function() return 'OriginalPlayerState' end}")
        self.tick()
        self.assertIsNone(self.lua.globals().worldSettings.PauserPlayerState)
        self.lua.execute('worldSettings.PauserPlayerState=pc.PlayerState')
        self.tick()
        self.assertEqual(self.lua.eval('worldSettings.PauserPlayerState:GetFullName()'), 'ReplaySpectatorState')

    def test_record_mode_does_not_register_viewer_hotkeys(self):
        self.start()
        self.assertEqual(len(list(self.lua.globals().keybinds.values())), 0)

    def test_hotkeys_do_nothing_before_actual_playback(self):
        self.setup_viewer()
        self.start('play', replay='TestReplay')
        self.lua.execute('keybinds[Key.F8]()')
        self.assertEqual(self.commands(), [])

    def setup_input(self):
        self.setup_viewer()
        self.lua.execute("""
        moves={}; selected={{get=function() return actor end}}; position={X=100,Y=200,Z=0}; down=false
        actor.K2_GetActorLocation=function() return position end
        pc.Pawn={IsValid=function() return true end,
          K2_GetActorLocation=function() return {X=0,Y=0,Z=0} end,
          K2_SetActorLocation=function(self,p) table.insert(moves,p) end,
          PlayerCameraComponent={InterpolateCameraToLocation=function() end}}
        pc.GetSelectedPawns=function() return selected end
        pc.IsInputKeyDown=function() return down end
        pc.GetMousePosition=function(self,x,y) x.LocationX=500;y.LocationY=500;return true end
        pc.GetViewportSize=function(self,x,y) x.SizeX=1000;y.SizeY=1000 end
        """)
        self.start('play', replay='TestReplay')

    def test_camera_input_does_not_run_in_live_game(self):
        self.setup_input()
        self.lua.execute('keybinds[Key.C]();loops[33]()')
        self.assertEqual(self.lua.eval('#moves'),0)

    def test_selected_target_is_followed_and_click_cancels_tracking(self):
        self.setup_input()
        self.lua.execute('replayPlaying=true;keybinds[Key.C]();loops[33]()')
        self.assertEqual(self.lua.eval('moves[1].X'),100)
        self.lua.execute('position.X=300;loops[33]()')
        self.assertEqual(self.lua.eval('moves[2].X'),300)
        self.lua.execute('down=true;loops[33]()')
        self.assertEqual(self.lua.eval('#moves'),2)

    def test_dead_target_stops_tracking(self):
        self.setup_input()
        self.lua.execute('replayPlaying=true;keybinds[Key.C]();actor.IsAlive=function() return false end;loops[33]()')
        self.assertEqual(self.lua.eval('#moves'),0)

    def test_i_toggles_live_statistics_without_camera_movement(self):
        self.setup_input()
        self.lua.execute("""
        toggles=0
        widget={IsValid=function() return true end,
         GetFullName=function() return 'Widget /Engine/Transient.HUD' end,
         SingularStatShow_ButtonClick=function() toggles=toggles+1 end}
        local previous=FindAllOf
        FindAllOf=function(cls) if cls=='TedThirdPartySpectatorHud' then return {widget} end;return previous(cls) end
        replayPlaying=true;keybinds[Key.I]()
        """)
        self.assertEqual(self.lua.eval('toggles'),1)
        self.assertEqual(self.lua.eval('#moves'),0)

    def test_right_edge_moves_camera_right_and_outside_viewport_is_ignored(self):
        self.setup_input()
        self.lua.execute("""
        replayPlaying=true
        pc.GetMousePosition=function(self,x,y) x.LocationX=999;y.LocationY=500;return true end
        loops[33]()
        """)
        self.assertLess(self.lua.eval('moves[1].Y'),0)
        self.lua.execute('pc.GetMousePosition=function(self,x,y) x.LocationX=1001;y.LocationY=500;return true end;loops[33]()')
        self.assertEqual(self.lua.eval('#moves'),1)

    def test_world_teardown_disables_all_viewer_callbacks_before_object_access(self):
        self.setup_viewer()
        self.start('play', replay='TestReplay')
        self.tick()
        self.lua.execute('now=1004')
        self.tick()
        self.lua.execute('replayPlaying=true')
        self.tick()
        self.lua.execute("""
        loadPre()
        FindAllOf=function() error('object access during teardown') end
        FindFirstOf=function() error('object access during teardown') end
        keybinds[Key.C]();keybinds[Key.I]();keybinds[Key.F8]()
        initHook({get=function() error('stale world context') end})
        """)
        self.assertTrue(self.lua.eval('loops[33]()'))
        self.assertTrue(self.tick())
        self.assertIn('viewer_stopped', (self.data / 'status.txt').read_text())

    def test_initial_replay_travel_suspends_and_resumes_polling(self):
        self.setup_viewer()
        self.start('play', replay='TestReplay')
        self.lua.execute('loadPre()')
        self.assertFalse(self.tick())
        self.assertFalse((self.data / 'playback.txt').exists())
        self.lua.execute('loadPost()')
        self.tick()
        self.assertTrue((self.data / 'playback.txt').exists())

    def test_endplay_transition_stops_viewer_but_unit_death_does_not(self):
        self.setup_viewer()
        self.start('play', replay='TestReplay')
        self.tick()
        self.lua.execute('now=1004')
        self.tick()
        self.lua.execute('replayPlaying=true')
        self.tick()
        self.lua.execute('endPre({get=function() return actor end},{get=function() return 0 end})')
        self.assertFalse(self.lua.eval('loops[33]()'))
        self.lua.execute("""
        endPre({get=function() error('must not inspect actors during transition') end},{get=function() return 1 end})
        FindAllOf=function() error('stale controller') end
        """)
        self.assertTrue(self.tick())
        self.assertTrue(self.lua.eval('loops[33]()'))

    def test_mouse_loop_reuses_game_thread_timer_without_queuing_callbacks(self):
        self.setup_input()
        self.lua.execute("""
        replayPlaying=true
        ExecuteInGameThread=function() error('per-frame coroutine dispatch') end
        for i=1,100 do loops[33]() end
        """)
        self.assertFalse((self.data / 'status.txt').read_text().find('viewer_control_error') >= 0)


if __name__ == '__main__':
    unittest.main()
