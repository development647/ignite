# IGNITE (BE 0716-AAF) code review

- **Repository snapshot:** `0371a3ea` (`main`, clean tree)
- **Review date:** 2026-10-31
- **Scope:** `Source/Application`, `AudIO`, `ComProtocol`, `Linux/` scripts and Buildroot integration
- **Method:** static review plus a real desktop configure/build/run attempt on Ubuntu 24.04 x86_64 (GCC 13.3, CMake 4.4.4)
- **Build result:** application configures and builds after installing the dependencies listed in [build-and-setup.md](build-and-setup.md). The resulting binary **segfaults at startup unless a SoundFont is installed at `/app/Ignite.sf2`** (confirmed with `strace` and `gdb`).

The build is currently a useful development build, not a hardened release build. The most serious risks are unauthenticated network/USB command interfaces, shell command construction from filenames, unchecked protocol lengths, and object-lifetime mistakes.

## Severity key

| Level | Meaning |
|---|---|
| Critical | Remotely or physically exploitable for command execution, memory corruption, or data loss |
| High | Crash, double-free, hang, or security weakness on common paths |
| Medium | Incorrect behaviour, data corruption, maintenance or release risk |
| Low | Cleanup, portability, or developer-experience issue |

## Critical and high security findings

### S1. Unauthenticated TCP control server can execute shell commands — Critical

`PlayTribeConnectionManager` opens TCP port 8080 and processes raw, unframed strings from the client. There is no authentication, session key, or command allowlist. The handler includes firmware update, factory reset, backup restore, log extraction, and device restart.

Evidence:
- `Source/Application/modules/hardware/source/PlayTribeConnectionManager.cpp:366-376` — raw `recv()` data is passed directly to `processCommandReceivedOverEthernet()`.
- `:413-493` — command handler; `:474-479` builds `cp`/`rm` shell commands from the packet payload.
- `:429-462` — further `system()` calls for logs and backup handling.
- `Linux/buildroot/board/freescale/imx8mm_var_som/ignite/rootfs_overlay/etc/systemd/system/ignite.service:9-12` — no `User=`, so the application runs with the service manager's default privileges (root).

Impact: anyone who can reach the device on the network can invoke destructive operations and, via the filename payload in `DEVICE_FW_UPDATE_REQUEST`, inject shell commands.

Recommendation:
- Do not ship this service enabled by default.
- If it is required, add mutual authentication and a strict command allowlist.
- Never interpolate network data into a shell string. Use `posix_spawn`/`execve` with fixed argument vectors and canonicalized paths.
- Run the service as an unprivileged user and sandbox it with systemd (`User=`, `ProtectSystem=strict`, `NoNewPrivileges=yes`, `PrivateTmp=yes`, etc.).

### S2. UDP discovery parser writes past its stack buffer — Critical

Evidence: `Source/Application/modules/hardware/source/PlayTribeConnectionManager.cpp:236-245`.

```cpp
char buffer[1024];
int n = recvfrom(udp_sockfd, buffer, 1024, 0, ...);
...
buffer[n] = '\0';
```

A 1024-byte datagram produces `n == 1024`, so the terminator writes `buffer[1024]` (one byte out of bounds). The `n < 0` path can also fall through with a negative index.

Recommendation: receive at most `sizeof(buffer) - 1`, reject `n <= 0`, and always terminate explicitly.

### S3. USB FunctionFS exposes arbitrary command execution and file access — Critical (physical)

`USBFunctionFS` implements a small shell-like protocol over the USB function endpoint:

Evidence: `Source/Application/modules/hardware/source/usbFunctionFS.cpp`:
- `UCmd:` → `popen2(buff + 5, ...)` executes an arbitrary shell command (`:1005+`).
- `ReadFile:` → opens any caller-supplied path for reading (`:966-1004`).
- `WFile:` / `Wdata:` → opens any caller-supplied path for writing and allocates a host-supplied size (`:798-850`).
- `CREATE_DIR:` → creates arbitrary directories (`:1132+`).

