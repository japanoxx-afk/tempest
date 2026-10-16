# Native replay validation

Test host: installed Steam build 25752338, Unreal 5.4.3. Local test date: 2026-10-16 (Asia/Seoul).

## Confirmed recording failure cause

The original UEHelpers.GetPlayerController helper selects a controller for which `IsPlayerController()` is true. In this game that includes `BP_BotPlayerController_Skirmish_C`. The native diagnostic harness observed that bot as the selected command context. Its Player does not point to a ULocalPlayer, so the Kismet wrapper returns without reaching the local player's Exec path.

Read-only PE inspection located the DEMOREC/DEMOPLAY dispatch in the installed executable, with the recording handler calling the game instance's virtual recording entry point. No executable patch or injected native machine code was needed. Selecting a controller whose Player is a real `/Script/Engine.LocalPlayer` made `demorec` reach `ULocalPlayer::Exec`, as observed by a UE4SS pre-hook.

Earlier theories about INI settings and map travel were not sufficient diagnoses. Native driver availability matters, but command routing to an AI controller independently prevented recording. Mock tests did not model this distinction until the real runtime trace exposed it.

## Recording evidence

- Test replay: `Tempest_20261016_014659_b389cbe7_1.replay`.
- Actual native Exec observed the recording command.
- World.DemoNetDriver became active.
- The file grew from 128,797 to 282,176 bytes.
- Return to the main menu finalized the file; it survived a complete game restart.
- Final SHA256: `3A699D34DDDCD1B5C75BF51E17DCC46C4D7AFB65AB3D334415EC7EEB0D1FAB10`.
- Storage: `%LOCALAPPDATA%\Tempest\Saved\Demos`.

The test contained building construction. File creation alone does not prove full world-state reconstruction or successful spectator playback.

## Playback evidence and scope

A clean game restart accepted the replay file and loaded Overgrown Oasis. Initial attempts had a black terrain view, missing HUD and concealed structures. These were separate from the recording failure:

- The game's TedSpectatorController_BP asset must be assigned as ReplaySpectatorPlayerControllerClass before replay travel.
- ClientSetHUD uses the recorded GameModeClass CDO's HUDClass, then ClientGotoState enters Spectating. The native spectator HUD becomes active, with both players' statistics.
- FogOfWarActor.K2_SetTemporarilyUnfog restores terrain in replay playback.
- The native TedPlayerCameraComponent.InterpolateCameraToLocation focuses a recorded construction yard. Actor location alone is overwritten by this camera component.
- TedStructureBase.SetInitiallyVisible and construction visuals initialization restore the building animation state. Skeletal animation must tick despite the replay spectator's absent visibility channel. Direct actor hidden-state synchronization plus component visibility refresh restores the render state; calling SetActorHiddenInGame alone was insufficient in this game.
- A recorded pause can stop demo delivery. Replay playback clears a pauser belonging to the original recorded player while preserving a pause belonging to the new local spectator.

In clean session b1447ac17f7243d49324f5a8ed469740, the installed Lua exactly matched source SHA256 `9D83111889689516C84A634102E0ABF49C9A94AD3296B8CE4426E6F7E6A443A5`. No development harness was present. Replay time advanced from 9.46 to 21.24 seconds. Screenshots observed the original textured GDF construction yard and a construction site changing into an advanced power plant. The game's native spectator HUD showed both players, resources, power and increasing structure counts. ReplaySubsystem.IsPlaying, HUD.IsSpectatorModeActive and IsOnlyASpectator were true. This confirms file-backed offline playback and spectator UI, not full game-wide replay correctness.

The viewer changes are gated by play mode AND ReplaySubsystem.IsPlaying. Design placeholders, ghosts, dead pawns and contained units are excluded. No visibility correction runs during recording. The repository's 23 mocked control-flow tests include AI-vs-local controller selection, viewer gating and recorded-vs-local pause ownership. Mocks are regression checks, not evidence of native compatibility.

Known limits: only a short offline skirmish on this map/build was recorded; online games, long combat, all maps/factions and version compatibility remain unverified. Native radar currently displays its limited-radar state. A development demoscrub experiment crashed the game; seeking is not exposed. Temporary material swaps, native helper construction, forced LOD experiments and developer file execution were only diagnostic experiments and are not shipped.

No game binaries, encryption keys, replay contents or account logs are included in the repository. Runtime evidence remains local under dist/validation and the launcher diagnostics folder.

## Final controls and pause validation

Final clean session 389b9d6f44a94bc0ad292482fa9ee839 used production source SHA256 `1CA601C89913C0B0B621125583D5808431A1122EDC29A13F511AD8356BC2412A`. The F6 key switched from the recorded GDF base to the recorded Dynasty base, including its machine shop and power plant. Camera movement requires aligning both the possessed pawn and the separate engine spectator pawn. I moved the scene using the native camera component. F8 paused delivery at replay time 48.63148; the pauser belonged to the new local spectator and was preserved by the bridge. No development harness or material substitution was present.


## v0.3.1 spectator interaction validation

Native testing on the same installed build identified a camera mismatch: the engine-created SpectatorPawn was the view target while Tempest's minimap and selection operate on pc.Pawn (TedSpectator_BP). Selecting the game-owned pawn as view target restores native minimap camera navigation. Cursor, click and mouse-over flags plus WidgetBlueprintLibrary.SetInputMode_GameAndUIEx restore pointer interaction without hiding it during capture.

Only transient live TedThirdPartySpectatorHud widgets are repositioned. Box_StatsOverview has a CanvasPanelSlot; anchors/alignment are top-left and position is (16,90) in widget coordinates. I invokes SingularStatShow_ButtonClick and no longer pans the camera. Native screenshots confirmed both hiding and showing the panel.

