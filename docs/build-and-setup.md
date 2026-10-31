# Building and running IGNITE

This document describes how to set up, configure, build, and run the IGNITE application from this repository. It reflects a real build attempted on Ubuntu 24.04.5 x86_64 with GCC 13.3 and CMake 4.4.4.

> **Release warning:** this repository is a source drop, not an official firmware release. The General MIDI SoundFont, MCU firmware, prebuilt bootloader, NXP/Marvell Wi-Fi firmware, and `pcmode` USB service are not included. See [Linux/README.md](../Linux/README.md) and [Source/Application/sf/README.md](../Source/Application/sf/README.md).

## 1. What you need

### Host requirements

- Linux, macOS, or Windows for the desktop application.
- CMake 3.20 or newer. CMake 3.28+ is recommended; the build was tested with CMake 4.4.4.
- A C++17 compiler. GCC 13.3, Clang, and MSVC are supported by JUCE 7.
- Git and network access for the first configure: CMake/CPM downloads JUCE 7.0.12 into the build directory.
- About 2 GB of free disk space for the build tree and JUCE checkout; more for the Buildroot image.

### Linux packages (Ubuntu 24.04)

The repository's documented package list is incomplete. The following list is the one that produced a successful build:

```sh
sudo apt-get update
sudo apt-get install -y \
  build-essential cmake pkg-config git \
  libasound2-dev libjack-jackd2-dev \
  libfreetype-dev libfontconfig1-dev \
  libx11-dev libxext-dev libxrender-dev libxrandr-dev \
  libxinerama-dev libxcursor-dev libxcomposite-dev \
  libxi-dev libxtst-dev \
  libglu1-mesa-dev mesa-common-dev \
  libcurl4-openssl-dev libssl-dev libflac-dev libvorbis-dev \
  libiw-dev
```

Notes:

- `libxi-dev` is required for `X11/extensions/XInput2.h`.
- `libiw-dev` is required for `iwlib.h` in the Wi-Fi manager.
- `libwebkit2gtk-4.0-dev` appears in older documentation but is not needed for the current configuration and is not available under that name on Ubuntu 24.04. The target explicitly sets `JUCE_WEB_BROWSER=0`. If you enable browser features, install the WebKit package appropriate for your distribution.
- For headless smoke tests, install `xvfb`.

### macOS

Install the Xcode command-line tools and CMake. JUCE will build against the native frameworks; no Linux X11 packages are needed.

### Windows

Install Visual Studio 2022 with the “Desktop development with C++” workload and CMake. The repository has MSVC-specific settings in `Source/Application/CMakeLists.txt`. The build was not tested on Windows during this review.

## 2. Desktop build (quick start)

From the repository root:

```sh
cmake -S Source/Application -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release -j"$(nproc)"
```

The first configure fetches JUCE and can take 1–3 minutes. The first full build can take several minutes; JUCE uses link-time optimization and the project compiles large unity translation units.

The executable and assets are produced at:

```text
build/apps/ignite/Ignite_artefacts/Release/Ignite
build/apps/ignite/Ignite_artefacts/Release/assets/
```

The assets are copied there by `Source/Application/apps/ignite/CMakeLists.txt`. Keep `assets/` next to the executable when running.

### Use a local JUCE checkout

To avoid downloading JUCE, point CMake at an existing JUCE 7.0.12 checkout:

```sh
cmake -S Source/Application -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DCPM_JUCE_SOURCE=/path/to/JUCE
cmake --build build --config Release -j"$(nproc)"
```

The build applies `Source/Application/patch/juce_multitouch.patch` to the JUCE checkout. If the patch has already been applied, the build records a flag in the build directory and skips it on later runs.

## 3. Supply the SoundFont before running

The application opens `/app/Ignite.sf2` on Linux (`Source/Application/modules/Firmware/Application/Model/ModelParams.h:264`). It does **not** currently open `Ignite.sf2` next to the executable.

If the SoundFont is missing, the app calls `tsf_set_output()` on a null `tsf*` and segfaults during `SongManager` construction. This was reproduced with `strace`:

```text
openat(AT_FDCWD, "/app/Ignite.sf2", O_RDONLY) = -1 ENOENT
SIGSEGV in Ignite::SongManager::SongManager(...)
```

Place a `.sf2` file you have the rights to at `Source/Application/sf/Ignite.sf2` so the build copies it into the artifact directory, then make it available at `/app/Ignite.sf2`:

```sh
# from the repository root
sudo mkdir -p /app
sudo cp Source/Application/sf/Ignite.sf2 /app/Ignite.sf2
```

Or use a symlink:

```sh
sudo mkdir -p /app
sudo ln -sf "$PWD/Source/Application/sf/Ignite.sf2" /app/Ignite.sf2
```