Impact: a physical USB host can read/write files and execute commands with the application's privileges. This is especially dangerous together with the root service above.

Recommendation: compile this interface out of production builds, or require an authenticated manufacturing mode. At minimum, use `O_NOFOLLOW`, restrict paths to a dedicated directory, bound transfer sizes, and never use a shell.

### S4. Shell injection through firmware and backup filenames — High

Filenames found on USB storage or received over the network are inserted into `system()` command strings.

Evidence:
- `Source/Application/modules/Firmware/Application/Model/FrontPannelManager.cpp:2221` — `tail ... <fwfilepath>`.
- `:2239` — `openssl ... -in <path> -out <path>`.
- `:2301-2306` — `mount -o loop ... <path>`.
- `:2436` — `rm -rf <path>`.
- `Source/Application/modules/hardware/source/PlayTribeConnectionManager.cpp:474-479` — network-supplied filename in `cp` and `rm -rf`.
- `Source/Application/modules/ignite_ui/source/settings/mt_ignite_backup.cpp:136-178` — backup paths passed to `system()`.

Filenames can contain spaces, `;`, `$()`, quotes, and other shell metacharacters. Even on a trusted device, a USB stick is an untrusted input.

Recommendation: replace shell commands with filesystem APIs and direct process execution. If a shell is unavoidable, use a strict filename whitelist and quote every argument with a proven escaping helper (not simple string concatenation).

### S5. MCU protocol parser has stack overflows and an uncaught exception — High

Evidence: `Source/Application/modules/Firmware/Application/Model/FrontPannelManager.cpp`:
- `:915-935` — `char szBuff[100]`; `data` is a `uint8_t` from the MCU and can be up to 255, so the copy loop can overflow the stack.
- `:1025-1040` — same `szBuff[100]` pattern for knob messages.
- `:1035` — `McuToUiMap.at(szBuff[0])` throws `std::out_of_range` for an unknown ID; the exception escapes the thread.
- `:1060-1068` — `SysMessage::Data` is 50 bytes; the MIDI path is bounded, but other paths are not consistently bounded.

Recommendation: check `data <= sizeof(szBuff)`, validate all packet lengths before reading fixed payload positions, and use `find()` rather than `at()` for externally supplied IDs.

### S6. Update and backup crypto is not a security boundary — High (design)

The firmware/backup keys are hardcoded in the repository, and the update package is not signed. The README acknowledges this, but the implementation still risks being mistaken for integrity protection.

Evidence:
- `Source/Application/modules/Firmware/Application/Model/FrontPannelManager.h:152` — update key.
- `Linux/buildroot/board/freescale/imx8mm_var_som/ignite/scripts/createEncryptedImage.sh` — update encryption key.
- `Source/Application/modules/hardware/source/PlayTribeConnectionManager.cpp:602-614` — XOR "encryption" for the FTP password with a static key.
- `Source/Application/modules/hardware/source/PlayTribeConnectionManager.cpp:41-58` — password generated with `rand()`, and `set_ftp_user_password()` is currently a stub returning success.

Recommendation: sign release images and verify the signature before `swupdate`. Use a real KDF/authenticated encryption if this is meant to protect anything, or explicitly document that it is only packaging. Never call XOR with a static key "encryption" in user-facing text.

### S7. Release service runs as root — High (operational)

`ignite.service` has no `User=` setting. Combined with the network/USB interfaces, any exploit gains root. Add privilege separation, a read-only root filesystem where possible, and systemd hardening.

Also verify the watchdog setup: the application periodically runs `systemd-notify WATCHDOG=1` from a child process. With the service's default `NotifyAccess=main`, systemd may ignore notifications from the `systemd-notify` child; this needs validation, or `NotifyAccess=all`/an in-process `sd_notify()` implementation.

