# IGNITE XML schema v0

This directory contains a reconstruction of the XML files written by
`Source/Application/modules/Firmware/Application/Model/EngineFileHandler.cpp`.

- Schema: [`ignite-xml-v0.xsd`](ignite-xml-v0.xsd)
- Examples: [`../examples/`](../examples/)
- Source model: `Source/Application/modules/common_defs/source/EngineDataStruct.h`
- Source writer/reader: `Source/Application/modules/Firmware/Application/Model/EngineFileHandler.cpp`
- Parameter/enum definitions: `Source/Application/modules/Firmware/Application/Model/ModelParams.h`

## Why multiple root elements?

IGNITE does **not** store a project as one XML document. It stores a tree of small XML files. Each file
has one of the root elements declared in the XSD.

```text
/data/ignite/Ignite_Files/Ignite_folder/
  Songs/
    <Song>/
      info.txt                    -> Song_Info
      <Scene>/
        info.txt                  -> SceneInfo
        TrackV1.txt               -> Track
  Patterns/
    <Pattern>/
      info.txt                    -> pattern
      BAR-<n>/
        info.txt                  -> pattern_bar
        step.txt                  -> step
  Instruments/
    <Instrument>.txt              -> Instrument
  Settings/
    SettingCnfg.txt               -> GeneralCnfg
    MidiCnfg.txt                  -> MidiCnfg
    ...
```

The `.txt` extension is historical; the content is XML.

## Root-to-file mapping

| Root element | File | Meaning |
|---|---|---|
| `Song_Info` | `Songs/<Song>/info.txt` | Song metadata |
| `SceneInfo` | `Songs/<Song>/<Scene>/info.txt` | Scene metadata |
| `Track` | `Songs/<Song>/<Scene>/TrackV1.txt` | All tracks in a scene |
| `pattern` | `Patterns/<Pattern>/info.txt` | Pattern metadata and used-by list |
| `pattern_bar` | `Patterns/<Pattern>/BAR-<n>/info.txt` | Bar metadata |
| `step` | `Patterns/<Pattern>/BAR-<n>/step.txt` | Steps, notes, and aux events |
| `Instrument` | `Instruments/<Instrument>.txt` | Instrument/patch data |
| `GeneralCnfg` | `Settings/SettingCnfg.txt` | General settings |
| `MidiCnfg` | `Settings/MidiCnfg.txt` or `Songs/<Song>/MidiCnfg.txt` | MIDI port/channel mapping |
| `CvioCnfgS` | `Settings/CvioCnfg.txt` or song-level | CV/gate settings |
| `CalibOffset` | `/factory/calibration/CalibrationOffset.txt` | CV calibration offsets |
| `SyStemStatus` | `/data/ignite/Ignite_Files/symstatus.txt` | Boot/power status |
| `mainInfoData` | `/data/ignite/Ignite_Files/...` | Last active song/master volume |

The settings roots (`GeneralCnfg`, `SongCnfgData`, `SceneCnfData`, `TrackCnfData`,
`PatternCnfgData`, `RecordCnfgData`, `BRayCnfgData`, `RemoteControlCnfgData`,
`MidiMachineControlCnfgData`, `MidiClkCnfgData`, `SculptModeCnfgData`, `UdsCnfgData`,
`CvioCnfgS`, `CalibOffset`) are intentionally defined loosely in this v0 schema. Their exact
attributes are still changing and are spread across several sections of `EngineFileHandler.cpp`.

## Data model correspondence

| XML object | C++ type | Notes |
|---|---|---|
| `Song_Info/Info` | `SongData` | Song metadata; the scene list is represented by directories |
| `SceneInfo/Info` | `SceneData` | Scene metadata; tracks live in `TrackV1.txt` |
| `Track/TrackData` | `TrackData` | Track names reference patterns and instruments by name |
| `TrackData/tvTrackData` | `TrackValue` | `paramType=1` MIDI CC, `paramType=2` program change |
| `pattern/pattern_info` | `PatternData` | Pattern metadata; bars live in subdirectories |
| `pattern_info/usedby` | `UsedByData` | Reference list for duplicate/copy/delete tracking |
| `pattern_bar/bar_info` | `BarData` | Bar length/direction/repeat |
| `step/step_data` | `StepData` | Step flags and child note/aux events |
| `step_node_data/note_data` | `NodeData` | Note pitch/velocity/length/offset |
| `aux_data` | `Aux` | MIDI CC, program change, pressure, pitch bend, etc. |
| `Instrument/Data` | `InstrumentData` | MIDI and internal-sound instrument settings |
| `Instrument/Data/tv` | `TrackValue` | Knob assignment/CC/program-change data |

## Important limitations

1. **This is v0.** `FILE_VERSION` is currently `0`, and there is no migration framework.
2. **Attributes are optional.** The device writer emits most fields, but this schema does not
   require them, so old or partial files remain inspectable.
3. **No range/enum validation yet.** Numeric ranges, enum values, and cross-file references are
   enforced in application code, not in this XSD.
4. **References are by name.** Tracks reference pattern/instrument names, not stable numeric IDs.
   Renaming a pattern or instrument requires updating the referring files.
5. **Settings are loose.** The settings roots are placeholders until their field sets are frozen.
6. **This is derived, not official.** It was reconstructed from the implementation and must be
   reviewed against a real project dump before being treated as a contract.

## Validation

With `libxml2-utils` installed:

```sh
xmllint --noout --schema companion/schema/ignite-xml-v0.xsd companion/examples/*.xml
```

Or with Python and `lxml`:

```python
from lxml import etree
schema = etree.XMLSchema(etree.parse("companion/schema/ignite-xml-v0.xsd"))
for path in ...:
    schema.assertValid(etree.parse(path))
```

## Recommended next step

Before a companion app writes files, add a **manifest** and a **schema version** to the project tree,
then define a migration policy. The current directory tree has no manifest, so a companion must
discover songs/scenes/patterns/instruments by walking folders.