For a packaging change, the better long-term fix is to make the desktop build resolve the SoundFont relative to the executable or `assets/` directory and to make all `tsf_*` calls null-safe. See [code-review.md](code-review.md) finding C2.

## 4. Prepare runtime directories

On Linux the engine uses hardcoded data paths:

- `/data/ignite/Ignite_Files` — user data
- `/factory/calibration` — calibration data

If the parent directories do not exist, the app throws `std::filesystem::filesystem_error` during `EngineFileHandler` construction. For a desktop development machine, create them and give your user ownership:

```sh
sudo mkdir -p /data/ignite /factory/calibration /app
sudo chown -R "$USER":"$USER" /data/ignite /factory
```

These directories exist on the device image; this step is only for desktop runs.

## 5. Run the desktop app

With a graphical session:

```sh
cd build/apps/ignite/Ignite_artefacts/Release
./Ignite
```

For a headless/CI smoke test:

```sh
sudo apt-get install -y xvfb
cd build/apps/ignite/Ignite_artefacts/Release
timeout 20 xvfb-run -a -s "-screen 0 1024x600x24" ./Ignite
```

If the app starts normally it will keep running until killed; `timeout` returning 124 after 20 seconds is the expected “still running” result. A return code of 139 indicates the SoundFont or another runtime prerequisite is missing.

The application has known shutdown issues: several worker threads use infinite loops and join-only destruction. If it does not exit cleanly, terminate it explicitly. See [code-review.md](code-review.md) finding C5.

## 6. Testing

See [testing.md](testing.md) for the current test status, smoke-test commands, manual checklist, sanitizer builds, and hardware-test boundaries.

## 7. Device (aarch64) cross-build

The device image is built with Buildroot under `Linux/`.

### 7.1 Build the SDK

The Buildroot tree is large and downloads source tarballs on first use. It also requires NXP packages whose license terms Buildroot will ask you to accept.

```sh
cd Linux/buildroot
make Ignite_defconfig
make sdk -j"$(nproc)"
```

The SDK/toolchain is produced under `Linux/buildroot/output/host/`. The toolchain file is normally:

```text
Linux/buildroot/output/host/share/buildroot/toolchainfile.cmake
```

Buildroot also produces a relocatable SDK archive:

```text
Linux/buildroot/output/images/aarch64-buildroot-linux-gnu_sdk-buildroot.tar.gz
```

If you use the archive, extract it somewhere convenient:

```sh
tar -xf aarch64-buildroot-linux-gnu_sdk-buildroot.tar.gz -C /opt
```

Then the toolchain file is:

```text
/opt/aarch64-buildroot-linux-gnu_sdk-buildroot/share/buildroot/toolchainfile.cmake
```

The convenience script `Linux/builder.sh Ignite` performs the host package installation and runs `make Ignite_defconfig && make`, but it builds the full image, not just the SDK. It also expects a working Buildroot setup and all removable firmware/artifacts.

### 7.2 Cross-compile the application

From the repository root:

```sh
cmake -S Source/Application -B build-arm \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE=/path/to/toolchainfile.cmake
cmake --build build-arm --config Release -j"$(nproc)"
```

Output:

```text
build-arm/apps/ignite/Ignite_artefacts/Release/Ignite
```

On the device, install the binary under `/app/Ignite` and the SoundFont at `/app/Ignite.sf2`. The device image expects `/app` to be the application partition.

### 7.3 Full device image

`make` in `Linux/buildroot` produces the bootloader, kernel, rootfs, and application image via the post-image scripts. Before a release build, provide:

- `Linux/buildroot/board/freescale/imx8mm_var_som/ignite/mcu-image/Ignite_MCU.hex` (MCU firmware; not included)
- The NXP/Marvell `sd8987_uapsta.bin` Wi-Fi firmware under `rootfs_overlay/usr/lib/firmware/mrvl/`
- Any other NXP-licensed binaries requested by Buildroot
- A replacement for `pcmode` if you need the USB transfer gadget, or adjust `create-usb-gadgets.sh` so it does not block waiting for `/dev/usb-utp0/ep1`

The update packaging scripts (`scripts/createEncryptedImage.sh`) also require the MCU firmware and the generated `.swu` files.

## 8. Build-process evaluation

### Tested environment and result

| Item | Result |
|---|---|
| OS | Ubuntu 24.04.5 LTS x86_64 |
| Compiler | GCC 13.3.0 |
| CMake | 4.4.4 (installed via pip for this environment) |
| CPU | 4 cores |
| Configure | Succeeded after installing the package list above |
| First configure time | ~142 seconds (JUCE fetch + juceaide build) |
| Build | Succeeded after adding `libxi-dev` and `libiw-dev` |
| Output | `apps/ignite/Ignite_artefacts/Release/Ignite` (~9.3 MB), `assets/` |
| Runtime | Failed without `/data/ignite` and `/factory/calibration`; then segfaulted without `/app/Ignite.sf2` |
| Windows/macOS | Not tested in this environment |
| aarch64 device | Not tested; requires the Buildroot SDK |

