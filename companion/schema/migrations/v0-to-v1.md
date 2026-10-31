# Migration: v0 legacy tree -> v1 manifested project

## Goal

Adopt a project tree produced by the current device (`FILE_VERSION = 0`, no manifest) into a
companion-managed project with `schemaVersion = 1`.

**No object fields change in this migration.** It adds the envelope and integrity metadata only.

## Input

```text
Songs/
Patterns/
Instruments/
Settings/
```

There is no `IgniteProject.xml`.

## Output

```text
IgniteProject.xml       # schemaVersion=1
Songs/...
Patterns/...
Instruments/...
Settings/...
```

Per-file `FILE_VERSION` values remain as they were.

## Steps

1. **Discover objects**
   - Walk `Songs/<Song>/info.txt`.
   - Walk `Songs/<Song>/<Scene>/info.txt`.
   - Walk `Songs/<Song>/<Scene>/TrackV1.txt`.
   - Walk `Patterns/<Pattern>/info.txt`.
   - Walk `Patterns/<Pattern>/BAR-<n>/info.txt`.
   - Walk `Patterns/<Pattern>/BAR-<n>/step.txt`.
   - Walk `Instruments/*.txt`.
   - Walk `Settings/*.txt`.

2. **Read object headers**
   - Capture `FILE_VERSION` from each `Info`/`Data`/`settings` element.
   - Do not require every optional field to exist.

3. **Compute integrity data**
   - For each file: path relative to project root, size, SHA-256.
   - Record the XML root type (`Song_Info`, `SceneInfo`, `Track`, `pattern`, `pattern_bar`,
     `step`, `Instrument`, settings root).

4. **Resolve references**
   - Track `mainPatternName` / `fillPatternName` → pattern directories.
   - Instrument names → instrument files.
   - `usedby` lists → song/scene/track references.
   - Record unresolved references as warnings, not hard failures.

5. **Write `IgniteProject.xml`**
   - `schemaVersion="1"`.
   - `Metadata` with project name, creator, device/firmware if known.
   - `Objects` inventory.
   - `Files` inventory with checksums.
   - `MigrationHistory` entry `from="0" to="1"`.

6. **Validate**
   - Validate the manifest against `project-manifest-v1.xsd`.
   - Validate each object against `ignite-xml-v0.xsd`.
   - Validate semantic references.

7. **Commit**
   - Write to a temp directory.
   - Rename into place only after validation.
   - Keep the pre-migration tree as a backup.

## Failure handling

If any step fails:

- do not delete or rewrite the input tree;
- keep the backup;
- report which object/file failed and whether it is structural or semantic;
- allow a partial/read-only import so the user can recover data.

## Future migrations

Later migrations can change object fields, for example adding step probability or automation. Each
should:

- bump `schemaVersion`;
- bump the relevant object `FILE_VERSION` only if that object changed;
- append a `MigrationHistory` entry;
- keep a v0/v1 fixture in tests.
