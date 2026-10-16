# Movement companion v1/v2

The companion is optional, local UTF-8/ASCII tab-separated data. It is not an Unreal replay and cannot be played independently. Store it beside the same-named `.replay` file. The generated replay basename binds the pair. Do not rename one file independently.

- Header: `TEMPEST_MOVEMENT<TAB>2<TAB>basename` for new recordings; readers also accept v1.
- `F<TAB>nativeReplaySeconds` begins a full snapshot. Times increase monotonically.
- `U<TAB>localID<TAB>unitClass<TAB>ownerID<TAB>entityKey` defines an identity once.
- `P<TAB>localID<TAB>X<TAB>Y<TAB>Z<TAB>Pitch<TAB>Yaw<TAB>Roll` records a received transform.
- Optional v2 `B<TAB>localID<TAB>state` follows a P record: 1 constructing, 2 completed, 3 explicitly dead. States are discrete, never interpolated; each sample permits one state. Construction can precede native IsAlive. Death requires an observed native PawnDeath flag, never absence.
- `E` finalizes the file. Completed, flushed frames remain usable if the process stopped without a trailer.

The native bridge reads the first IntProperty-sized word at NubECS.EcsActorComponent.EntityHandle through a read-only custom property alias resolved by reflection. This build exposes the handle as a native serialized struct with no reflected fields. The prefix is combined with class and owner to identify tracks within this recording; duplicate simultaneous identities are rejected. Native testing in v0.3.8 demonstrated that these handles are NOT stable between recording and playback. Playback ignores their numeric equality and binds tracks to a unique actor of the same class and owner within 200 Unreal units of its first recorded pose. Equal/competing candidates are rejected; established bindings persist instead of being recomputed from moving positions. Identical co-located spawns may remain unmatched.

The reader retains two adjacent full snapshots, interpolates positions and shortest rotation arcs, does not create actors and only displays actors recorded as alive and outside a container, and stops applying transforms after recorded data ends. A native ReplaySubsystem.IsPlaying gate is required before any actor mutation. Recording reads only already-received coordinates; it does not request extra server state or alter online replication. v0.3.8 removes standalone SetReplicateMovement/ForceNetUpdate changes too; neither online nor offline recording changes actor movement or live game speed.

Limits: 20,000 samples per snapshot, 1,000,000 unique IDs, finite coordinates bounded to absolute values below 1e9, tokens up to 160 characters and records up to 1024 characters. Invalid data disables supplementation with movement_error rather than executing or interpreting it as code. Seeking backward is unsupported, consistent with the launcher. The sidecar grows with match length and local unit count.

The pure data codec and mocked online-client integration tests do not by themselves establish successful online gameplay recording. Consult NATIVE-VALIDATION.md for native test evidence and limitations.

Client demos in the tested build restore zero health/max-health and IsAlive=false for actors that were actually alive. Snapshot presence is therefore the source of truth for supplemented actor visibility. Absence hides previously supplemented actors and suppresses the generic visibility initializer. This does not fabricate health or repair missing gameplay attributes; health bars, selection and other ECS-dependent UI may remain incomplete. Building presence is captured as well as mobile units.

v0.3.9 additionally derives presentation velocity from adjacent position samples, using replay-time seconds. This does not change the file format or writer. A last/unpaired sample has zero velocity; discontinuities exceeding 10,000 Unreal units per second are treated as teleports for animation only. Position playback remains unchanged. Minimap supplementation uses the same matched/present targets and native map projection, without fabricating health or recording new network data.