## High and medium correctness findings

### C1. The engine object has two owners and will be double-deleted — High

Evidence:
- `Source/Application/modules/Firmware/Application/Model/IgniteEngine.cpp:61-66` — `_PIgniteEngine` owns the engine and returns a raw pointer.
- `Source/Application/apps/ignite/Main.cpp:80` — the raw pointer is wrapped in a second `std::unique_ptr`.

At static destruction both `_PIgniteEngine` and `_PUiVirtualEngine` destroy the same object. In addition, `_PUiVirtualEngine` is written from the engine thread and read from the main thread without synchronization (`Main.cpp:80`, `:106`), which is a data race.

Recommendation: return `std::unique_ptr<IDevice>` from `EngineInit` (or explicitly `release()` ownership from `_PIgniteEngine`), and publish the ready pointer with a mutex/atomic/condition variable. Do not poll a non-atomic `unique_ptr`.

### C2. Startup segfaults when the SoundFont is missing — High

Evidence:
- `Source/Application/modules/Firmware/Application/Model/SongManager.cpp:517-523` calls `tsf_set_output`, `tsf_set_max_voices`, and `tsf_channel_set_volume` without checking the result of `tsf_load_filename`.
- `Source/Application/modules/Firmware/Application/Model/ModelParams.h:264` hardcodes the Linux path `/app/Ignite.sf2`.
- `Source/Application/apps/ignite/CMakeLists.txt` copies a supplied SoundFont next to the build artifact, but the runtime path is `/app/Ignite.sf2`.

Reproduction on a desktop build:

1. Configure and build the app.
2. Run it from the artifact directory.
3. `strace` shows `openat("/app/Ignite.sf2") = -1 ENOENT` followed by `SIGSEGV` in `SongManager::SongManager`.

Recommendation: guard all `tsf_*` calls with a null check after loading, and make Track/SFSynth paths tolerate a missing SoundFont. The CMake message “the app will start without internal sounds” is currently false. Either fix the code or fail at startup with a clear error message.

### C3. `CSong` copy constructor stores pointers into the source song — High

Evidence: `Source/Application/modules/Common/Modules/CSong.cpp:56-67`.

The scenes are copied into `this->_songData->sceneList`, but `editScene` and `playScene` are assigned `&(*i)` where `i` iterates `source._songData->sceneList`. The copied song therefore points into the original song's data. This is exercised by `SongManager::copySong` (`SongManager.cpp:3904`).

Recommendation: point at the copied scenes (`&this->_songData->sceneList.back()` during the loop, or search the destination list after copying). Also copy `startSceneId`, `endSceneId`, and `jumpSceneId` if they are part of the intended song state.

### C4. `CMsgQueue` is not thread-safe and ignores timeouts — High

Evidence: `Source/Application/modules/Common/Os/CrossPlatform/CMsgQueue.h:27-76`.

- `put()` reads `_queue.size()` without the mutex.
- `get()` ignores `timeoutTicks` and always waits forever.
- `_cond.wait(mlock)` has no predicate; a spurious wake-up can read `front()` on an empty queue.
- `isEmpty()`, `numQueued()`, `numVacant()` and `reset()` are unsynchronized.

This queue is used by the engine, UI publish thread, front-panel threads, and track playback threads. It is a systemic race/hang risk.

Recommendation: use a single mutex for all queue access, `_cond.wait(lock, predicate)`, honor the timeout with `wait_for`, and make all size queries lock. Add a bounded/`try_push` policy for real-time producers.

### C5. Thread shutdown and restart are unreliable — High

