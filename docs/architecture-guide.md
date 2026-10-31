# IGNITE architecture and extension guide

This document is a map of the codebase for someone who wants to **add functionality** rather than
chase a specific bug. For defects and security issues, see [code-review.md](code-review.md).

The short version: IGNITE is a JUCE application with a parameter/message bus connecting a large
model/engine layer to a touchscreen UI, plus hardware adapters for the front panel, MIDI, CV/gate,
USB, and Wi-Fi. Most features are added by extending the model structs, adding parameters, handling
them in a manager, exposing them in a UI screen, and persisting them.

## 1. Repository map

| Area | What lives there | Why it matters |
|---|---|---|
| `Source/Application/apps/ignite` | `main()`, window, startup sequence | Application entry point and lifetime |
| `Source/Application/modules/common_defs` | Shared types, enums, constants, UI data models | Change here when adding model fields, params, or shared enums |
| `Source/Application/modules/Common` | `Track`, `Pattern`, `Bar`, `Step`, `Scene`, `CSong`, `Instrument`, queues/threads | Core sequencing model and low-level runtime primitives |
| `Source/Application/modules/Firmware/Application/Model` | `IgniteEngine`, managers, playback, file handling, settings, front panel | Main engine/orchestration layer |
| `Source/Application/modules/hardware` | MCU UART, USB FunctionFS, Wi-Fi, PlayTribe, CV/I2C | Device I/O and platform integration |
| `Source/Application/modules/common_ui_controls` | Buttons, sliders, list boxes, keyboard, theme, popups | Reusable UI widgets |
| `Source/Application/modules/common_ui_components` | Tabbed component, pad buttons, mini-map, mode header | Reusable screen building blocks |
| `Source/Application/modules/ignite_ui` | Song/Scene/Track/Pattern/Instrument/Settings screens | Product UI and screen state |
| `AudIO/` | Patchable audio graph, buses/chains, DAW layer, effects, recorder | A second, largely independent audio engine |
| `ComProtocol/` | `PktMgr` framed protocol | Protocol library, not currently wired into the app |
| `Linux/` | Buildroot image, board files, rootfs overlay, update scripts | Device image and deployment |

The application is built from JUCE modules. Several module `.cpp` files include other `.cpp` files
(`Common.cpp`, `Firmware.cpp`, `common_defs.cpp`) to form large unity translation units.

## 2. Runtime startup and threads

At a high level:

```text
JUCE main
  -> IgniteApplication::initialise()
     -> UiEngineInterfaceInit() on a temporary thread
        -> EngineInit()
           -> IgniteEngine constructor
              -> EngineFileHandler
              -> PatternManager
              -> SongManager
              -> SceneManager
              -> TrackManager
              -> InstrumentManager
              -> FrontPannelManager
              -> settings managers
              -> SequenceManager
           -> IgniteEngine::initialize()
              -> SongManager::init()
              -> SequenceManager::init()
              -> settingsMidiClkCnfg->init()
              -> engineThread.startThread(...)
              -> FrontPannelManager::FrontPannelStartThreads()
        -> UiInterface (subscribes to parameters, starts publish thread)
     -> MainWindow / AppHome
```

Important threads:

- **Engine thread** (`IgniteEngine::engineThreadFunc`) consumes `engineMsgQ` and dispatches
  `msgSetParam`, `msgSetParamList`, `msgGetParam`, and `msgSetCommandParam` to modules.
- **UI publish thread** (`UiInterface::run`) consumes `enginePublishQ` and updates the UI.
- **Front-panel threads** read/write the MCU UART and process MCU messages.
- **MIDI clock / playback** is driven by `CMidiClock`, which calls `SongManager::pulse()`.
- **JUCE audio callback** calls `SongManager::renderTracksAndMix()` and writes the output.
- **USB host MIDI** has a Linux thread for device add/remove handling.
- **Track play queues** exist for parallel track processing (`TrackPlayQ_0..7`) when enabled.

When adding a feature, decide which thread owns the state. Most UI-originated model mutations go
through the engine thread. The audio callback and some front-panel/playback paths also touch model
state; keep new mutations on the engine thread where possible, keep the audio callback real-time-safe,
and let the UI thread send commands and render published state.

## 3. The parameter and command bus

This is the most important pattern to understand before adding UI-exposed functionality.

Core types:

