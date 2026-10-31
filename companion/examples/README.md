# Example XML files

These examples follow the current `EngineFileHandler` output shape and are intended as fixtures for a
companion app. They are **not** a complete project tree; they show one representative file of each
core type.

They validate against `../schema/ignite-xml-v0.xsd` when using an XSD 1.0 validator. The settings file
is intentionally loose in the schema because the settings roots are still changing.

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
