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
