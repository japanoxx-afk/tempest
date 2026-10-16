# Tempest Replay Bridge (experimental)

UE4SS Lua integration for Tempest Rising UE 5.4.3. A clean restart with a fresh launcher request is required. Without a request, the bridge stays idle. The probe is read-only. The launcher updates installed Lua on the next clean bridge launch.

Recording selects a controller attached to an Engine.LocalPlayer, waits for HasMatchStarted, registers the missing DemoNetDriver in the current engine and requests demorec once per match world. Driver activation and actual file creation are separate checks. The AI controller accepted by UEHelpers.GetPlayerController was the confirmed cause of earlier silent recording failures.

Playback configures the game's TedSpectatorController asset, restores the recorded game-mode HUD and spectator state, and focuses its native camera component on a recorded construction yard. Replay-only visibility initialization restores terrain, live actors, structure construction visuals and skeletal animation updates. These operations require both play mode and ReplaySubsystem.IsPlaying; they do not modify the visibility of a live recording session. Map design placeholders, ghosts, dead and contained pawns are excluded.

A native replay of an offline skirmish on the installed Steam build 25752338 was recorded, finalized and played in a new process on 2026-10-16. Native spectator UI, both players' statistics and construction visuals were observed. Online games, long battles, all maps/factions and seeking are not validated. See docs/NATIVE-VALIDATION.md in the source checkout. Never infer full replay correctness from command dispatch or mocked tests alone.

Runtime diagnostics remain under %LOCALAPPDATA%\TempestReplayLauncher\bridge. Do not commit dumps, account logs, game assets or replay contents. Development harnesses are not part of this bridge.

Viewer controls: mouse edge panning, native minimap click navigation, I to toggle the top-left statistics panel, C to toggle following the selected pawn, F6 to switch player bases, F8 to pause. Manual camera movement or another click cancels following. The game-owned TedSpectator pawn is the view target so native selection and minimap navigation use the same camera. Full minimap eligibility is enabled only during replay playback.


v0.3.5: LockAlways confines the mouse while the replay window has focus. F7 cycles 1/2/4/0.5 playback rates through WorldSettings.DemoPlayTimeDilation; launcher requests are session-scoped and allow only those rates. Offline authoritative recording additionally enables ReplicateMovement on non-structure TedPawn actors, initially and after spawn. This build otherwise uses custom unit movement replication which was missing from the earlier demo. Networked worlds and non-authoritative clients are excluded. Old files without movement cannot be repaired by this change.


The movement companion (v0.3.6) samples locally received TedPawn transforms and alive presence at 100 ms intervals while the native ReplaySubsystem is recording. This also runs in online client/listen-server worlds without changing their replication flags, calling RPCs, or moving live units. The optional `<basename>.movement` file is saved beside `<basename>.replay`. Playback alone matches the replicated ECS EntityHandle prefix plus unit class and owner and interpolates transforms against native replay time, including pause/speed changes. A read-only UE4SS alias resolves EntityHandle by its reflected property, rather than a fixed process address. Duplicate identities fail closed; malformed companions disable only movement supplementation. Native replay remains available. Units/data that never reach the local client are not reconstructed.

Keep both files when moving or sharing a recording. Launcher import copies both. Legacy files without a companion use native replay data. The codec parses data records only, streams two adjacent frames, and never executes file contents. Runtime movement-state.txt reports the current session, file, frames and unit count. Native bridge/module copying and legacy updater embedded payload include Movement.lua. See the latest native validation section for tested scope.


v0.3.8 supersedes the v0.3.5 replication changes and v0.3.6 playback identity assumption: recording never changes actor replication or game speed. Handles identify tracks only within a recording; playback binds unique same-class/same-owner initial poses and retains the actor binding. Ambiguous spawns remain native. U calls the minimap, player-list and statistics panels' own hide/show button handlers during actual playback only.
