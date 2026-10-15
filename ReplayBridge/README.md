# Tempest Replay Bridge (experimental)

UE4SS Lua integration for Tempest Rising UE 5.4.3. A clean restart with a fresh launcher request is required. Without a request, the bridge stays idle. The probe is read-only. The launcher updates installed Lua on the next clean bridge launch.

Recording selects a controller attached to an Engine.LocalPlayer, waits for HasMatchStarted, registers the missing DemoNetDriver in the current engine and requests demorec once per match world. Driver activation and actual file creation are separate checks. The AI controller accepted by UEHelpers.GetPlayerController was the confirmed cause of earlier silent recording failures.

Playback configures the game's TedSpectatorController asset, restores the recorded game-mode HUD and spectator state, and focuses its native camera component on a recorded construction yard. Replay-only visibility initialization restores terrain, live actors, structure construction visuals and skeletal animation updates. These operations require both play mode and ReplaySubsystem.IsPlaying; they do not modify the visibility of a live recording session. Map design placeholders, ghosts, dead and contained pawns are excluded.

A native replay of an offline skirmish on the installed Steam build 25752338 was recorded, finalized and played in a new process on 2026-10-16. Native spectator UI, both players' statistics and construction visuals were observed. Online games, long battles, all maps/factions and seeking are not validated. See docs/NATIVE-VALIDATION.md in the source checkout. Never infer full replay correctness from command dispatch or mocked tests alone.

Runtime diagnostics remain under %LOCALAPPDATA%\TempestReplayLauncher\bridge. Do not commit dumps, account logs, game assets or replay contents. Development harnesses are not part of this bridge.

Viewer controls: mouse edge panning, native minimap click navigation, I to toggle the top-left statistics panel, C to toggle following the selected pawn, F6 to switch player bases, F8 to pause. Manual camera movement or another click cancels following. The game-owned TedSpectator pawn is the view target so native selection and minimap navigation use the same camera. Full minimap eligibility is enabled only during replay playback.
