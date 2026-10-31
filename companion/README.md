# IGNITE companion app workspace

This folder is a **standalone starting point** for a companion app or external project editor. It is
intended to be copied or moved into its own repository.

It contains:

```text
companion/
  README.md
  schema/
    README.md
    ignite-xml-v0.xsd
  examples/
    README.md
    song-info.xml
    scene-info.xml
    track.xml
    pattern-info.xml
    pattern-bar.xml
    pattern-step.xml
    instrument.xml
    settings-general.xml
```

## What this is

The IGNITE device persists projects as a tree of XML files. The schema in this folder is a
reconstruction of that format from:

- `Source/Application/modules/common_defs/source/EngineDataStruct.h`
- `Source/Application/modules/Firmware/Application/Model/EngineFileHandler.cpp`
- `Source/Application/modules/Firmware/Application/Model/ModelParams.h`

The schema explicitly describes the current v0 format. It is not a new project format.

## What this is not

- It is not an official or versioned device API.
- It does not make the current XML format stable.
- It does not include the device's runtime parameter protocol, PlayTribe commands, or USB FunctionFS
  protocol.
- It does not validate cross-file references such as “this track points to a pattern that exists”.

## First tasks for the companion app

1. **Read-only project import**
   - Walk `Songs/<Song>/<Scene>/` and `Patterns/<Pattern>/BAR-<n>/`.
   - Parse the XML with the schema and build an in-memory project model.
   - Handle missing files and unknown attributes gracefully.

2. **Round-trip preservation**
   - Preserve attributes and child nodes the companion does not understand.
   - Do not rewrite the entire tree until you have a versioned writer.
   - Keep a backup before writing.

3. **Define a stable external model**
   - Map C++ names to friendly TypeScript/Rust/Python DTOs.
   - Replace 8-bit enum numbers with stable string keys.
   - Add a `schemaVersion` and migration path.

4. **Move to a live API later**
   - File import/export is the fastest path.
   - A live editor should use a versioned HTTP/WebSocket API with typed commands and events, not
     the existing ad-hoc PlayTribe/USB strings.
   - See `docs/companion-app-integration.md` in the application repo for the assessment.

## Moving this folder to a new repository

The folder has no build dependency on the IGNITE application. Copy it as-is:

```sh
cp -R companion /path/to/companion-repo
```

Then add your own app/build tooling around it. The examples can become test fixtures.

## Source provenance

The schema was reconstructed from the current implementation, not generated from a formal IDL.
Before relying on it for writes, compare it with a real project created by the current firmware and
freeze a schema version. The current device code still writes `FILE_VERSION = 0` and does not have a
migration framework.
