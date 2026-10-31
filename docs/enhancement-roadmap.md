# IGNITE enhancement and change assessment

This document looks at the codebase as a product platform: where it is easy to extend, where the
architecture will resist change, and which additions would give the most value. It intentionally
focuses on **new capability and structural improvement**, not bug fixes. Defects and security issues
are in [code-review.md](code-review.md); the code map is in [architecture-guide.md](architecture-guide.md).

The central conclusion: IGNITE already has the hard parts — a complete sequencer model, playback
clock, MIDI/CV hardware integration, a touchscreen UI, and a working build. The next gains are less
about adding more one-off code and more about making the existing seams predictable:

1. make the project format versioned and migratable;
2. make parameters self-describing and less manual;
3. add a test/simulator harness before expanding behaviour;
4. deepen the sequencer and mixer through the existing `SequenceManager` and `Track` seams;
5. unify or deliberately choose between the in-app TSF path and the separate `AudIO` graph.

## 1. Product shape and constraints

Current shape:

- 64-track sequencer with Song → Scene → Track → Pattern → Bar → Step → Note/Aux hierarchy.
- 96 PPQN timing, 16 steps per bar in the default pattern, timebases from 1 to 32T.
- Scene-based playback, fill patterns, transpose/FTS, solo/skip/mute, sculpt and step recording.
- Internal TSF SoundFont synth plus a fixed per-track effect chain.
- 5-pin MIDI, USB MIDI, USB host MIDI, MIDI clock, MMC, remote control.
- 8 CV and 8 gate outputs with calibration.
- Front-panel MCU, touchscreen UI, Wi-Fi/PC connection, backup/update flows.
- Persistence through per-object XML files under `/data/ignite`.

Constraints that influence feature design:

- Fixed 1024×600 touchscreen layout and asset-driven theme.
- 8-bit `moduleId_t` and `paramId_t`; roughly 255 parameters per module.
- Heavy use of global/singleton UI state and manual `updateDataFromEngine()` refreshes.
- Audio path is a 20 ms mono render block, duplicated to stereo, with a fixed effects chain.
- Project format has `FILE_VERSION = 0` and no migration framework.
- No automated tests or public CI workflow.
- Large unity translation units make compilation and tooling slower.
- The separate `AudIO` library has a much richer graph/bus/DAW design than the app currently uses.

## 2. Priority matrix

Rating is relative to this codebase.

| Initiative | User value | Effort | Risk | Notes |
|---|---|---|---|---|
| Versioned project format + migration | High | M | Medium | Unlocks every future persistent feature |
| Parameter metadata/registry | High | M–L | Medium | Reduces boilerplate for all new parameters |
| Test harness + simulator | High | M | Low | Needed to make feature work safe |
| Step probability/conditions/ratchets | High | M | Medium | Fits `SequenceManager` and step model |
| Per-step automation/parameter locks | High | L | High | New model + playback + UI + persistence |
| Arrangement/timeline enhancements | High | L | High | Song/scene model expansion |
| MIDI import/export (SMF) | High | M | Low–Medium | Uses existing event model; strong user value |
| Per-track insert slots / master bus | High | L | High | Requires audio graph work |
| MIDI routing matrix + MIDI learn | High | M | Medium | Build on current port/channel maps |
| CV modulation matrix / LFOs | Medium–High | M | Medium | Existing CV/ADSR infrastructure helps |
| Sample playback / multi-sample instruments | High | L | High | Needs new audio object and storage |
| Audio recording/export/stems | High | L | High | JUCE/AudIO recorder pieces exist |
| Responsive desktop/theme editor | Medium | M | Low | Fixed layout/theme is a current constraint |
| Companion app/web editor | High | L | High | Natural for a small screen; needs API design |
| Split engine into a library / CLI | Medium | M | Medium | Enables simulator, tests, tools |
| Reduce unity builds and giant files | Medium | M | Low | Developer velocity and tooling |
| Accessibility/localization | Medium | M | Low | Asset/text layout work |

## 3. Foundation work that unlocks features

### 3.1 Versioned project format and migrations

**Why:** every meaningful feature adds model state. The current XML format has a single `FILE_VERSION`
and no migration path. Without this, new fields risk breaking old songs, patterns, and settings.

**What to do:**

- define a schema version per object type or a single project manifest version;
- write a migration chain (`v0 -> v1 -> v2`) that fills defaults and transforms old fields;
- add an explicit “unknown field” policy and forward-compatibility behaviour;
- add a project manifest describing songs, scenes, patterns, instruments, and settings;
- make saves atomic (write temp file, fsync, rename) and keep a last-known-good backup;
- add round-trip and migration test fixtures.

**Where:** `EngineDataStruct.h`, `EngineFileHandler`, `FILE_VERSION`, `EngineFileHandler` backup/restore.

