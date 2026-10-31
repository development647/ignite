# Companion app integration and schema assessment

Short answer: **the data model is available in source code, but there is no formal companion-app
schema or API contract yet.** You can build a companion app from the existing C++ structs and XML
files, but you should first extract and version a proper external schema. Otherwise the companion
will be coupled to implementation details that are currently free to change.

## 1. What exists today

### 1.1 C++ model objects

The de facto domain model is in:

- `Source/Application/modules/common_defs/source/EngineDataStruct.h`
- `Source/Application/modules/Firmware/Application/Model/ModelParams.h`
- `Source/Application/modules/common_defs/source/ignite_common_defs.h`

The main persisted objects are:

```text
SongData
  └── SceneData
        └── TrackData
              ├── main pattern name
              ├── fill pattern name
              └── track-value knob data

PatternData
  └── BarData
        └── StepData
              ├── NodeData (note, velocity, length, offset)
              └── Aux (CC, program change, pressure, pitch bend, ...)
```

These structs contain the field names and types a companion needs. They are **C++ implementation
types**, not a stable serialization contract:

- no JSON/protobuf/IDL annotations;
- no field-level documentation for external consumers;
- 8-bit IDs in several places;
- runtime pointers (`Instrument*`, `Pattern*`, `Track*`) mixed into some structs;
- defaults and semantics are implicit in manager code.

### 1.2 XML project files

`EngineFileHandler` is the de facto **file schema**. It writes per-object XML under:

```text
/data/ignite/Ignite_Files/Ignite_folder/
  Songs/
    <SongName>/
      info.txt
      <SceneName>/
        info.txt
        TrackV1.txt
  Patterns/
    <PatternName>/
      info.txt
      BAR-<n>/
        info.txt
        step.txt
  Instruments/
    <InstrumentName>.txt
  Settings/
    SettingCnfg.txt
    MidiCnfg.txt
    ...
```

The XML element/attribute names are visible in `EngineFileHandler.cpp`. Examples:

- song: `Song_Info` → `Info` with `songName`, `songTempo`, `songSwing`, `gTrackCount`, ...
- scene: `SceneInfo` → `Info` with `numBars`, `gBarLenInSteps`, `scaleFTS`, ...
- track: `Track` → `TrackData` with `trackName`, `mainPatternName`, `fillPatternName`, ...
- pattern: `pattern` → `pattern_info` with `numBars`, `timeBase`, `patternLastStepId`, ...
- bar: `pattern_bar` → `bar_info` with `stepCount`, `barRepeatCount`, `direction`, ...
- step: `step` → `step_data` with `stepId`, `enable`, `skipStatus`, `tieStatus`, ...
- note: `note_data` with `nodeId`, `note`, `velocity`, `lenInSteps`, `lenInTicks`, `delay`
- aux: `aux_data` with `state`, `statusByte`, `dataByte1`, `dataByte2`, `offset`

**Important:** `FILE_VERSION` is currently `0` (`EngineFileHandler.cpp`), and there is no migration
framework. The file layout and attributes are an implicit schema, not a published one.

### 1.3 Internal parameter/command model

The engine parameter bus is described in [architecture-guide.md](architecture-guide.md). In brief:

- `ModuleName` enumerates modules.
- `SongParam`, `SceneParam`, `TrackParam`, `PatternParam`, `InstrumentParam`, etc. enumerate
  parameter IDs.
- `IgniteMessageParam`/`IgniteParamList`/`AnyType` carry parameter updates.
- `IDevice` is the engine-facing API used by the GUI.

This is a good source for a future live API, but it is **not externally addressable** today:

- numeric 8-bit module/parameter IDs;
- no stable string keys;
- no units, display names, grouping, or capability metadata;
- no documented subscription/stream protocol;
- no external authentication or session model.

### 1.4 Existing device/PC protocols

There are several ad-hoc protocols, but none is a general companion schema:

- **PlayTribe TCP/UDP** (`PlayTribeConnectionManager.h`): string commands such as
  `Device Info`, `System Logs`, `Save Backup`, `Load Backup Start`, `Factory Reset`,
  `Firmware Update`, `Fw Status`. This is a device-operation protocol, not a project/editor API.
- **USB FunctionFS** (`usbFunctionFS.cpp`): string commands for file transfer, shell command
  execution, firmware update, and device info.
- **Sysex** (`Firmware/Application/Model/SysexDefs.h`): legacy parameter/command IDs for MIDI sysex.
- **`ComProtocol/PktMgr`**: framed packet protocol, not currently wired into the application.
- **FTP file exchange** used by PlayTribe for backup uploads/downloads.

These can inform a new API, but they should not be presented as a stable companion-app SDK.

## 2. What is missing for a companion app

To build a maintainable companion, you need four separate contracts:

1. **Project data schema** — songs, scenes, tracks, patterns, bars, steps, notes, aux, settings.
2. **Live control schema** — transport, parameter changes, selection, undo, meter/status events.
3. **Transport/API contract** — HTTP/WebSocket/FTP/USB, authentication, errors, versioning.
4. **Capability/version negotiation** — device firmware version, schema version, feature flags.