- `moduleId_t` and `paramId_t` are currently `uint8_t`.
- `ModuleName` enumerates the engine modules (`moduleSong`, `modulePattern`, `moduleTrack`,
  `moduleSetting...`, etc.).
- Each manager derives from `Module` and registers `Parameter<T>` objects with min/max/default.
- `AnyType` is the type-erased value carrier.
- `IgniteParamList` carries `{param, value, startPos, count}` for list/bulk operations.
- `IDevice` is the engine-facing API used by the UI.
- `IgniteEngine` implements `IDevice` and routes calls to modules.

There are two paths:

1. **Queued path** — `setParam`, `setParam(list)`, `getParam`, `SetCommandParam`.
   These enqueue an `IgniteMessageParam` on `engineMsgQ`; the engine thread dispatches later.
2. **Synchronous path** — `SetCommand`.
   This calls the target module directly and is used where the caller needs an immediate result or
   where ordering matters.

A typical parameter change:

```text
UI control
  -> _PUiVirtualEngine->setParam(moduleUI, moduleSong, paramSongTempo, value)
  -> IgniteEngine::engineMsgQ
  -> engineThreadFunc()
  -> SongManager::setParam / onParameterChange
  -> model changes
  -> paramlistener->publish(...)
  -> UiInterface::publish()
  -> enginePublishQ
  -> UiInterface::run()
  -> UI updates
```

To add a new UI-exposed setting, the usual checklist is:

1. Add an enum value in the relevant `*Param` enum in `ModelParams.h`.
2. Add `AddParameter<T>(...)` in the manager constructor.
3. Handle it in `ParamHandler`/`onParameterChange`.
4. Return it from `getParamList` if the UI reads it back.
5. Add the UI control and wire it to `setParam`/`SetCommand`.
6. Persist it through `EngineFileHandler` and `EngineDataStruct`.
7. If it participates in undo, add it to the default undo list and make the undo path work.

### Architectural limits to plan around

- 8-bit `paramId_t` limits each module to roughly 255 parameters.
- 8-bit `moduleId_t` limits the module count.
- Parameters carry min/max/default but little metadata: no units, display names, grouping, or
  feature flags. UI code hard-codes much of that.
- Each manager repeats similar `getParamList` switch logic, undo bookkeeping, and save/load code.
- Adding a feature often touches many files (`ModelParams.h`, manager, UI, file handler, tests).

These are good candidates for a parameter-registry/code-generation enhancement before the feature
surface grows much larger.

## 4. Model hierarchy

The persisted model is built from `EngineDataStruct.h` and `ModelParams.h`:

```text
SongData
  ├── song metadata (id, name, tempo, swing, track count, number of scenes)
  └── SceneData
        ├── scene metadata (bars, steps per bar, FTS scale/root, transpose, tempo, swing)
        └── TrackData
              ├── mute/solo/record, MIDI in/out instrument names
              ├── main pattern name
              ├── fill pattern name
              └── track-value (knob) data

PatternData
  └── BarData
        └── StepData
              ├── NodeData (notes: pitch, velocity, length, offset)
              └── Aux events (CC, program change, pressure, pitch bend, etc.)
```

Runtime equivalents:

- `CSong` owns `SongData`; `Scene` owns `SceneData`; `Track` owns `TrackData`;
  `Pattern` owns `PatternData`; `Bar` owns `BarData`; `Step` owns `StepData`.
- `SongManager::activeSong` is the loaded song.
- `CSong::editScene` / `playScene` select the edited and playing scene.
- `Scene::editTrack` selects the edited track.
- `PatternManager::patternList` owns patterns; `InstrumentManager::instrumentList` owns instruments.
- Names are used as stable references in several places, and `UsedByData` tracks which song/scene/
  track uses a pattern or instrument.

For new data, decide whether it is:

- **per song, per scene, per track, per pattern, per bar, per step, or per note/event**;
- **persistent** (file format) or **runtime-only** (playhead, UI selection, cache);
- **global** (settings) or **project-scoped**.

The file format currently uses `FILE_VERSION = 0` and XML files. There is no migration framework, so
adding persistent fields without a versioning strategy will make old projects fragile.

## 5. Playback and sequencing pipeline

The playback path is important for any musical feature.

