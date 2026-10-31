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
    project-manifest-v1.xsd
    migrations/
      README.md
      v0-to-v1.md
  examples/
    README.md
    project-manifest.xml
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

## Proposed project manifest

The current device has **no manifest**. A companion should add one on first import so it can version,
validate, migrate, and safely round-trip a project.

Proposed path:

```text
<project root>/IgniteProject.xml
```

Proposed schema:

```text
schema/project-manifest-v1.xsd
examples/project-manifest.xml
```

The manifest carries:

- `schemaVersion` — the project/envelope version;
- project metadata (`projectName`, `createdBy`, `deviceModel`, `firmwareVersion`);
- object inventory (`song`, `scene`, `track-list`, `pattern`, `bar`, `step`, `instrument`, `settings`);
- file inventory with path, root type, per-file `fileVersion`, size, SHA-256;
- migration history;
- minimum reader/firmware compatibility hints.

Important distinction:

```text
schemaVersion  = version of the whole project/manifest envelope
FILE_VERSION   = version of one XML object file
```

The current device writes `FILE_VERSION = 0`. The proposed companion manifest starts at
`schemaVersion = 1`. A v1 project can still contain fileVersion 0 objects.

See:

- `schema/project-manifest-v1.xsd`
- `examples/project-manifest.xml`
- `schema/migrations/README.md`

## Schema versioning and migrations

Adopt these rules before write support:

1. **Version the project, not just individual files.**
   - `schemaVersion` for the manifest/envelope.
   - `FILE_VERSION` for each XML object.
2. **Legacy projects are v0.**
   - No manifest.
   - Discover objects by walking the directory tree.
   - Synthesize a v1 manifest without rewriting object files.
3. **Migration chain.**
   - `v0 -> v1 -> v2 ...`
   - Each migration is pure, idempotent, versioned, and recorded in `MigrationHistory`.
   - Refuse unknown major versions; warn on unknown optional fields.
4. **Safe write sequence.**
   - Validate input.
   - Back up the project.
   - Migrate into a temporary directory.
   - Validate the output.
   - Atomically replace/rename.
   - Never overwrite the only copy.
5. **Preserve unknown data.**
   - A companion must not silently drop attributes or child elements it does not understand.
   - Use a round-trip-preserving XML layer, not a strict “known fields only” model.
6. **Test fixtures.**
   - Keep a real v0 project fixture and a v1 migrated fixture.
   - Validate both against the schemas.
   - Include malformed/partial cases.

The first migration is intentionally conservative: **v0 -> v1 only adds the manifest and checksums.**
It does not rewrite `Song_Info`, `SceneInfo`, `Track`, `Pattern`, `Bar`, `Step`, or `Instrument`
fields. Later migrations can change object fields and bump the relevant `FILE_VERSION`.

See `schema/migrations/v0-to-v1.md`.

## First tasks for the companion app

1. **Read-only project import**
   - Walk `Songs/<Song>/<Scene>/` and `Patterns/<Pattern>/BAR-<n>/`.
   - Parse the XML with the schema and build an in-memory project model.
   - Handle missing files and unknown attributes gracefully.

2. **Create the v1 manifest**
   - Inventory objects and files.
   - Compute SHA-256 checksums.
   - Record the v0 -> v1 migration.
   - Leave object XML untouched.

3. **Round-trip preservation**
   - Preserve attributes and child nodes the companion does not understand.
   - Do not rewrite the entire tree until you have a versioned writer.
   - Keep a backup before writing.

4. **Define a stable external model**
   - Map C++ names to friendly TypeScript/Rust/Python DTOs.
   - Replace 8-bit enum numbers with stable string keys.
   - Add `schemaVersion` and migration tests.

5. **Move to a live API later**
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