### 3.2 Parameter registry and metadata

**Why:** each manager manually registers parameters, switches on IDs in `getParamList`, and duplicates
undo/save logic. Adding 50 new parameters this way becomes expensive and error-prone.

**What to do:**

- introduce a parameter descriptor: id, name, display name, type, min/max/default, unit, group,
  page, visibility, persistence, undo policy, and feature flag;
- make `AddParameter` take or derive the descriptor;
- generate or table-drive `getParamList` instead of hand-written switches;
- add a typed command/event layer for operations that are not simple values;
- consider widening `paramId_t`/`moduleId_t` or namespacing IDs before the 8-bit ceiling becomes a
  hard limit;
- expose parameter metadata to the UI and to future API/companion clients.

**Where:** `Common/Modules/parameter.h`, `parameterbase.h`, `module.h`, `ModelParams.h`, every manager.

### 3.3 Test harness and simulator

**Why:** feature work in a sequencer needs deterministic timing and file/state checks. The current
repo has no automated tests; the built-in touch/hardware screens are manual only.

**What to do:**

- extract the engine into a library target that can run without a window;
- add a headless simulator/harness that can create a song, pattern, scene, track, and MIDI events;
- add golden-file tests for project save/load and migrations;
- add protocol tests for `PktMgr`, sysex, MCU messages, and MIDI parsing;
- add a “fast-forward clock” or deterministic pulse driver for playback tests;
- add a CI smoke test under Xvfb with a test SoundFont;
- keep the existing touch/hardware test screens as manual device checks.

**Where:** CMake targets, `SongManager`, `SequenceManager`, `PatternManager`, `EngineFileHandler`,
`ComProtocol`, `docs/testing.md`.

### 3.4 Split the engine from the GUI application

**Why:** the engine model currently lives inside JUCE modules and is compiled together with UI code.
A separate core library would make a CLI, simulator, migration tool, and test harness much easier.

**Suggested split:**

```text
ignite_core        model, managers, sequence, persistence, MIDI/CV abstractions
ignite_audio       Track/TSF/AudIO integration, audio graph
ignite_hardware    front panel/USB/Wi-Fi adapters
ignite_ui          JUCE screens/widgets
ignite_app         main window and composition root
```

This does not require a rewrite; it can be done incrementally by moving interfaces and removing
UI/hardware globals from the core.

### 3.5 Reduce unity builds and giant files

**Why:** module `.cpp` files include other `.cpp` files. This makes builds large, prevents parallel
compilation, and lets macros/namespaces leak across unrelated code. It also makes navigation and
static analysis harder.

**What to do:**

- move source lists into CMake and compile files separately;
- split `SongManager.cpp`, `Track.cpp`, `mt_ignite_pattern.cpp`, and settings managers by concern;
- keep the module headers but stop concatenating implementations;
- add `clang-format`/`clang-tidy`/include-what-you-use gradually.

**Where:** `Common.cpp`, `Firmware.cpp`, `common_defs.cpp`, `apps/ignite/CMakeLists.txt`.

### 3.6 UI state model

**Why:** UI state is spread across singletons and global arrays (`gSongs`, `gInstruments`, pattern
arrays), with manual refresh calls. This is workable for the current screens but scales poorly when
adding cross-screen features.

**What to do:**

- introduce a lightweight view-model/state layer per major area (Song, Scene, Track, Pattern,
  Instrument, Settings);
- keep the engine as the source of truth and treat UI arrays as caches with explicit invalidation;
- replace “refresh everything” calls with targeted change notifications where practical;
- add a screen-registration/navigation table so new screens do not require edits in several
  visibility switches.

**Where:** `AppHome`, `AppMainmode`, `AppMenu`, `mt_ignite_*`, `ignite_common_defs.h`.

## 4. Sequencer and music features

These are the highest-value product additions and mostly fit the existing model.

### 4.1 Step probability, conditions, ratchets, flams

Add per-step or per-note fields such as:

- probability (0–100%);
- trigger condition (always, every N bars, fill only, previous step, random);
- ratchet/retrigger count and timing;
- flam/offset;
- velocity/length randomization ranges.

**Where:** `StepData`/`NodeData`, `SequenceManager` event generation, `Step`/`PatternManager`, step
and grid UI, `EngineFileHandler`.

**Why it fits:** `SequenceManager` already converts the step model into per-tick event maps, so a
conditional trigger can be decided at sequence-build or playback time.

### 4.2 Per-step automation and parameter locks

Add automation events alongside notes, for example filter cutoff, pan, send, or MIDI CC. Decide
between:

- **parameter locks** (value attached to a step, applied when the step fires);
- **automation lanes** (interpolated values over bars/patterns).