```text
CMidiClock timer
  -> SongManager::pulse(pulse)
     -> advance scene step/bar
     -> for each track: Track::pulse(sceneBarId, sceneStepId)
        -> SequenceManager event lookup
        -> Track::playStepEvents()
           -> internal: TSF note on/off + effects
           -> external: MIDI out
           -> CV/gate generation
     -> audio callback: SongManager::renderTracksAndMix()
        -> each Track::sfSynthesizeAudio()
        -> mix to master buffer
```

`SequenceManager` precomputes, for each pattern:

- `SequenceOrder`: bar/step ordering, including direction and skipped steps.
- `SequenceEvents`: tick-offset event maps.
- `PatternInfo`: bar info, timebase, bar loop.

This is the main seam for transformations that affect how notes are read, such as direction,
probability, generative variation, or chord/scale expansion. If a feature changes event timing or
note content, start in `SequenceManager` rather than the audio callback.

`Track` owns the per-track playback state: current step, bar, pulse, swing, repeat count, recording
buffer, MIDI port/channel, CV state, TSF instance, and the fixed internal effects chain. The audio
path renders a 20 ms mono block, applies reverb/chorus/EQ/filter/gain, and sums into the master
buffer.

## 6. UI architecture

The main UI is deliberately a fixed 1024×600 touchscreen interface.

- `AppHome` owns the top/bottom bars, main mode, status bars, and the touchscreen test overlay.
- `AppMainmode` owns the top-level tabs (`MENU`, `SONG`, `SCENE`, `TRACK`, `PATTERN`) and switches
  between the major screens.
- Each feature area has `mt_ignite_*` components: songs, scenes, tracks, patterns, instrument,
  settings, CV, MIDI, recording, backup, etc.
- `common_ui_controls` provides the reusable widget vocabulary.
- `common_ui_components` provides tab bars, pad groups, mini-maps, and headers.
- `common_Theme` contains the colour palette; `ignite_layout.h` contains the fixed geometry.
- Assets are loaded from `assets/` by filename; the theme/layout is strongly tied to those assets.

Screen state is a mix of:

- engine state fetched through `getParam`/`getParamList`;
- global UI arrays such as `gSongs`, `gInstruments`, and pattern arrays;
- singleton UI components (many `Get...Instance()` implementations);
- explicit `updateDataFromEngine()` / `refresh...UI()` methods after commands.

When adding a screen, expect to touch:

- the new component under `ignite_ui/source/...`;
- `AppMainmode` or `AppMenu` for navigation/visibility;
- `AppHome::hideAll()` / menu visibility reset;
- the theme/layout constants;
- the UI publish/refresh path.

The UI is not a generic reactive framework. If you add a lot of cross-screen state, consider adding a
small view-model/state layer instead of more globals and manual refresh calls.

## 7. Hardware and I/O layers

- `FrontPannelManager` owns the MCU UART, key/LED queues, MCU messages, firmware update flow, and
  front-panel device status. `FrontPannelUtility` interprets MCU messages; `FrontPannelLed` handles
  LED output.
- `usbFunctionFS` implements the USB function endpoint protocol.
- `PlayTribeConnectionManager` handles the PC companion connection over Ethernet/Wi-Fi.
- `wifiManager` handles scanning/connecting and Wi-Fi properties.
- `cvControl`/`i2cManager` handle CV/gate hardware.
- MIDI device handling lives largely in `SongManager` (`IgniteMidi`, USB host device threads, port
  maps, clock send/receive, MMC/remote-control parsing).

If you are adding a new hardware capability, define the protocol/message shape first, then add a
small adapter. Avoid putting feature logic directly in the UART/network readers; keep them as
transport and let the engine/manager own the feature.

## 8. Persistence

`EngineFileHandler` stores data under:

```text
/data/ignite/Ignite_Files/Ignite_folder/
  Songs/
  Patterns/
  Instruments/
  Settings/
```

The device image additionally uses `/data/ignite` for user data and `/factory/calibration` for
calibration. The current format is per-object XML with `FILE_VERSION = 0` and backup/restore helpers.

For new persistent data:

1. add fields to `EngineDataStruct.h` with safe defaults;
2. write/read them in `EngineFileHandler`;
3. decide on a format version bump and migration policy;
4. ensure old projects load with defaults;
5. update the backup/restore path;
6. test round-trip save/load on a disposable data set.

## 9. Audio library: `AudIO`

`AudIO/` is a separate patchable audio graph with:

- `Design` objects, chains, buses, insert effects, metering;
- `DawEngine`/`DawBus` for a small DAW layer;
- objects for oscillators, ADSR, mixer, playback, recorder, SoundFont synth, and Airwindows effects;
- its own CMake targets and examples.

It is **not currently linked into the `apps/ignite` target**. The application's active audio path is
the `Track`/TinySoundFont/JUCE path. This is an opportunity: either integrate `AudIO` as an optional
backend or borrow its graph/bus/effect abstractions for a future mixer, rather than building another
audio graph from scratch.

Legacy `CSoundFontEngine`/`CSoundEngine` simulators exist under `modules/Common/Board`, but the main
application uses `tsf` directly through `Track`.

## 10. Build structure and feature flags

- `Source/Application/CMakeLists.txt` defines global flags, fetches JUCE, and adds `timestamp`,
  `modules`, and `apps`.
- `modules/CMakeLists.txt` uses `juce_add_modules` with the module directories.
- `apps/ignite/CMakeLists.txt` defines the main target, assets, SoundFont copy, and optional ASan
  flags.
- `ENABLE_HARDWARE_TEST=1` compiles in the test screens.
- `FP_TEST_KEYBRD`, `FP_SIM_LINUX_REMOTE_SERVER`, and related front-panel flags are compile-time
  switches in `FrontPannelManager.h`.
- Module `.cpp` files are unity-style includes; this makes full builds large and reduces parallel
  compilation.

Feature flags are useful but currently ad hoc. If you add large optional features, define them in
CMake and keep them out of the core model where possible.

## 11. Where to add common kinds of features

| Feature | Start here | Also likely touched |
|---|---|---|
| Per-track parameter | `TrackData` + `TrackParam` in `ModelParams.h` | `TrackManager`, `Track`, `EngineFileHandler`, `mt_ignite_track*`, `mt_ignite_track_values` |
| Per-step or per-note property | `StepData`/`NodeData` | `Step`, `PatternManager`, `SequenceManager`, `EngineFileHandler`, `mt_ignite_step*`/grid view |
| Pattern transform/generator | `PatternManager` or a new transformer class | `Pattern`, `SequenceManager`, pattern UI, tests |
| New pattern direction/order rule | `PatternDirection`, `SequenceManager` | `mt_ignite_pattern*`, file handler |
| New internal synth/effect | `Track` effects or `AudIO/Objects` | `mt_ignite_track_values`/settings, audio callback, CMake |
| New MIDI routing/transform | `SongManager` MIDI path, `InstrumentData`, `Track` | MIDI settings UI, file handler |
| New CV/gate behavior | `Track` CV path, `cvControl` | `SettingsCvioCnfg`, CV UI, calibration |
| New screen | `ignite_ui/source/...` | `AppMainmode`, `AppMenu`, `AppHome`, theme/layout, assets |
| New global setting | `SettingsGeneralCnfg`/specific settings manager | `ModelParams.h`, `EngineFileHandler`, settings UI |
| New project-level entity | `EngineDataStruct.h`, `EngineFileHandler` | model manager, UI, backup/restore |
| New network/companion feature | new service under `hardware` or a separate module | protocol, UI, build flags |

A practical feature slice is:

1. model field and defaults;
2. parameter/command plumbing;
3. engine behavior;
4. persistence and migration;
5. UI control and refresh;
6. tests or a simulator scenario;
7. documentation.

## 12. Suggested reading order

1. `ModelParams.h` — module/parameter enums and message structs.
2. `IgniteEngine.h/.cpp` — dispatch, module registration, queues.
3. `EngineDataStruct.h` — persisted model.
4. `SongManager.h/.cpp` — playback, audio callback, MIDI, scenes.
5. `SequenceManager.h/.cpp` — timing/event maps.
6. `Track.h/.cpp` — per-track playback, synth, effects, CV.
7. `PatternManager`/`Pattern`/`Bar`/`Step` — editing model.
8. `AppHome`/`AppMainmode`/`mt_ignite_*` — UI composition and screen flow.
9. `EngineFileHandler` — persistence.
10. `FrontPannelManager`/`hardware` — device I/O.

If you only read one file first, read `IgniteEngine.h`; if you only read one implementation first, read
`SongManager.cpp` around `pulse`, `renderTracksAndMix`, and `audioDeviceIOCallbackWithContext`.
