# Testing IGNITE

This document describes what can be tested today, what cannot, and how to run a basic smoke test. It complements [build-and-setup.md](build-and-setup.md).

## Current test status

There is **no automated test suite** in this repository and no public GitHub CI workflow. The existing Azure definitions under `Source/CI` are internal build pipelines, not tests.

At the moment, “testing” means:

1. build the application;
2. start it in a desktop or headless environment;
3. exercise the main UI/model workflows manually;
4. optionally build with sanitizers or debug symbols and inspect crashes.

Because the application uses hardcoded device paths and hardware interfaces, a desktop run can only test the UI/model/audio paths. MIDI DIN, CV/gate, front-panel MCU, and USB gadget behaviour require the device or a simulator setup.

## 1. Prerequisites

Follow [build-and-setup.md](build-and-setup.md) to install packages and build the app. At minimum you need `/app/Ignite.sf2`, `/data/ignite`, and `/factory/calibration` for a desktop run.

Quick reminder:

```sh
sudo mkdir -p /app /data/ignite /factory/calibration
sudo chown -R "$USER":"$USER" /data/ignite /factory
sudo cp /path/to/your/Ignite.sf2 /app/Ignite.sf2
```

## 2. Basic smoke test

Start from the build output:

```sh
cd build/apps/ignite/Ignite_artefacts/Release
./Ignite
```

For a headless host:

```sh
sudo apt-get install -y xvfb
cd build/apps/ignite/Ignite_artefacts/Release
timeout 20 xvfb-run -a -s "-screen 0 1024x600x24" ./Ignite
```

Interpretation:

| Exit status | Meaning |
|---|---|
| `124` | The app was still running when `timeout` killed it — basic startup passed |
| `0` | The app exited normally |
| `139` | Segfault — most often `/app/Ignite.sf2` is missing; check with `strace`/`gdb` |
| `134` | Abort — often a missing filesystem path or uncaught C++ exception |

Capture startup output:

```sh
timeout 20 xvfb-run -a -s "-screen 0 1024x600x24" ./Ignite \
  > /tmp/ignite-smoke.log 2>&1
echo "exit=$?"
tail -50 /tmp/ignite-smoke.log
```

If it crashes, get a backtrace:

```sh
gdb -batch -ex run -ex 'thread apply all bt 20' --args ./Ignite
```

For a missing-file check:

```sh
strace -f -e trace=openat,access -o /tmp/ignite.strace ./Ignite
grep -E 'Ignite\.sf2|ENOENT' /tmp/ignite.strace | tail -20
```

## 2.1 Built-in GUI test screens

The application itself is a JUCE GUI application; there is no separate test-only GUI binary. The main UI runs at 1024×600 and is the screen exercised by manual testing.

The build sets `ENABLE_HARDWARE_TEST=1` by default in `Source/Application/CMakeLists.txt`, which compiles in additional test controls. In the running UI:

1. Open **Settings**.
2. Open **Miscellaneous Options**.
3. Select **Test Data Mgmt**.

The **Test Data Mgmt** screen can create/wipe test data for songs, scenes, tracks, patterns, bars, and instruments. It also contains:

- **HardwareTest** — starts the hardware-test mode (front-panel/MCU path).
- **Touch Test** — shows a 10×8 touch grid and a colour bar; every grid cell must be touched before the test completes.
- **Mcu FW Upgrade test** — triggers the MCU firmware-upgrade test command.

If `ENABLE_HARDWARE_TEST` is set to `FALSE`, these screens are compiled out.

There is also an optional Windows-only front-panel keyboard simulator guarded by `FP_TEST_KEYBRD` in `Source/Application/modules/Firmware/Application/Model/FrontPannelManager.h`. It is commented out by default and is not built on Linux.

For a headless screenshot of the GUI, run it under Xvfb and capture the root window:

```sh
cd build/apps/ignite/Ignite_artefacts/Release
xvfb-run -a -s "-screen 0 1024x600x24" sh -c \
  './Ignite & sleep 10; import -window root /tmp/ignite-gui.png; kill %1'
```

`import` comes from ImageMagick.

## 3. Manual test checklist

A successful start is not enough. At minimum exercise the following in the UI. This list is intentionally broad; use your product requirements to decide which paths are release-blocking.

### Startup and UI

