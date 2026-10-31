# Example XML files

These examples follow the current `EngineFileHandler` output shape and are intended as fixtures for a
companion app. They are **not** a complete project tree; they show one representative file of each
core type.

`project-manifest.xml` is a **proposed companion envelope**; the current device does not write it.
It demonstrates how to wrap the legacy tree with `schemaVersion=1`, object/file inventories,
checksums, and migration history. See `../schema/migrations/README.md`.

The object examples validate against `../schema/ignite-xml-v0.xsd`. The proposed manifest validates
against `../schema/project-manifest-v1.xsd`. The settings example is intentionally loose in the object
schema because the settings roots are still changing.

Typical project tree:

```text
Songs/<Song>/info.txt
Songs/<Song>/<Scene>/info.txt
Songs/<Song>/<Scene>/TrackV1.txt
Patterns/<Pattern>/info.txt
Patterns/<Pattern>/BAR-<n>/info.txt
Patterns/<Pattern>/BAR-<n>/step.txt
Instruments/<Instrument>.txt
Settings/SettingCnfg.txt
Settings/MidiCnfg.txt
```