Evidence:
- `Source/Application/modules/Common/Os/CrossPlatform/CThread.cpp:8-21` — `_started` is never set; a second `startThread()` on a running thread assigns to a joinable `std::thread`, which calls `std::terminate`.
- `:40-44` and the destructor unconditionally join. Several threads loop forever (`IgniteEngine::engineThreadFunc` at `IgniteEngine.cpp:295-323`, `UiInterface::run`, front-panel threads), so shutdown can hang.
- `IgniteEngine` has no destructor that signals the engine thread to stop.
- `WatchDogService`/`UiInterface` use infinite loops with blocking queue reads and no cancellation.

Recommendation: add explicit stop flags/atomic cancellation, stop queues before joining, and use `std::jthread`/`stop_token` or a documented `stop()` protocol. Set `_started = true` and reject double starts.

### C6. Rule-of-Five violations on owned raw pointers — High

These classes own `new`-allocated data through raw pointers but default the copy assignment:

- `Track& operator=(const Track&) = default;` — `Source/Application/modules/Common/Modules/Track.h:157`
- `Pattern& operator=(const Pattern&) = default;` — `Pattern.h:38`
- `Bar& operator=(const Bar&) = default;` — `Bar.h:61`
- `Step& operator=(const Step&) = default;` — `Step.h:126`
- `Scene& operator=(const Scene&) = default;` — `Source/Application/modules/Common/Modules/Scene.h:22`
- `CSong& operator=(const CSong&) = default;` — `CSong.h:20`
- `Instrument& operator=(const Instrument&) = default;` — `Instrument.h:27`

A default assignment shallow-copies the owned pointer. Any later destruction frees the same object twice. This is a latent double-free across the model layer.

Recommendation: delete copy assignment, implement deep copy consistently, or replace owning raw pointers with `std::unique_ptr` and define the copy/move operations explicitly.

### C7. Pattern last-step ID is inconsistent/off by one — Medium

Evidence:
- `Source/Application/modules/Common/Modules/Pattern.cpp:43` sets `(bars * 16) - 1`.
- `:62` overwrites it with `numBars * 16`.
- UI code expects `(num_bars * 16) - 1` (`mt_ignite_pattern_list.cpp:551`), and other manager paths set `getTotalSteps() - 1`.

Recommendation: define one invariant and use it everywhere. If `patternLastStepId` is the last valid index, always store `totalSteps - 1`.

### C8. Project/XML values are not validated — Medium

Evidence:
- `Source/Application/modules/Firmware/Application/Model/EngineFileHandler.cpp:676` casts `numberOfTracks` to `uint8_t`; `Scene.cpp:37` and `:121` loop with `int8_t`. Values above 127 can cause signed overflow/infinite loops.
- `songData.numberOfScenes` is an unchecked `int32_t` used to create scene objects (`EngineFileHandler.cpp:502`).
- `sceneData.sceneTempo` is parsed with `getIntAttribute` (`EngineFileHandler.cpp:679`), truncating fractional BPM.
- Pattern `timeBase` is not range-checked; an invalid value makes `getTicksPerStep()` return 0 (`Pattern.cpp:27-30`), leading to division by zero in `Track.cpp:2424`.

Recommendation: parse into bounded integer types, reject out-of-range values, check file versions, and validate all object counts against hard limits before construction.

### C9. Firmware version parsing reads uninitialized memory — Medium

Evidence: `Source/Application/modules/Firmware/Application/Model/FrontPannelManager.cpp:2181-2206`.

`versionBytes[20]` is uninitialized, `file.read(..., 20)` may read fewer bytes, and `std::string(versionBytes, 20)` then reads the full 20 bytes regardless of `gcount()`. `getFirmwareInfo()` also writes `imxFirmwareVersion[2]` without checking the string length (`:2602`), and `str.erase(0, 18)` can throw on short lines.

Recommendation: zero-initialize the buffer, use `gcount()`, validate the length before constructing strings, and bound all `erase()` calls.

### C10. `EngineFileHandler::SetSystemStatus` checks the wrong path — Low/Medium

Evidence: `Source/Application/modules/Firmware/Application/Model/EngineFileHandler.cpp:151-153` checks `exists(root_work_path / ...)` but writes `root_path / ...`.

