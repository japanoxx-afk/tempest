"""Control-flow tests with a mocked UE4SS host; these do NOT validate game compatibility."""
import pathlib
import tempfile
import unittest
from lupa import LuaRuntime

SOURCE = (pathlib.Path(__file__).parents[1] / 'ReplayBridge/Scripts/main.lua').read_text(encoding='utf-8')
MOCK = r'''
now = 1000; commands = {}; began = false; ended = false
invalid = {IsValid=function() return false end}
gs = {IsValid=function() return true end, IsA=function() return true end,
 GetFullName=function() return "TedGameState" end,
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
FindAllOf=function(cls) if cls=='PlayerController' then return controllers end;return {} end
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
RegisterBeginPlayPostHook=function(callback) beginPost=callback end
RegisterLoadMapPreHook=function(callback) loadPre=callback end
RegisterLoadMapPostHook=function(callback) loadPost=callback end
RegisterEndPlayPreHook=function(callback) endPre=callback end
RegisterULocalPlayerExecPreHook=function(callback) localExecPre=callback end
loops={}; LoopAsync=function(interval, callback) loops[interval]=callback; if interval==1000 then loop=callback end end
LoopInGameThreadWithDelay=function(interval,callback) loops[interval]=callback; if interval==1000 then loop=callback end;return interval end
CancelDelayedAction=function() return true end
ExecuteInGameThread=function(callback) callback() end
Key={Q=81,W=87,E=69,R=82,T=84,Y=89,A=65,S=83,U=85,F6=117,F7=118,F8=119,I=73,C=67,J=74,K=75,L=76}; keybinds={}
RegisterKeyBind=function(key,callback) keybinds[key]=callback end
hooks={};RegisterHook=function(path,callback) hooks[path]=callback end
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
        module=(pathlib.Path(__file__).parents[1] / 'ReplayBridge/Scripts/Movement.lua').read_text()
        self.lua.execute('package.preload.Movement=function()\n'+module+'\nend')

    def tearDown(self):
        self.temp.cleanup()

    def start(self, mode='record', expiry=1100, replay=''):
        (self.data / 'request.txt').write_text(f'{mode}\nsession123\n{expiry}\n{replay}\n')
        if mode=='play':
            (self.data/'safety.txt').write_text('session123\nready\nMock native guard')
        self.bridge=self.lua.execute(SOURCE+'\nreturn movementIO')

    def commands(self):
        return list(self.lua.globals().commands.values())

    def tick(self):
        return self.lua.globals().loop()

    def test_normal_launch_is_idle(self):
        self.lua.execute(SOURCE)
        self.assertIsNone(self.lua.globals().loop)

    def test_replay_requires_current_session_native_guard_before_demoplay(self):
        self.start('play',replay='TestReplay')
        for content in ['', 'other\nready\nGuard', 'session123\nerror\nUnsupported build']:
            (self.data/'safety.txt').write_text(content)
            self.tick()
            self.assertFalse(any(c.startswith('demoplay') for c in self.commands()))
        self.assertIn('viewer_safety_error',(self.data/'status.txt').read_text())
        (self.data/'safety.txt').write_text('session123\nready\nVerified')
        self.tick()
        self.assertIn('demoplay TestReplay',self.commands())

    def test_replay_menu_exit_closes_the_protected_process_without_opening_live_menu(self):
        self.setup_viewer();self.start('play',replay='TestReplay')
        self.lua.execute('replayPlaying=true');self.tick();self.tick()
        self.lua.execute("hooks['/Script/Tempest.TedPlayerController:ExitCurrentGame']({get=function()return pc end},{get=function()return false end})")
        self.assertEqual((self.data/'close-viewer.txt').read_text(),'session123')
        self.assertEqual(self.commands()[-1],'exit')
        self.assertFalse(any(c.startswith('open ') for c in self.commands()))
        self.assertFalse((self.data/'restore-safety.txt').exists())

    def test_tooltip_hover_uses_cursor_bounds_instead_of_latched_native_hover(self):
        self.start('play',replay='TestReplay');self.lua.globals().bridge=self.bridge
        self.lua.execute('''
        inside=false
        local v=function()return true end
        local slate={IsValid=v,GetLocalSize=function()return {X=1,Y=1} end,IsUnderLocation=function()return inside end}
        local layout={IsValid=v,GetMousePositionOnPlatform=function()return {} end}
        StaticFindObject=function(path)if path:find('SlateBlueprint')then return slate else return layout end end
        local w={IsValid=v,IsHovered=function()return true end,GetCachedGeometry=function()return {} end}
        assert(not bridge:underCursor(w));inside=true;assert(bridge:underCursor(w))
        slate.GetLocalSize=function()return {X=0,Y=0} end
        assert(bridge:underCursor(w)) -- empty native const-reference geometry
        ''')

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
        self.lua.execute('keybinds[Key.C]();loops[16]()')
        self.assertEqual(self.lua.eval('#moves'),0)

    def test_selected_target_is_followed_and_click_cancels_tracking(self):
        self.setup_input()
        self.lua.execute('replayPlaying=true;keybinds[Key.C]();loops[16]()')
        self.assertEqual(self.lua.eval('moves[1].X'),100)
        self.lua.execute('position.X=300;loops[16]()')
        self.assertEqual(self.lua.eval('moves[2].X'),300)
        self.lua.execute('down=true;loops[16]()')
        self.assertEqual(self.lua.eval('#moves'),2)

    def test_dead_target_stops_tracking(self):
        self.setup_input()
        self.lua.execute('replayPlaying=true;keybinds[Key.C]();actor.IsAlive=function() return false end;loops[16]()')
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

    def test_stat_shortcuts_select_all_eight_options_only_in_replay(self):
        self.setup_input()
        self.lua.execute("""
        choices={}
        widget={IsValid=function() return true end,GetFullName=function() return 'Widget /Engine/Transient.HUD' end,
          IsInViewport=function() return true end,StatsOverview={StatsSelector={IsValid=function() return true end,
            GetOptionsCount=function() return 8 end,SelectOptionByIndex=function(self,i) choices[#choices+1]=i end}}}
        local old=FindAllOf
        FindAllOf=function(c) if c=='TedThirdPartySpectatorHud' then return {widget} end;return old(c) end
        keybinds[Key.Q]();assert(#choices==0)
        replayPlaying=true
        for _,key in ipairs({Key.Q,Key.W,Key.E,Key.R,Key.T,Key.Y,Key.A,Key.S}) do keybinds[key]() end
        for i=1,8 do assert(choices[i]==i-1) end
        """)

    def test_replay_end_pauses_once_and_cannot_be_resumed_with_f8(self):
        self.setup_viewer()
        self.start('play',replay='TestReplay')
        self.bridge.codec.duration=self.lua.eval('function() return 10 end')
        self.lua.execute('replayPlaying=true;replayTime=9;replaySystem.GetReplayCurrentTime=function() return replayTime end')
        self.tick();self.tick()
        self.assertNotIn('demopause',self.commands())
        self.lua.execute('replayTime=10')
        self.tick()
        self.assertEqual(self.commands().count('demopause'),1)
        self.lua.execute('keybinds[Key.F8]();keybinds[Key.F7]()')
        self.tick()
        self.assertEqual(self.commands().count('demopause'),1)
        self.assertIn('viewer_finished',(self.data/'status.txt').read_text(encoding='utf-8'))

    def test_locomotion_hook_changes_only_prepared_infantry_and_resets_when_inactive(self):
        self.setup_input();self.setup_online_companion()
        self.lua.execute("""
        RegisterHook=function(path,callback) animHook=callback end
        anim={IsValid=function() return true end,IsA=function() return true end,
          GetFullName=function() return 'InfantryAnim' end,IsMovingSpeedThreshold=5}
        unit.MeshComp={IsValid=function() return true end,GetAnimInstance=function() return anim end,
          SetComponentTickEnabled=function(self,on)meshTick=on end}
        unit.GetDefinitionAsset=function() return {IsValid=function() return true end,MovementSpeed=550} end
        """)
        self.bridge.animationFrames=self.lua.table()
        self.bridge.updateLocomotion(self.bridge,self.lua.globals().unit,self.lua.eval('{X=550,Y=0,Z=0}'))
        self.lua.execute('assert(meshTick);anim.Speed=100;animHook({get=function() return anim end});assert(anim.Speed==550);assert(anim.MaxSpeed==550);assert(anim.bIsMoving)')
        self.bridge.close(self.bridge)
        self.lua.execute('anim.Speed=100;animHook({get=function() return anim end});assert(anim.Speed==100)')

    def test_right_edge_moves_camera_right_and_outside_viewport_is_ignored(self):
        self.setup_input()
        self.lua.execute("""
        replayPlaying=true
        pc.GetMousePosition=function(self,x,y) x.LocationX=999;y.LocationY=500;return true end
        loops[16]()
        """)
        self.assertLess(self.lua.eval('moves[1].Y'),0)
        self.lua.execute('pc.GetMousePosition=function(self,x,y) x.LocationX=1001;y.LocationY=500;return true end;loops[16]()')
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
        self.assertTrue(self.lua.eval('loops[16]()'))
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
        self.assertFalse(self.lua.eval('loops[16]()'))
        self.lua.execute("""
        endPre({get=function() error('must not inspect actors during transition') end},{get=function() return 1 end})
        FindAllOf=function() error('stale controller') end
        """)
        self.assertTrue(self.tick())
        self.assertTrue(self.lua.eval('loops[16]()'))

    def test_mouse_loop_reuses_game_thread_timer_without_queuing_callbacks(self):
        self.setup_input()
        self.lua.execute("""
        replayPlaying=true
        ExecuteInGameThread=function() error('per-frame coroutine dispatch') end
        for i=1,100 do loops[16]() end
        """)
        self.assertFalse((self.data / 'status.txt').read_text().find('viewer_control_error') >= 0)

    def test_replicated_inprogress_starts_recording_when_client_controller_is_not_ready(self):
        self.lua.execute("gs.MatchState={ToString=function() return 'InProgress' end};began=false")
        self.start()
        self.tick()
        self.assertEqual(len(self.commands()),1)
        self.assertTrue(self.commands()[0].startswith('demorec '))

    def test_replicated_lobby_and_terminal_states_never_start_recording(self):
        self.lua.execute("gs.MatchState={ToString=function() return 'WaitingToStart' end};began=true")
        self.start()
        self.tick()
        self.assertEqual(self.commands(),[])
        self.lua.execute("gs.MatchState={ToString=function() return 'WaitingPostMatch' end}")
        self.tick()
        self.assertEqual(self.commands(),[])

    def test_unrecorded_match_is_reported_instead_of_silently_returning_to_ready(self):
        self.start()
        self.tick()
        self.lua.execute('now=1012')
        self.tick()
        self.assertIn('record_waiting',(self.data / 'status.txt').read_text())
        self.assertIn('started=false',(self.data / 'recording-state.txt').read_text())
        self.lua.execute("worldName='MainMenu';gs.IsA=function() return false end")
        self.tick()
        self.assertIn('record_not_started',(self.data / 'status.txt').read_text())

    def test_speed_cycles_only_during_actual_playback(self):
        self.setup_input()
        self.lua.execute('keybinds[Key.F7]()')
        self.assertIsNone(self.lua.globals().worldSettings.DemoPlayTimeDilation)
        self.lua.execute('replayPlaying=true;keybinds[Key.F7]()')
        self.assertEqual(self.lua.globals().worldSettings.DemoPlayTimeDilation,2)
        self.lua.execute('keybinds[Key.F7]()')
        self.assertEqual(self.lua.globals().worldSettings.DemoPlayTimeDilation,4)
        self.lua.execute('keybinds[Key.F7]()')
        self.assertEqual(self.lua.globals().worldSettings.DemoPlayTimeDilation,0.5)

    def test_speed_control_requires_matching_session_and_supported_value(self):
        self.setup_input()
        self.lua.execute("pc.SetViewTargetWithBlend=function() end; FindAllOf=function(cls) if cls=='PlayerController' then return controllers end;return {} end")
        self.lua.execute('replayPlaying=true')
        self.tick()
        self.lua.execute('now=1004')
        self.tick()
        for request, expected in [('other\nspeed=4\n',1), ('session123\nspeed=3\n',1), ('session123\nspeed=0.5\n',0.5)]:
            (self.data / 'control.txt').write_text(request)
            self.tick()
            self.assertEqual(self.lua.globals().worldSettings.DemoPlayTimeDilation,expected)

    def test_u_calls_panel_buttons_only_in_replay_and_toggles_back(self):
        self.setup_input()
        self.lua.globals().bridge = self.bridge
        self.lua.execute("""
        clicks=0
        function panel() return {v=4,GetVisibility=function(self) return self.v end} end
        hud={IsValid=function() return true end,IsInViewport=function() return true end,
            GetFullName=function() return '/Engine/Transient.TestHud' end,
            VerticalBox_Minimap=panel(),PlayerInfoPanel=panel(),StatsOverview=panel()}
        local function toggle(p) clicks=clicks+1;p.v=p.v==1 and 4 or 1 end
        hud.MinimapShow_ButtonClick=function(self) toggle(self.VerticalBox_Minimap) end
        hud.PlayerListShow_ButtonClick=function(self) toggle(self.PlayerInfoPanel) end
        hud.SingularStatShow_ButtonClick=function(self) toggle(self.StatsOverview) end
        local oldFind=FindAllOf;FindAllOf=function(cls) if cls=='TedThirdPartySpectatorHud' then return {hud} end;return oldFind(cls) end
        removedPins=0
        bridge.visible={Tracked=true}
        bridge.maps={Map={Tracked={IsValid=function() return true end,
            RemoveFromParent=function() removedPins=removedPins+1 end}}}
        keybinds[Key.U]();assert(clicks==0)
        replayPlaying=true;keybinds[Key.U]();assert(clicks==3 and hud.StatsOverview.v==1)
        assert(next(bridge.visible)==nil and removedPins==0)
        keybinds[Key.U]();assert(clicks==6 and hud.StatsOverview.v==4)
        assert(next(bridge.visible)==nil and bridge.maps==nil and removedPins==1)
        """)

    def test_recording_has_no_viewer_hotkeys_or_speed_writes(self):
        self.start();self.lua.execute('began=true');self.tick()
        (self.data / 'control.txt').write_text('session123\nspeed=4\n')
        self.tick()
        self.assertIsNone(self.lua.globals().worldSettings.DemoPlayTimeDilation)
        self.assertIsNone(self.lua.globals().worldSettings.TimeDilation)
        self.assertEqual(len(list(self.lua.globals().keybinds.keys())),0)
        self.assertIsNone(self.lua.globals().loops[250])

    def test_replay_velocity_updates_only_during_playback_and_resets_on_stop(self):
        self.setup_input();self.setup_online_companion()
        path=self.root / 'Tempest/Saved/Demos/TestReplay.movement'
        path.write_bytes(b'TEMPEST_MOVEMENT\t1\tTestReplay\nF\t0\nU\t1\tTank_C\t1\t2076\nP\t1\t10\t20\t30\t0\t0\t0\nF\t1\nP\t1\t110\t20\t30\t0\t0\t0\nE\n')
        self.lua.execute("""
        move={IsValid=function() return true end}
        unit.GetMovementComponent=function() return move end
        unit.IsA=function(self,c) return c=='/Script/Tempest.TedPawn' or c=='/Script/Tempest.TedUnitBase' end
        loops[16]();assert(move.Velocity==nil)
        replayPlaying=true;loops[16]();assert(move.Velocity.X==100)
        replayTime=1;loops[16]();assert(move.Velocity.X==0)
        """)

    def test_recorded_exit_movement_is_not_blocked_by_stale_native_container(self):
        self.setup_input();self.setup_online_companion()
        path=self.root / 'Tempest/Saved/Demos/TestReplay.movement'
        path.write_bytes(b'TEMPEST_MOVEMENT\t1\tTestReplay\nF\t0\nU\t1\tTank_C\t1\t2076\nP\t1\t10\t20\t30\t0\t0\t0\nF\t1\nP\t1\t110\t20\t30\t0\t0\t0\nE\n')
        self.lua.execute('unit.IsInContainer=function() return true end;replayPlaying=true;loops[16]();assert(locationWrites==1)')

    def test_real_garrison_owner_is_not_a_stale_production_container(self):
        self.start('play',replay='TestReplay');self.lua.globals().bridge=self.bridge
        self.lua.execute("""
        local v=function()return true end
        local kind='/Script/Tempest.TedConformationBase'
        local owner={IsValid=v,IsA=function(self,c)return c==kind end}
        local unit={IsValid=v,IsInContainer=function()return true end,GetPawnContainerOwner=function()return owner end}
        assert(bridge:isGarrisoned(unit))
        kind='/Script/Tempest.TedUnitBase';assert(bridge:isGarrisoned(unit))
        kind='/Script/Tempest.TedProductionStructure';assert(not bridge:isGarrisoned(unit))
        unit.IsInContainer=function()return false end;assert(not bridge:isGarrisoned(unit))
        """)

    def test_neutral_presentation_materials_follow_capture_owner_without_reallocation(self):
        self.start('play',replay='TestReplay');self.lua.globals().bridge=self.bridge
        self.lua.execute("""
        local v=function()return true end
        ownerID=0;allocations=0;updates=0
        local mid={IsValid=v,SetVectorParameterValue=function(self,k,c)updates=updates+1;lastColor=c.R end}
        local component={IsValid=v,GetNumMaterials=function()return 1 end,CreateDynamicMaterialInstance=function()allocations=allocations+1;return mid end}
        local actor={GetFullName=function()return 'Neutral' end,GetOwningPlayerID=function()return ownerID end}
        local utils={IsValid=v,GetPlayerColorPreset=function(self,a,id)return {PrimaryColor={R=id+1},SecondaryColor={R=id+1}}end}
        local colors={IsValid=v,PrimaryPlayerColorParamName='Player Color',SecondaryPlayerColorParamName='Player Color Secondary'}
        StaticFindObject=function(p)if p:find('TedUtils')then return utils end;return colors end
        bridge:neutralColor(actor,component);bridge:neutralColor(actor,component)
        assert(allocations==1 and updates==2 and lastColor==1)
        ownerID=1;bridge:neutralColor(actor,component);assert(allocations==1 and updates==4 and lastColor==2)
        """)

    def test_garrison_mesh_stays_hidden_then_reappears_on_unload(self):
        self.start('play',replay='TestReplay');self.lua.globals().bridge=self.bridge
        self.lua.execute("""
        local v=function()return true end
        local inside=true
        local mesh={IsValid=v,SetHiddenInGame=function(self,on)self.hidden=on end,SetVisibility=function(self,on)self.visible=on end}
        local owner={IsValid=v,IsA=function(self,c)return c=='/Script/Tempest.TedConformationBase' end}
        local actor={MeshComp=mesh,GetFullName=function()return 'occupant' end,
          IsInContainer=function()return inside end,GetPawnContainerOwner=function()return owner end,
          SetActorHiddenInGame=function(self,on)self.hidden=on end}
        bridge.isDead=function()return false end
        bridge:garrisonVisuals(actor);assert(actor.hidden and mesh.hidden and not mesh.visible)
        actor.hidden=false;mesh.visible=true
        bridge:garrisonVisuals(actor);assert(actor.hidden and not mesh.visible)
        inside=false;bridge:garrisonVisuals(actor);assert(not actor.hidden and not mesh.hidden and mesh.visible)
        """)

    def test_replay_projectiles_retire_after_destination_and_can_be_reused(self):
        self.start('play',replay='TestReplay')
        self.lua.globals().bridge=self.bridge
        self.lua.execute("""
        px=110;active=true;disabled=0;enabled=0;fxStops=0
        local oldFind=StaticFindObject
        StaticFindObject=function(path)if path=='/Script/Engine.FXSystemComponent' then return {IsValid=function()return true end} end;return oldFind(path) end
        move={IsValid=function()return true end,IsActive=function()return active end,
          Deactivate=function()active=false end,SetComponentTickEnabled=function(self,on)if on then enabled=enabled+1 else disabled=disabled+1 end end}
        shot={IsValid=function()return true end,bHidden=false,ProjectileMovement=move,Target=invalid,
          GetClass=function()return {GetFullName=function()return 'Class /Script/Tempest.TedProjectile' end,ForEachFunction=function()end} end,
          StartLocation={X=0,Y=0,Z=0},TargetLocation={X=100,Y=0,Z=0},
          GetFullName=function()return 'shot' end,K2_GetActorLocation=function()return {X=px,Y=0,Z=0} end,
          SetActorHiddenInGame=function(self,on)self.bHidden=on end,SetActorTickEnabled=function()end,
          K2_GetComponentsByClass=function()return {false,{get=function()return {IsValid=function()return true end,Deactivate=function()fxStops=fxStops+1 end} end}} end,
          ReceiveOnProjectileHit=function()error('must not dispatch damage/hit')end}
        FindAllOf=function(cls)if cls=='TedProjectile' then return {shot} end;return {} end
        bridge:updateProjectiles(0);assert(shot.bHidden and not active and disabled==1 and fxStops==1)
        hooks['/Script/Tempest.TedProjectile:ReceiveOnProjectileFired']({get=function()return shot end})
        assert(enabled==1);shot.bHidden=false;active=true;px=10
        bridge:updateProjectiles(1);assert(not shot.bHidden and active)
        bridge:updateProjectiles(32);assert(shot.bHidden)
        """)

    def test_corpse_collision_stops_immediately_and_mesh_retires_once(self):
        self.start('play',replay='TestReplay');self.lua.globals().bridge=self.bridge
        self.lua.execute('''
        collision=true;hidden=false;ticking=true;deaths=0
        local a={IsValid=function()return true end,GetFullName=function()return 'Sentinel' end,
          DestroyActorDelay=3,ReceiveOnDeath=function()deaths=deaths+1 end,
          SetActorEnableCollision=function(self,v)collision=v end,
          SetActorHiddenInGame=function(self,v)hidden=v end,
          SetActorTickEnabled=function(self,v)ticking=v end,
          MeshComp={IsValid=function()return true end,SetComponentTickEnabled=function()end,
            SetHiddenInGame=function()end}}
        bridge.playTime=10;bridge:deathVisuals(a,true)
        assert(not collision and not hidden and deaths==1)
        bridge:retireCorpses(12.9);assert(not hidden)
        bridge:retireCorpses(13);assert(hidden and not ticking and bridge.retiredCorpses==1)
        bridge:deathVisuals(a,true);bridge:retireCorpses(30)
        assert(deaths==1 and bridge.retiredCorpses==1 and next(bridge.corpseQueue)==nil)
        ''')

    def test_actor_discovery_cache_expires_and_clears_at_teardown(self):
        self.start('play',replay='TestReplay');self.lua.globals().bridge=self.bridge
        self.lua.execute('''
        scans=0;FindAllOf=function()scans=scans+1;return {} end
        for i=1,60 do bridge:cachedActors('TedPawn') end;assert(scans==1)
        bridge.cacheTick=1;bridge:cachedActors('TedPawn');assert(scans==2)
        bridge:close();assert(bridge.actorCache==nil)
        ''')

    def test_replay_pawn_without_combat_attributes_never_enables_primary_tick(self):
        self.start('play',replay='TestReplay');self.lua.globals().bridge=self.bridge
        self.lua.execute('''
        writes=0;enabled=true
        local pawn={GetFullName=function()return 'Pawn' end,SetActorTickEnabled=function(self,v)writes=writes+1;enabled=v end}
        bridge:presentationTick(pawn);assert(writes==1 and not enabled)
        pawn.DefaultAttributeSet={IsValid=function()return true end}
        bridge:presentationTick(pawn);assert(writes==1)
        ''')

    def test_neutral_deployed_asset_is_restored_only_when_mesh_is_missing(self):
        self.start('play',replay='TestReplay');self.lua.globals().bridge=self.bridge
        self.lua.execute('''
        writes=0
        local v=function()return true end
        local asset={IsValid=v,IsA=function(self,c)return c=='/Script/Engine.SkeletalMesh' end}
        local mesh={IsValid=v,IsA=function(self,c)return c=='/Script/Engine.SkeletalMeshComponent' end,
          SetSkeletalMesh=function(self,m)self.SkeletalMesh=m;writes=writes+1 end}
        local pawn={GetFullName=function()return 'NeutralBunker' end,PawnDeath={bDied=false},
          IsA=function(self,c)return c=='/Script/Tempest.TedConformationBase' end,MeshComp=mesh,Mesh_Deployed=asset}
        bridge:neutralMesh(pawn);bridge:neutralMesh(pawn);assert(writes==1 and mesh.SkeletalMesh==asset)
        pawn.PawnDeath.bDied=true;mesh.SkeletalMesh=nil;bridge:neutralMesh(pawn);assert(writes==1)
        ''')

    def test_dead_samples_are_recorded_once_instead_of_growing_every_frame(self):
        self.setup_online_companion();self.start()
        self.lua.execute('began=true');self.tick();self.lua.execute('loops[100]()')
        self.lua.execute('unit.PawnDeath={bDied=true};replayTime=1;loops[100]();replayTime=2;loops[100]();isRecording=false;loops[100]()')
        files=list((self.root/'Tempest/Saved/Demos').glob('*.movement'))
        self.assertEqual(files[0].read_text().count('D\t1\n'),1)

    def test_doctrine_restore_refreshes_ui_once_without_granting_gameplay_research(self):
        self.start('play',replay='TestReplay');self.lua.globals().bridge=self.bridge
        self.lua.execute("""
        refreshed=0
        local asset={IsValid=function()return true end,IsA=function(self,c)return c=='/Script/Tempest.TedDoctrineDefinition' end}
        LoadAsset=function()return asset end
        local owner={IsValid=function()return true end,GetTedPlayerID=function()return 0 end}
        local data={IsValid=function()return true end,GetOwningPlayerState=function()return owner end,GetFullName=function()return 'data' end}
        local widget={IsValid=function()return true end,GetTargetPlayerData=function()return data end,
          OnResearchedDoctrinesChange_Handler_Native=function()refreshed=refreshed+1 end}
        FindAllOf=function(c)if c=='TedPlayerData' then return {data} elseif c=='TedPlayerDataWidget' then return {widget} end;return {} end
        local snapshot={[0]={'/Game/Tempest/DataAssets/Doctrine/GDF/DD_Test.DD_Test'}}
        bridge:restoreDoctrines(snapshot);bridge:restoreDoctrines(snapshot)
        assert(#data.ResearchedDoctrines==1 and refreshed==1)
        bridge:restoreDoctrines({[0]={}});assert(#data.ResearchedDoctrines==0 and refreshed==2)
        """)

    def test_recording_captures_received_doctrines_in_the_paired_companion(self):
        (self.root/'Tempest/Saved/Demos').mkdir(parents=True)
        self.start();self.lua.globals().bridge=self.bridge
        self.lua.execute("""
        local owner={IsValid=function()return true end,GetTedPlayerID=function()return 0 end}
        local asset={IsValid=function()return true end,GetFullName=function()return 'TedDoctrineDefinition /Game/Tempest/DataAssets/Doctrine/GDF/DD_Test.DD_Test' end}
        local data={IsValid=function()return true end,GetOwningPlayerState=function()return owner end,
          ResearchedDoctrines={ForEach=function(self,fn)fn(1,{get=function()return asset end})end}}
        FindAllOf=function(c)if c=='TedPlayerData' then return {data} end;return {} end
        bridge:record({GetReplayCurrentTime=function()return 0 end},'TestReplay',{});bridge:close()
        local reader=bridge.codec.reader(testRoot..'/Tempest/Saved/Demos/TestReplay.movement','TestReplay')
        reader:at(0);assert(reader.doctrines[0][1]=='/Game/Tempest/DataAssets/Doctrine/GDF/DD_Test.DD_Test');reader:close()
        """)

    def test_neutral_structure_is_not_a_placement_preview(self):
        self.start('play', replay='TestReplay')
        actor=self.lua.eval("{GetFullName=function() return 'BP_Conformation_Garage_C_1' end,IsA=function(self,c) return c=='/Script/Tempest.TedConformationBase' end}")
        self.assertTrue(self.bridge.isPresentationPawn(self.bridge,actor))
        actor.GetFullName=self.lua.eval("function() return 'BP_Conformation_Ghost_C_1' end")
        self.assertFalse(self.bridge.isPresentationPawn(self.bridge,actor))

    def test_visibility_refresh_does_not_rehide_existing_actor(self):
        self.setup_viewer()
        self.start('play', replay='TestReplay')
        self.lua.execute('replayPlaying=true')
        self.tick();self.tick()
        self.lua.globals().hiddenCalls=0
        self.tick()
        self.assertEqual(self.lua.globals().hiddenCalls,1)  # show only; no hide/show reset

    def test_u_refreshes_replay_actor_visibility_without_rehiding(self):
        self.setup_viewer()
        self.lua.execute('''
        visibilityCalls=0
        actor.K2_SetDefaultVisibility=function() visibilityCalls=visibilityCalls+1 end
        ''')
        self.start('play',replay='TestReplay')
        self.lua.execute('replayPlaying=true')
        self.tick();self.tick();self.tick()
        initial=self.lua.globals().visibilityCalls
        self.tick()
        self.assertEqual(self.lua.globals().visibilityCalls,initial)
        self.lua.execute('pc.Pawn={IsValid=function() return true end}')
        self.lua.execute('keybinds[Key.U]()')
        self.tick()
        self.assertEqual(self.lua.globals().visibilityCalls,initial+1)
        self.tick()
        self.assertEqual(self.lua.globals().visibilityCalls,initial+1)

    def test_native_neutral_visibility_never_forces_destroyed_mesh(self):
        self.setup_viewer()
        self.lua.execute("""
        neutralInitialized=0
        placeholder.IsAlive=function() return false end
        placeholder.IsA=function(self,c) return c=='/Script/Tempest.TedConformationBase' end
        placeholder.SetDestroyedMeshOnVisibilityChange=function() neutralInitialized=neutralInitialized+1 end
        """)
        self.start('play', replay='TestReplay')
        self.lua.execute('replayPlaying=true')
        self.tick();self.tick()
        self.assertEqual(self.lua.globals().neutralInitialized,0)

    def test_explicit_death_is_not_overridden_by_companion_visibility(self):
        self.setup_input();self.setup_online_companion()
        path=self.root / 'Tempest/Saved/Demos/TestReplay.movement'
        path.write_bytes(b'TEMPEST_MOVEMENT\t1\tTestReplay\nF\t0\nU\t1\tTank_C\t1\t2076\nP\t1\t10\t20\t30\t0\t0\t0\nF\t1\nE\n')
        self.lua.execute("""
        replayPlaying=true;loops[16]();assert(locationWrites==1)
        unit.PawnDeath={bDied=true};unitHidden=nil
        loops[16]();assert(locationWrites==1);assert(unitHidden==nil)
        replayTime=1;loops[16]();assert(unitHidden==nil)
        """)
        self.assertFalse(self.bridge.alive(self.bridge,self.lua.globals().unit))

    def setup_movement_actor(self):
        self.lua.execute("""
        movementChanges=0
        world.AuthorityGameMode={IsValid=function() return true end}
        unit={IsValid=function() return true end,
          IsA=function(self,cls) return cls=='/Script/Tempest.TedPawn' end,
          GetFullName=function() return 'TestUnit' end,GetWorld=function() return world end,
          SetReplicateMovement=function(self,on) assert(on);movementChanges=movementChanges+1 end,
          ForceNetUpdate=function() end}
        """)

    def test_standalone_recording_does_not_modify_unit_replication(self):
        self.setup_movement_actor()
        self.start()
        self.assertIsNone(self.lua.globals().beginPost)
        self.assertEqual(self.lua.globals().movementChanges,0)

    def test_online_unit_replication_is_not_modified(self):
        self.setup_movement_actor()
        self.lua.execute('world.NetDriver={IsValid=function() return true end}')
        self.start()
        self.assertIsNone(self.lua.globals().beginPost)
        self.assertEqual(self.lua.globals().movementChanges,0)

    def test_client_without_authority_does_not_change_movement_replication(self):
        self.setup_movement_actor()
        self.lua.execute('world.AuthorityGameMode=invalid')
        self.start()
        self.assertIsNone(self.lua.globals().beginPost)
        self.assertEqual(self.lua.globals().movementChanges,0)

    def setup_online_companion(self):
        (self.root / 'Tempest/Saved/Demos').mkdir(parents=True)
        self.setup_movement_actor()
        self.lua.execute("""
        world.NetDriver={IsValid=function() return true end};world.AuthorityGameMode=invalid
        PropertyTypes={IntProperty=1};aliasCalls=0
        RegisterCustomProperty=function(info) assert(info.OffsetInternal.Property=='EntityHandle');aliasCalls=aliasCalls+1 end
        local oldFind=StaticFindObject
        StaticFindObject=function(path)
          if path=='/Script/NubECS.EcsActorComponent' then return {
            IsValid=function() return true end,ForEachProperty=function(self,cb) cb({
              GetFName=function() return FName('EntityHandle') end,
              GetStruct=function() return {GetFullName=function() return 'ScriptStruct /Script/NubECS.EcsEntityHandle' end} end}) end} end
          return oldFind(path)
        end
        unit.EcsActor={IsValid=function() return true end,TempestReplayEntityKey=2076}
        unit.GetClass=function() return {GetFName=function() return FName('Tank_C') end,
          GetFullName=function() return 'Class Tank_C' end,ForEachFunction=function() end} end
        unit.SetActorEnableCollision=function() end;unit.SetActorTickEnabled=function() end;unit.ReceiveOnDeath=function() end
        unit.GetOwningPlayerID=function() return 1 end
        unit.IsAlive=function() return true end;unit.IsInContainer=function() return false end
        unit.IsConstructing=function() return false end
        unit.K2_GetActorLocation=function() return {X=unitX or 10,Y=20,Z=30} end
        unit.K2_GetActorRotation=function() return {Pitch=0,Yaw=0,Roll=0} end
        unit.K2_SetActorLocation=function(self,pos) unitX=pos.X;locationWrites=(locationWrites or 0)+1 end
        unit.K2_SetActorRotation=function() end
        unit.K2_SetDefaultVisibility=function() end;unit.K2_OnVisibilityChanged=function() end
        unit.SetActorHiddenInGame=function(self,hidden) unitHidden=hidden end
        FindAllOf=function(cls) if cls=='PlayerController' then return controllers elseif cls=='TedPawn' then return {unit} end;return {} end
        replayTime=0;replayPlaying=false;isRecording=true
        replaySystem={IsValid=function() return true end,IsPlaying=function() return replayPlaying end,
          IsRecording=function() return isRecording end,GetReplayCurrentTime=function() return replayTime end}
        FindFirstOf=function(cls) if cls=='ReplaySubsystem' then return replaySystem end;return invalid end
        """)

    def test_online_client_records_local_positions_without_replication_or_location_writes(self):
        self.setup_online_companion()
        self.start();self.tick();self.lua.execute('began=true');self.tick()
        self.lua.execute('loops[100]();replayTime=0.1;unitX=90;loops[100]()')
        files=list((self.root / 'Tempest/Saved/Demos').glob('*.movement'))
        self.assertEqual(len(files),1)
        text=files[0].read_text()
        self.assertIn('Tank_C\t1\t2076',text)
        self.assertIn('90.000',text)
        self.assertEqual(self.lua.globals().movementChanges,0)
        self.assertIsNone(self.lua.globals().locationWrites)
        self.assertEqual(self.lua.globals().aliasCalls,1)
        self.lua.execute('ended=true');self.tick()
        self.assertTrue(files[0].read_text().endswith('E\n'))
        self.assertIn('completed',(self.data / 'movement-state.txt').read_text())
        self.lua.execute('isRecording=false;loops[100]()')
        self.assertTrue(files[0].read_text().endswith('E\n'))

    def test_network_structure_presence_is_recorded_without_changing_replication(self):
        self.setup_online_companion()
        self.lua.execute("unit.IsA=function(self,cls) return cls=='/Script/Tempest.TedPawn' or cls=='/Script/Tempest.TedStructureBase' end")
        self.start();self.tick();self.lua.execute('began=true');self.tick();self.lua.execute('loops[100]()')
        files=list((self.root / 'Tempest/Saved/Demos').glob('*.movement'))
        self.assertEqual(len(files),1)
        self.assertIn('Tank_C',files[0].read_text())
        self.assertEqual(self.lua.globals().movementChanges,0)
        self.lua.execute('isRecording=false;loops[100]()')

    def test_building_lifecycle_records_construction_before_alive_and_explicit_death(self):
        self.setup_online_companion()
        self.lua.execute("""
        unit.IsA=function(self,c) return c=='/Script/Tempest.TedPawn' or c=='/Script/Tempest.TedStructureBase' end
        constructing=true;alive=false
        unit.IsConstructing=function() return constructing end;unit.IsAlive=function() return alive end
        """)
        self.start();self.tick();self.lua.execute('began=true');self.tick()
        self.lua.execute('loops[100]();replayTime=1;constructing=false;alive=true;loops[100]();replayTime=2;alive=false;unit.PawnDeath={bDied=true};loops[100]();isRecording=false;loops[100]()')
        text=next((self.root/'Tempest/Saved/Demos').glob('*.movement')).read_text()
        self.assertIn('B\t1\t1',text);self.assertIn('B\t1\t2',text);self.assertIn('B\t1\t3',text)
        self.assertIsNone(self.lua.globals().locationWrites)

    def test_building_visual_transitions_once_and_never_resurrect_death(self):
        self.start('play',replay='TestReplay')
        actor=self.lua.eval("""{IsA=function(self,c) return c=='/Script/Tempest.TedStructureBase' end,
          GetFullName=function() return 'Building' end,SetActorEnableCollision=function() end,SetActorTickEnabled=function() end,
          ReceiveHandleConstructionVisuals=function(self,v) self.constructCalls=(self.constructCalls or 0)+1 end,
          ReceiveOnDeath=function(self) self.deathCalls=(self.deathCalls or 0)+1 end}""")
        for state in [1,1,2,2,3,3,2]: self.bridge.buildingVisuals(self.bridge,actor,state)
        self.assertEqual(actor.constructCalls,2);self.assertEqual(actor.deathCalls,1)

    def test_replay_exit_unpauses_and_requests_local_quit(self):
        self.setup_viewer();self.start('play',replay='TestReplay')
        self.lua.execute('replayPlaying=true');self.tick();self.tick()
        self.lua.execute("""
        worldSettings.PauserPlayerState=pc.PlayerState
        hooks['/Script/Tempest.TedPlayerController:ExitCurrentGame']({get=function() return pc end},{get=function() return true end})
        assert(commands[#commands]=='exit');assert(worldSettings.PauserPlayerState==nil);assert(loops[16]())
        """)

    def test_confirmed_exit_signal_only_exists_for_replay_sessions(self):
        self.start()
        self.assertIsNone(self.lua.globals().localExecPre)
        self.start('play',replay='TestReplay')
        self.lua.execute("localExecPre(nil,nil,'demopause');localExecPre(nil,nil,'quit later')")
        self.assertFalse((self.data/'shutdown.txt').exists())
        self.lua.execute("local _,run=localExecPre(nil,nil,' QUIT ');assert(run)")
        self.assertEqual((self.data/'shutdown.txt').read_text(),'session123')

    def test_production_queue_completion_never_replays_building_placement(self):
        self.start('play',replay='TestReplay')
        self.lua.globals().bridge=self.bridge
        self.lua.execute("""
        local v=function() return true end
        local anim={IsValid=v,Montage_IsPlaying=function() return false end,
          Montage_Play=function(self,m,s,r,t,stop) assert(s==1 and not stop);plays=(plays or 0)+1 end}
        local a={IsA=function(self,c) return c=='/Script/Tempest.TedStructureBase' end,
          GetFullName=function() return 'Structure' end,SetActorEnableCollision=function() end,SetActorTickEnabled=function() end,
          ReceiveHandleConstructionVisuals=function() end,SpawnAnimation={IsValid=v},
          MeshComp={IsValid=v,GetAnimInstance=function() return anim end,SetComponentTickEnabled=function() end}}
        bridge:buildingVisuals(a,2);assert(plays==nil)
        bridge:buildingVisuals(a,1);bridge:buildingVisuals(a,2);bridge:buildingVisuals(a,2)
        assert(plays==nil)
        """)

    def test_reused_gdf_site_selects_zero_based_barracks_footprint_once(self):
        self.start('play',replay='TestReplay');self.lua.globals().bridge=self.bridge
        self.lua.execute("""
        local v=function() return true end
        local site={IsA=function(self,c) return c=='/Script/Tempest.TedConstructionSite' end,
          ActiveFootprintConfig=0,FootprintConfigs={ForEach=function(self,fn)
            fn(1,{get=function() return {GridSize={X=5,Y=6}} end})
            fn(2,{get=function() return {GridSize={X=3,Y=6}} end}) end},
          OnRep_ActiveFootprint=function() changed=(changed or 0)+1 end,
          OnRep_ConstructionProgress=function() end}
        LoadAsset=function() return {IsValid=v,GetCDO=function() return {StructureGridSize={X=3,Y=6}} end} end
        bridge.catalog={site={segments={{time=23,last=40,target={time=40,class='BP_BD_GDF_Barracks_C'}}}}}
        assert(bridge:siteVisuals(site,'site',{},30))
        assert(site.ActiveFootprintConfig==1 and changed==1)
        assert(site.LastConstructionProgress>0 and site.LastConstructionProgress<1)
        bridge:siteVisuals(site,'site',{},31);assert(changed==1)
        assert(not bridge:siteVisuals(site,'site',{},40))
        """)

    def test_match_end_flushes_pending_death_before_stopping_driver(self):
        self.setup_online_companion();self.start()
        self.lua.execute('began=true');self.tick();self.lua.execute('loops[100]()')
        self.lua.execute("""
        hooks['/Script/Tempest.TedPawn:ReceiveOnDeath']({get=function() return unit end})
        local old=FindAllOf;FindAllOf=function(c) if c=='TedPawn' then return {} end;return old(c) end
        replayTime=1;ended=true
        """)
        self.tick()
        files=list((self.root/'Tempest/Saved/Demos').glob('*.movement'))
        self.assertIn('D\t1',files[0].read_text())
        self.assertTrue(files[0].read_text().endswith('E\n'))
        self.assertEqual(self.commands()[-1],'demostop')

    def test_direct_speed_keys_are_replay_only(self):
        self.setup_input()
        self.lua.execute('keybinds[0x34]()')
        self.assertIsNone(self.lua.globals().worldSettings.DemoPlayTimeDilation)
        self.lua.execute('replayPlaying=true;keybinds[0x34]()')
        self.assertEqual(self.lua.globals().worldSettings.DemoPlayTimeDilation,4)
        self.lua.execute('keybinds[0x32]()')
        self.assertEqual(self.lua.globals().worldSettings.DemoPlayTimeDilation,2)
        self.lua.execute('keybinds[0x31]()')
        self.assertEqual(self.lua.globals().worldSettings.DemoPlayTimeDilation,1)

    def test_dead_vehicle_and_aircraft_effects_run_once_even_with_native_death_bit(self):
        self.start('play',replay='TestReplay')
        self.lua.globals().bridge=self.bridge
        self.lua.execute("""
        deaths=0
        for _,name in ipairs({'Pillager','Aircraft','FlameTurret'}) do
          local a={PawnDeath={bDied=true},GetFullName=function() return name end,
            SetActorEnableCollision=function() end,SetActorTickEnabled=function() end,ReceiveOnDeath=function() deaths=deaths+1 end}
          bridge:deathVisuals(a,true);bridge:deathVisuals(a,true)
        end
        assert(deaths==3)
        """)

    def test_recorded_death_survives_actor_removal_before_next_snapshot(self):
        self.setup_online_companion();self.start()
        self.lua.execute('began=true');self.tick();self.lua.execute('loops[100]()')
        self.lua.execute("""
        hooks['/Script/Tempest.TedPawn:ReceiveOnDeath']({get=function() return unit end})
        local old=FindAllOf;FindAllOf=function(c) if c=='TedPawn' then return {} end;return old(c) end
        replayTime=1;loops[100]();isRecording=false;loops[100]()
        """)
        files=list((self.root/'Tempest/Saved/Demos').glob('*.movement'))
        self.assertIn('D\t1',files[0].read_text())

    def test_doctrine_hover_retains_overview_and_enables_child_icon_tooltips(self):
        self.setup_input()
        self.lua.globals().bridge=self.bridge
        self.lua.execute("""
        local v=function() return true end
        local cls={IsValid=v}
        hoveringSource=true;hoveringPopup=false;hoveringIcon=false;removed=0;descriptions=0
        source={IsValid=v,GetFullName=function() return 'Source' end,IsHovered=function() return hoveringSource end,
          IsCustomTooltipShown=function() return false end,GetOwningPlayer=function() return pc end}
        panel={IsValid=v,GetFullName=function() return 'Panel' end,SetVisibility=function() end,bResearchable=true}
        icon={IsValid=v,GetFullName=function() return 'Icon' end,GetDoctrinePanel=function() return panel end,CustomTooltipClass=cls,
          IsHovered=function() return hoveringIcon end,GetTitle=function() return 'Hovered title' end,GetDescription=function() return 'Hovered description' end,
          SetVisibility=function(self,x) self.visibility=x end,SetIsEnabled=function(self,x) self.enabled=x end}
        tip={IsValid=v,GetFullName=function() return 'Clone' end,OnTooltipShown=function() end,AddToViewport=function() end,
          SetVisibility=function() end,IsHovered=function() return hoveringPopup end,DoctrinePanelA=panel,
          RemoveFromParent=function() removed=removed+1 end}
        original={IsValid=v,GetParent=function()return invalid end,IsInViewport=function()return false end,SetVisibility=function(self,x) self.visibility=x end}
        local library={IsValid=v,Create=function(self,owner,c)
          if c==cls then descriptions=descriptions+1;return {IsValid=v,OnTooltipShown=function() end,
            AddToViewport=function() end,SetVisibility=function() end,RemoveFromParent=function() removed=removed+1 end,
            TextBlock_Name={IsValid=v,SetText=function(self,x) title=x end},
            TextBlock_Description={IsValid=v,SetText=function(self,x) description=x end}} end
          return tip end}
        local old=StaticFindObject;StaticFindObject=function(p)
          if p=='/Script/UMG.Default__WidgetBlueprintLibrary' then return library end;return old(p) end
        local oldFind=FindAllOf;FindAllOf=function(c) if c=='TedDoctrineSlot' then return {icon} end;return oldFind(c) end
        bridge:activateDoctrineTooltip(nil,source,original,{IsValid=v})
        assert(original.visibility==2 and not panel.bResearchable and icon.enabled and icon.visibility==0)
        assert(not icon.CustomTooltipClass:IsValid() and not icon.bTrackAsWidgetUnderCursor)
        hoveringSource=false;hoveringPopup=true;hoveringIcon=true
        loops[50]();assert(descriptions==1 and removed==0 and title=='Hovered title' and description=='Hovered description')
        for i=1,10 do loops[50]() end;assert(descriptions==1 and removed==0)
        hoveringIcon=false;loops[50]();loops[50]();assert(descriptions==1 and removed==0)
        hoveringIcon=true;loops[50]();assert(descriptions==1 and removed==0)
        hoveringPopup=false;hoveringIcon=false
        for i=1,5 do loops[50]() end;assert(removed==0)
        loops[50]();assert(removed==0 and bridge.viewerDoctrinePopup==nil)
        hoveringSource=true;bridge:activateDoctrineTooltip(nil,source,original,{IsValid=v})
        hoveringIcon=true;loops[50]();assert(descriptions==1)
        bridge:clearDoctrinePopup();bridge.doctrinePoll=0
        source.GetHUD=function()return nil end;source.CustomTooltipClass={IsValid=v}
        original.IsVisible=function()return true end;original.IsInViewport=function()return false end;original.GetVisibility=function()return 0 end
        original.GetTargetWidget=function()return source end;original.RemoveFromParent=function()end
        local priorFind=FindAllOf
        FindAllOf=function(c)if c=='WBP_ThirdPartySpectator_Doctrines_Tooltip_C' then return {original} end;return priorFind(c) end
        for i=1,9 do loops[50]();assert(bridge.viewerDoctrinePopup==nil) end
        loops[50]();assert(bridge.viewerDoctrinePopup~=nil) -- direct Blueprint call without ProcessEvent hook
        """)

    def test_replay_menu_exit_ignores_hover_and_other_slots(self):
        self.setup_viewer();self.start('play',replay='TestReplay')
        self.lua.execute('replayPlaying=true');self.tick();self.tick()
        self.lua.execute("""
        local slot={IsValid=function() return true end,GetFullName=function() return 'Menu.Main' end}
        local menu={IsValid=function() return true end,Slot_MainMenu=slot,Slot_Quit=invalid}
        local wrap=function(v) return {get=function() return v end} end
        local hook=hooks['/Script/Tempest.TedPauseMenuScreen:OnPauseMenuButtonSlotAction']
        hook(wrap(menu),nil,wrap(slot),wrap(1));assert(commands[#commands]~='open /Game/Tempest/Maps/MainMenu/MAP_MainMenu_P')
        hook(wrap(menu),nil,wrap(slot),wrap(0));assert(commands[#commands]~='open /Game/Tempest/Maps/MainMenu/MAP_MainMenu_P')
        """)

    def test_replay_quit_requires_exact_popup_confirm_and_defers_dispatch(self):
        self.setup_viewer();self.start('play',replay='TestReplay')
        self.lua.execute('replayPlaying=true');self.tick();self.tick()
        self.lua.execute("""
        local v=function() return true end
        local wrap=function(x) return {get=function() return x end} end
        local quit={IsValid=v,GetFullName=function() return 'Menu.Quit' end}
        local panel={IsValid=v,GetFullName=function() return 'ExitPopup.Buttons' end,GetContentSlotsCount=function() return 2 end}
        local popup={IsValid=v,IsVisible=function() return true end,ButtonsPanel=panel}
        local menu={IsValid=v,Slot_Quit=quit,Slot_MainMenu=invalid,GetPauseMenuPopup=function() return popup end,
          GetOwningPlayer=function() return pc end}
        local oldFind=FindAllOf;FindAllOf=function(c) if c=='TedPauseMenuScreen' then return {menu} end;return oldFind(c) end
        local index=0
        local button={IsValid=v,GetFullName=function() return 'ConfirmButton' end,GetParentContentPanel=function() return panel end,GetSlotIndex=function() return index end}
        local menuHook=hooks['/Script/Tempest.TedPauseMenuScreen:OnPauseMenuButtonSlotAction']
        local buttonHook=hooks['/Script/Tempest.TedContentPanelSlotBase:TriggerAction']
        menuHook(wrap(menu),nil,wrap(quit),wrap(0));assert(commands[#commands]~='exit')
        buttonHook(wrap(button),wrap(1));assert(not loops[1]) -- hover is not confirm
        buttonHook(wrap(button),wrap(0));assert(not loops[1]) -- cancel
        index=1;buttonHook(wrap(button),wrap(0));assert(not loops[1]) -- stale confirm after cancel
        buttonHook(wrap(quit),wrap(0)) -- direct native menu-handler fallback
        local other={IsValid=v,GetFullName=function() return 'OtherButton' end,GetParentContentPanel=function() return {IsValid=v,GetFullName=function() return 'OtherPopup' end} end}
        buttonHook(wrap(other),wrap(0));assert(not loops[1])
        buttonHook(wrap(button),wrap(0));assert(loops[1] and commands[#commands]~='exit')
        assert(loops[1]());assert(commands[#commands]=='exit')
        """)
        self.assertEqual((self.data/'shutdown.txt').read_text(),'session123')

    def test_online_companion_does_not_start_without_native_recording(self):
        self.setup_online_companion()
        self.start();self.tick();self.lua.execute('began=true;isRecording=false');self.tick()
        self.lua.execute('loops[100]()')
        self.assertEqual(list((self.root / 'Tempest/Saved/Demos').glob('*.movement')),[])

    def test_online_companion_applies_only_during_actual_playback(self):
        self.setup_input()
        self.setup_online_companion()
        path=self.root / 'Tempest/Saved/Demos/TestReplay.movement'
        path.write_bytes(b'TEMPEST_MOVEMENT\t1\tTestReplay\nF\t0\nU\t1\tTank_C\t1\t2076\nP\t1\t123\t20\t30\t0\t0\t0\nE\n')
        # setup_input already started play mode; its input callback sees the newly provided native mocks.
        self.lua.execute('loops[16]()')
        self.assertIsNone(self.lua.globals().locationWrites)
        self.lua.execute('replayPlaying=true;loops[16]()')
        self.assertEqual(self.lua.globals().unitX,123)
        self.assertEqual(self.lua.globals().movementChanges,0)

    def test_recorded_alive_presence_overrides_incomplete_client_demo_health(self):
        self.setup_input();self.setup_online_companion()
        path=self.root / 'Tempest/Saved/Demos/TestReplay.movement'
        path.write_bytes(b'TEMPEST_MOVEMENT\t1\tTestReplay\nF\t0\nU\t1\tTank_C\t1\t2076\nP\t1\t123\t20\t30\t0\t0\t0\nF\t1\nE\n')
        self.lua.execute('unit.IsAlive=function() return false end;replayPlaying=true;loops[16]()')
        self.assertEqual(self.lua.globals().unitX,123)
        self.assertFalse(self.lua.globals().unitHidden)
        self.lua.execute('replayTime=1;loops[16]()')
        self.assertTrue(self.lua.globals().unitHidden)

    def test_minimap_pins_use_native_projection_and_remove_absent_targets(self):
        self.setup_input();self.setup_online_companion()
        self.lua.globals().bridge=self.bridge
        self.lua.execute("""
        local valid=function() return true end
        local color={R=0.2,G=0.4,B=0.8,A=1}
        local utils={IsValid=valid,GetWorldBounds=function() return {} end,
          GetPlayerColorPreset=function() return {PrimaryColor=color} end}
        local ui={IsValid=valid,CalculateMinimapLocation=function(self,b,p,s,out) out.X=75;out.Y=125 end}
        local old=StaticFindObject;StaticFindObject=function(p)
          if p=='/Script/Tempest.Default__TedUtils' then return utils end
          if p=='/Script/Tempest.Default__TedUIFunctionsLibrary' then return ui end
          if p=='/Script/UMG.Image' then return {IsValid=valid} end
          return old(p)
        end
        created=0;removed=0
        StaticConstructObject=function()
          created=created+1
          pin={IsValid=valid,SetVisibility=function(self,v) self.visibility=v end,
            SetColorAndOpacity=function(self,c) self.color=c end,
            RemoveFromParent=function() removed=removed+1 end,
            Slot={SetSize=function(self,s) self.size=s end,SetPosition=function(self,p) self.position=p end,SetZOrder=function() end}}
          return pin
        end
        local canvas={IsValid=valid,IsA=function() return true end,AddChildToCanvas=function() end}
        local widget={IsValid=valid,GetFullName=function() return 'Map' end,GetMinimapSize=function() return {X=228,Y=228} end,
          MinimapImage={IsValid=valid,GetParent=function() return canvas end,Slot={GetPosition=function() return {X=0,Y=0} end}}}
        FindAllOf=function(c) if c=='TedMinimapWidget' then return {widget} end;return {} end
        unit.IsAlive=function() return false end
        unit.IsA=function(self,c) return c=='/Script/Tempest.TedStructureBase' end
        samples={track={position={X=30,Y=50,Z=0}}};actors={track=unit}
        bridge:updateMarkers(actors,samples)
        assert(created==1 and pin.visibility==3 and pin.color==color)
        assert(pin.Slot.size.X==5 and pin.Slot.position.X==72.5 and pin.Slot.position.Y==122.5)
        bridge:updateMarkers(actors,samples);assert(created==1)
        bridge:updateMarkers({},{});assert(removed==1 and next(bridge.maps.Map)==nil)
        """)

    def test_companion_opened_before_first_world_status_survives_world_ready(self):
        self.setup_input();self.setup_online_companion()
        path=self.root / 'Tempest/Saved/Demos/TestReplay.movement'
        path.write_bytes(b'TEMPEST_MOVEMENT\t1\tTestReplay\nF\t0\nU\t1\tTank_C\t1\t2076\nP\t1\t0\t20\t30\t0\t0\t0\nF\t1\nP\t1\t100\t20\t30\t0\t0\t0\nF\t2\nP\t1\t200\t20\t30\t0\t0\t0\nE\n')
        self.lua.execute('replayPlaying=true;loops[16]()')
        self.tick()
        self.lua.execute('replayTime=0.5;loops[16]()')
        self.assertEqual(self.lua.globals().unitX,50)
        self.lua.execute('replayTime=3;loops[16]()')

    def test_duplicate_online_identity_disables_companion_instead_of_swapping_units(self):
        self.setup_online_companion()
        self.lua.execute("local oldFind=FindAllOf;FindAllOf=function(cls) if cls=='TedPawn' then return {unit,unit} end;return oldFind(cls) end")
        self.start();self.tick();self.lua.execute('began=true');self.tick();self.lua.execute('loops[100]()')
        self.assertIn('Duplicate ECS identity',(self.data / 'status.txt').read_text())
        self.assertIsNone(self.lua.globals().locationWrites)


if __name__ == '__main__':
    unittest.main()