### Observed build issues

1. **Missing XInput2 headers.** The first build failed with:
   ```text
   fatal error: X11/extensions/XInput2.h: No such file or directory
   ```
   Fix: install `libxi-dev`.

2. **Missing wireless headers.** The next build failed with:
   ```text
   fatal error: iwlib.h: No such file or directory
   ```
   Fix: install `libiw-dev`.

3. **Missing runtime directories.** The first run failed with:
   ```text
   filesystem error: cannot create directory: No such file or directory [/data/ignite/Ignite_Files]
   ```
   Fix: create `/data/ignite` and `/factory/calibration` as described above.

4. **Missing SoundFont.** After creating the directories, the app segfaulted. `strace` showed `/app/Ignite.sf2` did not exist. Fix: install a SoundFont at `/app/Ignite.sf2`. The code should also be fixed to handle this gracefully.

5. **WebKit is optional for this target.** Configure prints:
   ```text
   Package 'webkit2gtk-4.0' ... not found
   Package 'gtk+-x11-3.0' ... not found
   ```
   This did not block the build because `JUCE_WEB_BROWSER=0`.

6. **CMake re-runs on every build.** `Source/Application/timestamp/CMakeLists.txt` adds a `clear_cache` target that removes `BUILD_TIME` from the cache. Because `timestamp` depends on it, every `cmake --build` triggers reconfigure and the JUCE fetch check again. This is expected with the current timestamp implementation but slows iteration.

7. **CMake 4 deprecation warning.** CMake 4.4 warns that CPM uses the deprecated `FetchContent_Populate`; a future CMake release may drop it. If this becomes a problem, use CMake 3.28/3.31 or update CPM/JUCE integration.

8. **Warnings are suppressed.** The project adds `-w -ffast-math -Ofast` on GCC/Clang (`Source/Application/CMakeLists.txt:74`). A successful build does not mean the code is warning-free, and floating-point behaviour may differ from a standard build.

9. **The optional VST target is not currently buildable.** The option names are inconsistent (`IGNITE_VST_PLUGIN` vs `BUILD_VST`), and the plugin links a `ValueTreeDebugger` target that is not defined in this tree. Leave `IGNITE_VST_PLUGIN=OFF` (the default).

## 9. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `X11/Xlib.h` or `XInput2.h` not found | Missing X11/freetype dev packages | Install `libx11-dev libxi-dev libfreetype-dev libfontconfig1-dev` |
| `iwlib.h` not found | Missing libiw | Install `libiw-dev` |
| `juceaide` fails while configuring | Missing GUI build dependencies | Install the full Linux package list above |
| WebKit not found during configure | Optional browser feature | Ignore with `JUCE_WEB_BROWSER=0`, or install an available WebKit dev package |
| `filesystem error ... /data/ignite` | Host data directory missing | Create `/data/ignite` and `/factory/calibration` |
| Segfault immediately after launch | `/app/Ignite.sf2` missing | Install a valid SoundFont at `/app/Ignite.sf2` |
| No window opens on a server | No X display | Use `xvfb-run` or a real desktop session |
| Build reconfigures every time | `timestamp` `clear_cache` target | Expected; see section 7 |
| App does not exit on Ctrl+C/close | Infinite worker threads / join-only shutdown | Known issue C5; terminate the process |
| VST configure/build error | Optional plugin target incomplete | Keep `IGNITE_VST_PLUGIN=OFF` |
| Device image build stops at missing firmware | MCU/Wi-Fi/pcmode artifacts not in repo | Supply them as described in `Linux/README.md` |

## 10. Security note

This build is a development build. The application includes network and USB command interfaces that are not authenticated and can execute shell commands. Do not expose a device running this build to an untrusted network, and do not run it on a machine where the USB gadget is reachable by an untrusted host. See [code-review.md](code-review.md) for details and remediation priorities.

## 11. Useful paths

| Path | Meaning |
|---|---|
| `Source/Application/CMakeLists.txt` | Top-level application CMake project |
| `Source/Application/apps/ignite/CMakeLists.txt` | Main app target and asset copying |
| `Source/Application/sf/README.md` | SoundFont requirements |
| `Source/Application/modules/Firmware/Application/Model/ModelParams.h` | Runtime paths and `SOUND_FONT_FILE` |
| `Source/Application/modules/Firmware/Application/Model/EngineFileHandler.cpp` | `/data/ignite` and `/factory/calibration` paths |
| `Source/Application/timestamp/CMakeLists.txt` | Build-time timestamp and `clear_cache` target |
| `Linux/README.md` | Buildroot/device image instructions |
| `Linux/buildroot/board/freescale/imx8mm_var_som/ignite/` | Board files, rootfs overlay, update scripts |