None of these exists as a formal artifact today.

## 3. Recommended schema strategy

### Step 1: Define a project schema

Create a machine-readable schema for the persisted model. Good choices:

- **JSON Schema** if the companion is TypeScript/JavaScript and the transport is JSON.
- **Protobuf** if you want compact binary messages and generated clients in several languages.
- **FlatBuffers** if you need very low-latency, zero-copy live messages.
- **OpenAPI** for the HTTP control surface, with JSON Schema components for project objects.

Start with these top-level DTOs:

```text
Project
  schemaVersion
  songs[]
    scenes[]
      tracks[]
        patternRef
        fillPatternRef
        instrumentRef
  patterns[]
    bars[]
      steps[]
        notes[]
        aux[]
  instruments[]
  settings
```

Use stable string IDs in the external schema. Do not expose internal pointers or 8-bit enum values
directly; map them to names such as `song.tempo`, `track.mute`, `pattern.timeBase`, `step.tie`.

### Step 2: Decide whether the companion edits files or talks to a live API

**Offline/file-based companion (fastest path):**

- read/write the existing XML tree over USB mass storage, FTP, or a future file API;
- implement the XML reader/writer against a published schema;
- useful for project backup, pattern library management, bulk edits, import/export;
- needs a file-format version and migration policy before editing is safe.

**Live companion (better UX):**

- device exposes a versioned local API over HTTP/WebSocket;
- project upload/download for bulk edits;
- command/event channel for transport, parameter changes, selection, and meters;
- companion renders its own UI and sends typed commands;
- requires authentication and a stable parameter registry.

A realistic first release is a **read-only or import/export companion** over files, followed by a
live API.

### Step 3: Add a parameter registry/capability model

Before a live API, define a stable address for every controllable parameter:

```json
{
  "key": "song.tempo",
  "type": "float",
  "min": 20.0,
  "max": 360.0,
  "default": 120.0,
  "unit": "bpm",
  "group": "transport",
  "writable": true
}
```

This can be generated from the existing `Module`/`Parameter` registration once parameter metadata is
added. Avoid making the companion hard-code numeric `moduleId`/`paramId` values.

### Step 4: Version everything

At minimum:

- `projectSchemaVersion`
- `apiVersion`
- `firmwareVersion`
- capability list (`features: ["pattern.import.smf", "mixer.master"]`)

Define compatibility rules:

- old project on new firmware: migrate forward;
- new project on old firmware: refuse with a clear message;
- unknown fields: ignore on read, preserve only if the format supports it;
- API: reject unsupported major versions; negotiate minor features.

## 4. Suggested API shape

If you build a live companion, keep transport and domain schema separate.

```text
REST/HTTP for project and file operations
  GET    /api/v1/device
  GET    /api/v1/project
  PUT    /api/v1/project
  GET    /api/v1/projects
  POST   /api/v1/projects/import
  GET    /api/v1/projects/{id}/export
  GET    /api/v1/patterns/{id}
  PUT    /api/v1/patterns/{id}

WebSocket for live events
  subscribe transport, selection, meters, parameter changes
  send transport.play / transport.stop / pattern.select / parameter.set
```

Do not model live control as raw shell-like strings. Define typed commands and events, validate
lengths and ranges, and keep the device-side adapter thin.

## 5. Practical build path

### v1: file-based companion

1. Publish the XML/file schema and a JSON Schema/TypeScript type set.
2. Implement read-only import of songs, patterns, instruments, and settings.
3. Add export/import of a pattern or song as JSON/SMF.
4. Add schema validation and clear errors.
5. Keep writes opt-in and make backups before modifying device files.

### v2: project sync

1. Add a file service (HTTP or WebSocket) with authentication and checksummed upload/download.
2. Add a project manifest with schema version and object dependencies (`UsedByData`).
3. Add atomic upload/rename and conflict detection.
4. Add capability reporting so the companion knows which firmware features exist.

### v3: live editor

1. Add the parameter registry with stable string keys.
2. Add command/event API for transport, selection, and parameter updates.
3. Add subscriptions/streaming for meters, playhead, and scene state.
4. Add typed command validation and error codes.
5. Generate the companion client from OpenAPI/JSON Schema.

## 6. Bottom line

- **Can you build a companion from this codebase?** Yes, the domain model and file layout are
  present and understandable.
- **Is there an official schema to build against today?** No. The closest things are the C++ structs,
  the implicit XML files, and the internal parameter IDs.
- **What should you do first?** Extract a versioned project schema from `EngineDataStruct.h` and
  `EngineFileHandler`, publish it, and build a read-only/file-based companion before attempting a
  live editor.
- **What should you avoid?** Coupling the companion to numeric `paramId_t`/`moduleId_t` values,
  internal pointers, `FILE_VERSION = 0` XML details, or the current ad-hoc PlayTribe/USB command
  strings.

See [architecture-guide.md](architecture-guide.md) for where the model and parameter bus live, and
[enhancement-roadmap.md](enhancement-roadmap.md) for the suggested implementation phases.