Recommendation: use the same path for the existence check and the write, and check that the output stream opened successfully.

### C11. Shell/runtime issues in the device image — Medium

- `Linux/.../rootfs_overlay/usr/bin/hostUsbMount.sh:4-5` uses `$21`. With udev passing `%k` (for example `sda1`), this produces the wrong device path (`/dev/sda11`); the USB auto-mount used by firmware update may fail.
- `Linux/.../rootfs_overlay/usr/bin/create-usb-gadgets.sh:21-28` still starts `/usr/bin/pcmode` and waits for `/dev/usb-utp0/ep1`. The README says `pcmode` was removed, so this service will block and the following MIDI/mass-storage setup will not run.
- `Source/Application/modules/Firmware/Application/Model/FrontPannelManager.cpp:60` calls `/usr/bin/hostUsbMount.sh` with no device argument; the unmount path only uses `/mnt/flash`, so this specific call is less affected.

### C12. Latent protocol defects in unused code — Medium

`ComProtocol` is not referenced by the application, but it is published as the hardware protocol:

- `ComProtocol/PktMgr/PktMgr.cpp:104-115` writes up to 255 bytes into a receive FIFO whose actual capacity is not checked (the class declares a 30-byte buffer).
- `PktMgr.cpp:134-146` pops without bounds checks.
- The state machine does not return to `EN_FRM_STATE_INIT_1` after CRC; the static receive vector is never reset by `Init()`/`ClearReceiver()`.

`CSysexHandler` is also currently unreferenced on Linux, but has a real overflow: `CSysexHandler.cpp:77-89` copies up to `len` bytes into `IgniteMessage::messageData[50]`, and `createSysexMessage()` copies `data[i]` starting at index 9 instead of index 0.

Recommendation: fix or remove. Do not publish a protocol implementation that is not integration-tested.

## Build, packaging, and maintainability findings

### B1. Documented Linux dependencies are incomplete

The build needs these that are missing from the README/CI package list on Ubuntu 24.04:
- `libxi-dev` for `X11/extensions/XInput2.h`
- `libiw-dev` for `iwlib.h`

The first full build failed at exactly those two headers. See [build-and-setup.md](build-and-setup.md) for the full tested package list.

`libwebkit2gtk-4.0-dev` is listed in the README/CI script but is not required for this configuration and is not available under that name on Ubuntu 24.04. CMake warns about `webkit2gtk-4.0` and `gtk+-x11-3.0` not being found but still completes, because the target defines `JUCE_WEB_BROWSER=0`.

### B2. Every build re-runs CMake

`Source/Application/timestamp/CMakeLists.txt` adds a `clear_cache` target that removes `BUILD_TIME` from the CMake cache on every build. `timestamp` depends on it. As a result, `cmake --build` re-runs configure, re-checks/downloads JUCE, and rebuilds `timestamp` every time. This is intentional for compile-time timestamping but is a significant iteration-speed cost.

Recommendation: document this behaviour, or replace it with a build-time generated header that does not force a reconfigure.

### B3. Warnings are disabled globally

`Source/Application/CMakeLists.txt:74` adds:

```cmake
-w -Wno-unknown-pragmas -ffast-math -Ofast
```

This hides exactly the classes of defects found above. Use target-specific warning flags, keep `-Wall -Wextra` enabled, and reserve `-Ofast`/`-ffast-math` for vetted DSP code only.

### B4. In-source build paths and CI

- `Source/Application/CMakeLists.txt:86` sets `CMAKE_RUNTIME_OUTPUT_DIRECTORY` to the source tree.
- `Source/CI/azure_build.sh` uses `cmake ./` and `make` in-source.
- `Source/CI/azure-app-pipeline.yaml` refers to internal branches (`ui_dev`) and an internal `Source` repository.

