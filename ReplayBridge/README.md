# Tempest Replay Bridge (experimental)

UE4SS Lua bridge for installed Tempest Rising UE 5.4.3. This is an integration prototype, not a verified replay implementation. It requires a clean game restart with UE4SS loaded. Do not infer replay success from a console-command dispatch or from the presence of engine symbols.

The launcher creates a short-lived request before starting Steam. Without a fresh request this mod stays idle. A recording request waits for a Tempest game state and `HasMatchStarted()`, dispatches `demorec` once per world, and writes an acknowledgement. File growth is verified separately by the launcher. Playback requests configure the game's existing spectator controller class and attempt to activate its spectator HUD; these steps require in-game validation.

`probe` mode only reports reflected classes and members, without recording or modifying spectator properties. Runtime status and diagnostics stay under `%LOCALAPPDATA%\TempestReplayLauncher\bridge`. Never commit local runtime dumps or game assets.
