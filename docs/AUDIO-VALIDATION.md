# Replay audio investigation — v0.3.19

Reference: `Tempest_20261020_000550_c518bcd9_1.replay` and its `.movement`, game 2.0.1+60808. Original files are read-only. The original live match's audio/video was not supplied, so this is an instrumented replay investigation, not a claimed listening comparison with that past match.

## Evidence and scope

| Category | Evidence | Change / limitation |
| --- | --- | --- |
| Firing | Native projectile-fired events are available. A fired event alone does not identify the actual firing sound. | Native firing playback is retained; no guessed replacement or attack call. Every weapon's audible firing sound remains unverified. |
| Flight | Native projectile actors and their effects survive in the demo. | Native audio/effects are retained. Every flight/laser loop's audibility is unverified. |
| Impact | Blueprint projectile-hit events execute, while sampled GameplayStatics audio calls do not show corresponding impact calls. Loaded HitBurst/HitActor defaults provide 149 valid effect-sound tag mappings. | Observe actual hits and schedule their mapped sound only. Missing tag/asset is counted instead of invented. Native C++ audio can bypass reflection hooks, so hook absence alone cannot prove complete silence. |
| Explosion | Grenadier-impact tags resolve to a native explosion MetaSound; bullet/laser tags resolve to metal/flesh cues. | These mapped projectile impacts use the same presentation-only route. Other explosion types are not assumed equivalent. |
| Unit death | Death visuals and state exist, but a death flag does not identify a voice, variation, or sound time. | Existing native death audio is retained. No death/damage function is called to synthesize sound. Complete unit-death audio recovery is unverified. |
| Building destruction | Native calls using small/medium generic structure-explosion MetaSounds were observed. | Retained, rather than adding a second destruction sound. Every building's audible destruction remains unverified. |

The first location-based sound factory returned invalid components even for a loaded metal cue at the reported listener position. The same cue could create/play an audio component. The replay-only fallback therefore creates an **idle** component, enables spatialization, disables UI sound, retains the sound asset's attenuation, places it at the impact, and only then plays it. This is not global 2D playback. The exact engine-internal reason for the location factory's rejection is not established.

The scheduler waits 0.06 replay seconds for an observed native duplicate, matches asset/time/location one-to-one, drops events older than one replay second, limits pending/active components, pauses owned components during pause and stops them at exit/EOF. Only this module's components are paused/stopped. Pitch, global time dilation and gameplay audio settings are not changed by this module. Native calls that bypass reflected observers remain a duplicate-detection limitation.

No attack, damage, projectile-hit, or gameplay-cue execution function is invoked to make audio. The new observers/module run only in a playing replay. Recording/live-game branches are unchanged. This does not claim an exhaustive new multiplayer interoperability test.

## Existing-file limits

This pair has no dedicated event-by-event audio sidecar. Projectile impacts that still execute with a supported cue can be reconstructed without rewriting the files. Events that were never replicated, cues without a sound asset, unknown sound variations, or missing death/voice information cannot be recovered reliably. Transform tracks cannot supply those facts. This release does not claim those sounds have been restored or silently fabricate them; explicit future capture of such event identities would require a separately validated recording format.

## Other presentation fixes

Actual `GetPawnContainerOwner` values identify bunker/fortification/transport occupants. They are excluded from companion positioning and minimap reveal, and their meshes are hidden until unloading. Stale production-container flags remain eligible for the existing movement correction. Neutral replacement meshes receive the native primary/secondary player material parameters; owner 0/1 and neutral 8 are treated separately, without changing ownership.

Runtime checks and known unverified items are also recorded in `NATIVE-VALIDATION.md`. Automated scheduling tests are not listening tests.