**Where:** `StepData`/`Aux`, `SequenceManager`, `Track` effect/MIDI application, UI lanes, persistence.

### 4.3 Arrangement and scene workflow

Enhancements:

- visual song arrangement/timeline instead of only scene lists;
- scene follow actions, chaining, loop counts, jump targets;
- per-scene tempo/meter automation;
- song markers and sections;
- copy/paste of scene ranges, scene templates.

**Where:** `SongData`/`SceneData`, `SongManager`, `CSong`/`Scene`, scene/song UI, file format.

### 4.4 MIDI import/export and interoperability

Add:

- Standard MIDI File import into patterns/scenes;
- SMF export of a song, scene, or pattern;
- pattern clipboard as text/JSON for sharing;
- compatibility with common DAWs (tempo, track names, program changes, CC).

**Where:** new SMF import/export service, `SequenceManager` event maps, `PatternManager`,
`SongManager`, file import/export UI. JUCE's `MidiFile` support lives in `juce_audio_basics`, which is
already linked; audio-file import/export may additionally need `juce_audio_formats`.

### 4.5 Scales, chords, generators

The code already has FTS scales, custom scales, transpose, and a “sculpt” concept. Extend with:

- chord generators and chord memory;
- arpeggiator with pattern/rate/gate;
- Euclidean rhythm generator;
- generative variation using seed and mutate controls;
- scale-aware random/ratchet/probability.

**Where:** `SequenceManager`, `Track::sculptUpdate`, pattern/step UI, scale/FTS data.

### 4.6 Polyrhythm and meter

Current patterns have a timebase and bars have step counts. Add:

- per-track clock dividers or pattern lengths;
- per-scene/per-bar time signatures;
- polymetric patterns (different bar lengths per track);
- richer shuffle/swing per track or per scene.

This requires careful work in `SongManager::pulse`, `Track` pulse/step counting, and `SequenceManager`.

## 5. Audio and sound design

### 5.1 Per-track insert slots and a real mixer

Current `Track` has a fixed chain (reverb, chorus, EQ low/high, filter, gain) and the master sums
tracks with a master volume. A richer mixer would add:

- ordered insert slots per track;
- send/return buses;
- master bus with EQ/compressor/limiter/meter;
- per-track pan, gain, mute/solo with metering;
- effect presets and bypass;
- sidechain routing.

**Where:** `Track` effect chain, `SongManager::renderTracksAndMix`, new mixer UI, persistence.
Alternatively, use `AudIO`’s `Design`/`Chain`/`Bus`/`DawEngine` abstractions.

### 5.2 Use or integrate `AudIO`

`AudIO` already provides a patchable graph, buses/chains, insert effects, metering, recorder/playback,
and a DAW layer. Options:

1. **Adopt it as the audio backend** behind `SongManager`/`Track`.
2. **Extract selected abstractions** (bus, chain, insert, meter) into the app.
3. **Keep it separate** and use it only for an eventual companion/desktop mixer.

The first option is strategically attractive but high risk because the app’s current TSF path is
tightly coupled to `Track`. A safer path is to introduce an `IAudioTrack`/`IAudioGraph` interface
and implement a second backend behind it.

### 5.3 Sample playback and instrument management

Add:

- one-shot and looped sample tracks;
- multi-sample instruments with velocity/key zones;
- sample import and naming;
- SoundFont preset browser with categories/favorites;
- per-track preset recall and auditioning.

**Where:** new audio object under `AudIO/Objects` or `Track`, file storage under `/data/ignite`,
instrument UI, settings.

### 5.4 Recording and export

Add:

- audio recording of the master or individual tracks;
- export mixdown/stems to WAV;
- metronome/click track;
- loop recording/overdub;
- render with tail and normalize options.

`AudIO` has recorder and playback pieces; JUCE audio formats are available if linked. This is a
strong candidate for a standalone “Export” screen.

## 6. MIDI, CV, and hardware I/O

### 6.1 MIDI routing matrix and learn

Current routing is per-instrument port/channel and `playSceneTrackPortMap`, with MMC/remote-control
handling in `SongManager`. Add:

- a visual routing matrix: source port/channel → destination track/instrument;
- MIDI learn for knobs, buttons, and transport;
- per-track MIDI filters/transforms (transpose, scale, velocity, channel);
- MPE/poly-aftertouch support;
- MIDI monitor and event log for debugging.

**Where:** `SongManager` MIDI path, `Instrument`, `Track`, MIDI settings UI, routing UI.

### 6.2 CV/gate modulation

The `Track` code already has CV generation, ADSR envelopes, calibration, and per-track CV data. Add:

- LFOs and modulation matrix;
- per-track CV source/destination routing;
- gate modes (trigger, gate, clock division);
- calibration profiles per output;
- CV scope/monitor.