The live TedMinimapWidget uses Enabled and Eligible enum flags (indexes 0 and 1), bIgnoreMinimapRequirements and fog drawing disabled. Screenshots showed the full bright map and camera frustum. Clicking the enemy-base region moved to the Dynasty base and native clicking selected the construction yard with its details panel.

C obtains GetSelectedPawns entries by unwrapping UE4SS RemoteUnrealParam:get(). In clean production session 9e1461a9fca243d39863607e5f90d294 (no developer harness), C activated tracking of a selected GDF construction yard and a second C reported Camera tracking off, without viewer errors. The 33 ms replay-only camera loop updates the target position and cancels on a fresh left click, manual edge pan or target death. Zoom is preserved with the native camera component's skip-reset option. An edge input changed camera Y by 200 while preserving camera Z; the horizontal direction was then corrected for the game's yaw-180 view.

Final source SHA256: 17EA27DC00C494BE550B86A91366E45CBA0B5ACE471178DD41A5657499653B4A. Mock host checks now cover 28 cases including replay-only input, selected-target updates, click/death cancellation, I toggle, right-edge direction and out-of-viewport rejection. These are regression checks, not native compatibility evidence. The available replay contains buildings but no moving units, so tracking a moving combat unit in real playback remains unverified. Full radar is now enabled; earlier limited-radar notes above describe v0.3.0 only.

Final clean session b5b24ecc4dae4e5c95b4c40611cbde31 used that exact installed source hash without a harness. A right-edge input moved the scene left (camera right), confirming the corrected horizontal direction. Native UI remained at top left and the full minimap remained active; no bridge/viewer errors were logged in this session.


## v0.3.2 cursor and teardown investigation

The supplied crash XML/YAML and minidump identify an access violation in UE4SS, with the active scene reported as MainMenu after replay viewing. The minidump exception address maps to UE4SS+0xc67cc8; shipping symbols are unavailable, so this does not identify the exact Lua/native call. A first LoadMap-only guard was insufficient in a development run and a second crash occurred. Lifecycle hardening also handles replay-controller EndPlay, level transition/quit, playback termination and already-queued callbacks. Subsequent game-object access is disabled; the InitGameState hook also stays idle after the viewer stops. Individual unit destruction does not stop playback.

Camera interpolation no longer restarts on every mouse-pan/follow tick. Repeated SetViewTargetWithBlend and minimap state initialization were removed from the one-second refresh. The game-owned pawn location drives ordinary camera movement while the initial/native minimap camera behavior remains available. A native pointer sample after scrolling remained at viewport position (2683,946) across repeated samples rather than resetting to center (1920,1080). Camera movement remained functional. This is observed behavior after combined changes, not proof of a single native cursor-reset call.

Clean session fa9ef0b02d14443d89e58aa3fc818ad9 (no developer harness) returned to the native main menu after replay viewing. The bridge recorded viewer_stopped before map teardown, the menu remained responsive, and normal exit completed without a new crash report. The initial LoadMap-only development failure is retained in local crash storage and was not used as successful validation. Regression tests now cover 31 cases, including transition suspension, terminal EndPlay, stale-context avoidance and callbacks after teardown. Native testing is limited to the same short offline replay/build.


An additional clean run d295d120ae4644d1889907e03b70c483 crashed during playback around 44 seconds, before any terminal lifecycle event. This disproved teardown as a complete explanation. The UE4SS log also contained a prior registry reference error (Ref was not function). The bridge previously generated a new ExecuteInGameThread coroutine from LoopAsync on every 33 ms input tick, concurrently with its slower async loop. The pinned runtime source explicitly warns of shared Lua state/registry races in this path. The bridge now uses LoopInGameThreadWithDelay and CancelDelayedAction, both confirmed present in the installed DLL. Its recurring Lua callbacks execute directly on the game thread and reuse timer registrations. No async input/status loops or per-frame dispatch allocations remain. This addresses a separate scheduler risk; without private symbols the exact faulting Lua operation is still not proven.


Final production session e6d2cca88c1e4ed1add872082e6dbab4 used source SHA256 0FD86F81DB9A272D1A7E012C98306C9ED875315F791E252443B7CC6E881F4812, matching the installed Lua exactly, with no development harness. Replay time reached the native end at 52.109 seconds. The viewer remained active for approximately 148 seconds, including mouse-edge movement, and then returned to the main menu. viewer_stopped was recorded before teardown. No new crash directory or registry-reference error was produced in this run. This is a successful native regression run; it does not guarantee that every crash in all replays/builds is eliminated. The final mocked suite has 32 tests, including direct reuse of the game-thread timer without per-frame dispatch.


## v0.3.3 online recording diagnosis (not native-verified)

A user-reported online skirmish entered Overgrown Oasis at 14:06:45 and returned to the menu at 14:21:00 in record-mode session 489703cda18044249e0dca1804f19678. No demorec command, recording-driver event or new replay file was present. The old bridge silently returned when its Tempest GameState/controller-start preconditions were not satisfied, and did not log which precondition failed. Therefore the evidence proves a skipped request, not an engine recording rejection or a specifically proven HasMatchStarted fault.

The update adds a replicated MatchState InProgress start path, respects explicit lobby/terminal states, persists recording-state.txt and reports waiting/unrecorded exits. Mock tests cover an unready controller with InProgress, explicit lobby/terminal state and a match left unrecorded. Actual online recording and playback remain unverified; the next fresh online record-mode launch is needed to collect native evidence. No online match was initiated or user game interrupted for this change.