- [ ] Boot screen/window appears and does not immediately crash.
- [ ] Assets load: background, buttons, fonts, icons.
- [ ] Touchscreen/mouse and keyboard input work.
- [ ] All top-level modes open: Song, Scene, Track, Pattern, Instrument, Settings, Menu.

### Song / scene / track / pattern model

- [ ] Create a song, scene, track, and pattern.
- [ ] Rename/delete/copy each object.
- [ ] Add/remove bars and steps.
- [ ] Add/edit/delete notes; change velocity, length, delay, transpose.
- [ ] Use undo/redo and verify state restores correctly.
- [ ] Save, reload, and compare the loaded song with the saved state.
- [ ] Test backup/restore on a disposable data set (these paths run destructive shell commands).

### Playback and audio

- [ ] Play/stop/pause; verify transport position and tempo.
- [ ] Change timebase and swing; verify timing.
- [ ] Test internal SoundFont playback with a valid `/app/Ignite.sf2`.
- [ ] Test mute, solo, skip, fill, and pattern/song modes.
- [ ] Test MIDI clock and sync if hardware is available.
- [ ] Test MIDI output/input with a loopback or external device.

### Persistence and settings

- [ ] Save/load MIDI, CV/gate, and general settings.
- [ ] Reboot/power-cycle and confirm settings persist.
- [ ] Test factory reset only on a device/data set you can lose.
- [ ] Test firmware/backup UI paths only with a valid signed/trusted test package.

### Shutdown

- [ ] Close the window and verify the process exits.
- [ ] If it hangs, record the thread state with `gdb`; this is a known issue in the current code (`CThread` joins infinite worker threads).

## 4. Sanitizer builds

Sanitizers are useful because the code has several unchecked buffer and lifetime paths. The project adds `-w -Ofast` globally (`Source/Application/CMakeLists.txt`), which suppresses warnings and may reduce the usefulness of some diagnostics. A sanitizer build can still find memory errors.

Example AddressSanitizer + UndefinedBehaviorSanitizer build:

```sh
cmake -S Source/Application -B build-asan \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_CXX_FLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer -g" \
  -DCMAKE_C_FLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer -g" \
  -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=address,undefined"
cmake --build build-asan --config RelWithDebInfo -j"$(nproc)"
```

Run:

```sh
cd build-asan/apps/ignite/Ignite_artefacts/RelWithDebInfo
ASAN_OPTIONS=detect_leaks=0:abort_on_error=1 \
  xvfb-run -a -s "-screen 0 1024x600x24" ./Ignite
```

Notes:

- `detect_leaks=0` avoids noise from long-lived global services and threads while you are looking for memory-safety errors.
- For a more useful sanitizer build, temporarily remove `-Ofast`/`-w` from `Source/Application/CMakeLists.txt` in your working tree, or add `-O1` after the project flags. Do not ship that change as-is; it is only for diagnosis.
- A ThreadSanitizer build is also worth doing for `CMsgQueue` and the worker threads, but be prepared for many reports because the current queue is not synchronized.

## 5. Device/hardware testing

Desktop runs do not exercise:

- front-panel MCU UART protocol;
- RGB LEDs, encoders, pads;
- CV/gate outputs and calibration;
- 5-pin MIDI DIN ports;
- USB host MIDI;
- USB gadget / front-panel update path;
- Wi-Fi and the PlayTribe network service.

For those, build the device image and run on hardware as described in [build-and-setup.md](build-and-setup.md). Be careful with the network/USB interfaces: they are currently unauthenticated and can execute shell commands. Test only on an isolated network and with a device you can reflash.

## 6. What tests should be added

The highest-value additions, in order:

1. **Unit tests for protocol parsers**: `PktMgr`, sysex framing, MCU messages, XML project loading.
2. **Model lifetime tests**: copy/assignment/destruction of `Track`, `Pattern`, `Bar`, `Step`, `Scene`, `CSong`, `Instrument`.
3. **Queue/thread stress tests**: producer/consumer shutdown, timeouts, spurious wakeups.
4. **File round-trip tests**: save a song/pattern/instrument/settings file, reload it, compare.
5. **Sanitizer CI**: ASan/UBSan on Linux, TSan for queue/thread tests.
6. **Smoke test in CI**: launch under `xvfb` with a small test SoundFont, wait for a ready marker, then terminate.

Until those exist, keep a written record of the manual checklist above for each release candidate.