Recommendation: use out-of-source builds everywhere (`cmake -S Source/Application -B build`) and publish a GitHub Actions workflow driven by environment variables rather than internal repository names.

### B5. Unity-style `.cpp` includes

Module implementations are concatenated by including `.cpp` files from module `.cpp` files (for example `Source/Application/modules/Common/Common.cpp` and `Source/Application/modules/Firmware/Firmware.cpp`). This prevents parallel compilation, creates very large translation units, and can leak `using namespace` directives and macros across files.

Recommendation: list source files in CMake and compile them as separate translation units.

### B6. Module metadata is copy-pasted

The JUCE module declarations contain duplicate/wrong IDs:

- `Common/Common.h` and `Firmware/Firmware.h` both say `ID: ignite_ui`.
- `common_ui_controls/common_ui_controls.h` and `ignite_ui/ignite_ui.h` both say `ID: common_defs`.
- `hardware/hardware.h` says `ID: common`.

CMake target names are directory-based, so this is not the current build blocker, but Projucer/module dependency metadata is wrong. Correct the IDs, names, and dependency lists.

### B7. Optional VST build is not coherent

- The option is `IGNITE_VST_PLUGIN`, but `USE_VST` is set from `BUILD_VST` (`Source/Application/CMakeLists.txt:10`, `:37-42`).
- The plugin target links `ValueTreeDebugger`, but no such target is defined in this tree.
- The plugin editor reuses the same global engine ownership pattern as the main app (`ignitevst/src/PluginEditor.cpp`).

Treat the plugin as unsupported until these are fixed and tested.

### B8. No tests, no GitHub CI

There is no unit/integration test suite and no `.github/workflows` directory. The Azure definitions are internal and are not a substitute for reproducible public CI. Add at least:

- parser tests for `PktMgr`, sysex, MCU messages, and XML loaders;
- lifetime/copy tests for `Track`, `Pattern`, `Scene`, `CSong`;
- queue/thread stress tests;
- ASan, UBSan, and TSan builds;
- a smoke test that starts the app headlessly with a test SoundFont.

### B9. Licensing headers are inconsistent

Only about half of the application module files carry the AGPL SPDX header. Add `SPDX-License-Identifier: AGPL-3.0-or-later` and the copyright notice to all first-party files.

### B10. SoundFont path mismatch

`Source/Application/apps/ignite/CMakeLists.txt` copies `Source/Application/sf/Ignite.sf2` next to the build artifact, but `ModelParams.h` loads `/app/Ignite.sf2` on Linux. A desktop build needs the SoundFont at `/app/Ignite.sf2`, not next to the binary.

Recommendation: either make the path relative to the executable/assets directory on desktop, or document the `/app` requirement clearly. See [build-and-setup.md](build-and-setup.md).

## What is good

- Clear separation of UI, engine/model, common sequencing primitives, and hardware integration.
- The repository and third-party license documentation is better than typical for a hardware project.
- The feature model (song/scene/track/pattern/instrument) is coherent and consistently named.
- Many manager objects use `std::unique_ptr`; the problematic ownership is concentrated in model objects, not everywhere.
- The hardware protocol and screen layout constants are centralized.

## Recommended remediation order

1. **Remove/secure the PlayTribe TCP and USB FunctionFS command interfaces**; eliminate all shell construction from untrusted filenames.
2. **Fix the engine ownership and SoundFont null handling** (immediate crash/double-free).
3. **Fix `CMsgQueue`, `CThread`, and engine/UI shutdown.**
4. **Adopt Rule-of-Five or `unique_ptr` in `Track`/`Pattern`/`Bar`/`Step`/`Scene`/`CSong`/`Instrument`.**
5. **Harden all parsers** (MCU, XML, firmware headers, UDP/TCP).
6. **Add sanitizer and smoke-test CI**, then address build hygiene (`-w`, unity `.cpp` includes, in-source CI, module metadata).
