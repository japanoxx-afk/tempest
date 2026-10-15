# Installed-game investigation — 2026-10-16 (Korea)

## Evidence collected

- Steam app 1486920; installed build ID 25752338.
- Executable identifies engine as Unreal Engine 5.4.3 and build `2.0.1.60808.5.4.3`.
- `Tempest/Mods` is empty; installed plugin directories are DLSS, Streamline and XeSS. No UE4SS proxy/runtime or loose `.uplugin` SDK was found.
- `MapEditorProject` is absent. The official editor is an optional DLC, not installed here.
- No files were found in the user game's `Saved/Logs` directory at inspection time. No local replay recording was available to validate.
- Read-only executable string inspection found `DemoNetDriver`, `DEMOREC`, `DEMOPLAY`, `LocalFileNetworkReplayStreaming`, `ReplaySpectatorPlayerControllerClass`, and Tempest-specific spectator symbols.
- Tempest names include `TedGameState`, `TedGameModeBase`, `TedHUD`, `TedPlayerController_Spectator`, `ActivateMatchSpectatorUI`, `UTedThirdPartySpectatorHud` and `/Game/Tempest/Blueprints/Core/TedSpectatorController_BP`.

Names in an executable are evidence of compiled components, not proof that functions are exposed, callable, or sufficient to reproduce gameplay. No encrypted game assets or encryption keys were read or redistributed.

## Official interfaces

- [Official map editor documentation](https://support.saber.games/hc/en/tempest-rising/articles/map-editor-guides-26) links a 190-page editor API reference. Searching that reference found no `Replay` API; it does describe game state, game mode and spectator-related functions. This does not prove that the runtime lacks an internal replay API.
- [Developer's editor installation instructions](https://steamcommunity.com/app/1486920/discussions/0/573794767997100331/) describe optional DLC and `MapEditorProject/Docs`.
- [Official spectator patch notes](https://support.saber.games/hc/en/tempest-rising/articles/september-9-2025-patch-notes-13) document live custom-match spectator HUD, statistics, camera following and fog-of-war controls. They do not establish replay support.
- [Unreal replay system](https://dev.epicgames.com/documentation/en-us/unreal-engine/using-the-replay-system-in-unreal-engine) records replicated state. Merely issuing `demorec` does not establish that Tempest's gameplay state is replicated in the required form.
- [Unreal replay drivers](https://dev.epicgames.com/documentation/en-us/unreal-engine/demonetdriver-and-streamers-in-unreal-engine) describe separate replay spectator controllers and recording relevance. A client recording cannot recover information the server never sends to that client.

## Experimental path prepared

Use a pinned UE4SS experimental build supporting UE5.4, enable only this project's Lua bridge, and perform a fresh-launch probe. Loader archive SHA256 is pinned to `e615ee7a2c24344ea5aeef85183d6cfd550f4f6352225976679f9fefffd0b9a5` for `UE4SS_v3.0.1-1176-g1ba38db4.zip`. The moving upstream experimental release may remove that asset; a different build must be reviewed and pinned again rather than bypassing the check.

The bridge consumes a short-lived launcher request. Probe mode writes reflected class/member signatures without gameplay commands. Record mode waits for a started Tempest game state and requests recording once per world. Playback attempts to use the existing Tempest spectator controller and a zero-argument HUD activation function only if reflected signatures match. Unsupported calls fail with a diagnostic state.

## Validation gates still required

1. Game exits cleanly; install the loader without overwriting existing loaders.
2. Fresh diagnostic launch: UE4SS loads without crashes, bridge acknowledges the current session, and reflection data is generated.
3. Offline skirmish: start and end a match, confirm a real `.replay` file is written and grows. Check finalization after return to menu and process exit.
4. Restart into replay: verify actual recorded unit motion, economy, both factions, match duration and world state rather than just map loading.
5. Verify spectator camera, HUD, player selection, fog-of-war view, and absence of live match side effects. Adapt actual reflected signatures as needed.
6. Only after local success, evaluate custom multiplayer compatibility and recorded information completeness. Ranked multiplayer compatibility is unknown.

At the end of the development pass the game was still running, so installation and these live tests were not performed. This is a prototype; automatic recording and spectator playback are **not verified**.