**Where:** `Track` CV path, `cvControl`, `SettingsCvioCnfg`, CV UI.

### 6.3 Hardware abstraction and simulator

Add a proper hardware abstraction layer so the engine can run against:

- real MCU/UART/CV hardware;
- a desktop simulator;
- a record/replay transport for tests.

This would make the existing `FP_TEST_KEYBRD`/`ENABLE_HARDWARE_TEST` ideas more systematic and
reduce the need for `/sys/class/gpio` side effects during development.

## 7. UI/UX enhancements

- **Responsive desktop mode:** the current 1024×600 fixed layout works on the device but is awkward
  on desktop. Add a scaled window and a layout-mode abstraction.
- **Theme editor:** `common_Theme` has a large palette; expose theme presets and a user theme file.
- **Search/filter/bulk edit:** pattern/instrument/song lists will grow; add search, tags, multi-select,
  range edit, and duplicate detection.
- **Undo history:** current undo is parameter-list based. Add a visible history with labels and
  grouping for pattern/step operations.
- **Contextual help:** `common_helpInfoPopup` exists; expand it with per-screen help and shortcuts.
- **Accessibility/localization:** font scaling, high-contrast theme, screen-reader labels, and string
  externalization.
- **Keyboard/mouse workflow:** the desktop app should support keyboard shortcuts and mouse editing
  without requiring the touchscreen metaphor everywhere.

## 8. Connectivity and companion experience

The device has Wi-Fi and a PC connection. Natural additions:

- a versioned local API (HTTP/WebSocket) for project upload/download and transport control;
- a companion editor for pattern/step editing and file management;
- OSC or Ableton Link for integration with other tools;
- remote control from a tablet/phone;
- cloud/backup sync with conflict handling;
- a “device status” API for diagnostics.

**Important:** design this as a proper service with authentication, versioning, and explicit
commands. Do not extend the current ad-hoc network command strings. A companion app is likely the
single biggest UX win because the 1024×600 screen is small for deep editing.

## 9. Developer platform

- Add a **plugin-style object registry** for synths/effects so new audio objects can be added without
  editing a giant switch.
- Add **feature flags** in CMake and a runtime capability list.
- Add **code generation** for parameter IDs, UI labels, and persistence from one schema.
- Add **profiling** around `SongManager::pulse`, `renderTracksAndMix`, and `SequenceManager` updates.
- Add **structured logging** with categories and a log viewer; the existing `DBG`/`log.c` paths are
  scattered.
- Add **ADRs** (architecture decision records) for major choices such as TSF vs AudIO, XML vs SQLite,
  and the parameter-ID width.

## 10. Suggested phased plan

### Phase 1 — Make change safe (foundation)

1. Versioned project format + migration + atomic save.
2. Headless test harness and simulator.
3. Parameter metadata/registry, at least for new parameters.
4. Extract a core library target; keep the UI app as a composition layer.
5. Start splitting unity builds and the largest files.

**Outcome:** new features can be added without breaking old projects or guessing at UI/engine flow.

### Phase 2 — Deepen the sequencer

1. Probability, conditions, ratchets, flams.
2. Per-step automation/parameter locks.
3. MIDI import/export (SMF).
4. Scene chaining/arrangement improvements.
5. Chord/arpeggiator/Euclidean generators.

**Outcome:** the product becomes materially deeper as a sequencer with relatively contained model
changes.

### Phase 3 — Sound and I/O

1. Per-track insert slots and master bus.
2. Sample playback/multi-sample instruments.
3. Audio recording/export/stems.
4. MIDI routing matrix, MIDI learn, MPE.
5. CV modulation matrix.

**Outcome:** stronger sound design and studio integration. This is the phase where `AudIO` integration
or a new audio graph decision becomes important.

### Phase 4 — Ecosystem and experience

1. Companion app/web editor.
2. Versioned local API, OSC/Ableton Link.
3. Responsive/desktop UI and theme editor.
4. Accessibility/localization.
5. Cloud/backup sync.

**Outcome:** the device is easier to integrate into a wider setup and less dependent on the small
screen for deep editing.

## 11. First concrete recommendations

If you want to start with the highest leverage and lowest regret:

1. **Add a project-format version and migration layer.** Every later feature depends on it.
2. **Build the headless simulator/test harness.** It makes every later feature measurable.
3. **Introduce parameter metadata for new parameters first**, then migrate existing managers
   gradually.
4. **Add step probability/conditions and MIDI export** as the first user-visible musical features.
5. **Create an `IAudioTrack`/`IAudioGraph` seam** before committing to either the current TSF chain or
   `AudIO` as the long-term mixer.

The codebase is large, but these changes are mostly additive. The existing model, parameter bus,
sequence builder, and UI component vocabulary are strong enough to support them if the foundation
work comes first.
