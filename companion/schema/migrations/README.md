# Versioning and migrations

This directory documents how a companion app should version and migrate the IGNITE XML project tree.

## Two version numbers

Do not conflate these:

| Version | Scope | Where |
|---|---|---|
| `FILE_VERSION` | One XML file/object | Existing `Info`/`data` attributes in `EngineFileHandler.cpp` |
| `schemaVersion` | Whole project/companion envelope | Proposed `IgniteProject.xml` manifest |

The current device writes `FILE_VERSION = 0` for individual objects. The proposed companion manifest
starts at `schemaVersion = 1`.

A project can therefore be:

```xml
<IgniteProject schemaVersion="1">
  ...
  <File path="Patterns/PATTERN-1/info.txt" fileVersion="0"/>
</IgniteProject>
```

That means “the project envelope is version 1, and this particular object still uses file version 0.”

## Version policy

Use these rules unless you have a stronger reason:

- **Major/schema version** increments when the project structure or semantics change.
- **Minor writer version** can be tracked in `Metadata.createdBy`/`appVersion`, not as a schema bump.
- **File version** increments only when that object's fields change incompatibly.
- A reader must refuse a major version it does not know.
- A reader should ignore unknown optional attributes and preserve them on round-trip.
- A writer must never silently drop unknown data.
- Downgrades are explicit exports, not automatic rewrites.

## Manifest

The proposed manifest is:

- `../project-manifest-v1.xsd`
- `../../examples/project-manifest.xml`

It carries:

- `schemaVersion`
- project metadata
- object inventory
- file inventory with checksums
- migration history
- firmware/reader compatibility hints

The current device does **not** emit this manifest. A companion can synthesize it on first import of a
legacy project.

## Migration contract

Each migration should be:

1. **Pure** — a function of the input project tree.
2. **Idempotent** — safe to detect and skip if already applied.
3. **Versioned** — `from` and `to` schema versions.
4. **Recorded** — append a `MigrationHistory` entry.
5. **Validated** — run XSD + semantic validation after migration.
6. **Reversible or backed up** — keep a pre-migration backup.
7. **Tested** — use real fixture projects, including malformed/partial ones.

Suggested layout:

```text
companion/
  schema/
    ignite-xml-v0.xsd
    project-manifest-v1.xsd
    migrations/
      README.md
      v0-to-v1.md
```

## Safe write sequence

```text
read project
  -> detect manifest
     -> present: validate and read schemaVersion
     -> absent: treat as legacy v0 and synthesize a manifest
  -> validate input
  -> create backup
  -> apply migrations in order
  -> validate output
  -> write to temporary directory
  -> atomic replace/rename
  -> record migration history
```

Never overwrite the only copy of a project in place. Keep a timestamped backup until the new tree has
been validated.

## Legacy v0 -> v1

See [`v0-to-v1.md`](v0-to-v1.md). The first migration is intentionally conservative: it adds the
manifest and checksums but does not rewrite object XML.
