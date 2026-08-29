# FFB Interceptor + Visualizer

FFB Interceptor is an **unsigned experimental** Windows tool that observes
Force-Feedback commands sent through DirectInput8 and displays their command
parameters in a live viewer. It forwards every DirectInput call and HRESULT
unchanged. A graph labelled **Command Peak/RMS** describes the selected API
channel; it is not a measurement of motor torque.

Version 0.2.0 supports a C++17 `dinput8.dll` proxy and a no-game-DLL offline
launcher/hook for x86 and x64, a Python 3.12+ x64 PySide6/pyqtgraph viewer,
and a .NET Framework 4.8 SimHub plug-in. The proxy is derived from
[walmis/dcs-force-feedback-fix](https://github.com/walmis/dcs-force-feedback-fix)
v0.2 (MIT) and keeps its history. New code is GPL-3.0-only.

## Scope and safety

Only DirectInput8 devices created through `DirectInput8Create` are supported.
GameInput, WinRT, XInput and private SDK paths are outside v0.2.0. There is no
anti-cheat bypass, online-competition feature, driver/HID hook, arbitrary
memory scan, network service, or physical torque measurement. The launcher
only parses bounded PE import data in the new child it creates. iRacing is
explicitly unsupported as a support policy; GPL does not impose an additional
use restriction.

High-torque wheelbases can move unexpectedly. Keep hands clear, use a physical
stop, begin at minimum gain, and test offline. The recommended launcher bundle
contains no `dinput8.dll` and never writes the game directory. At runtime it
loads its fixed sibling hook only into the new child it creates; it has no
existing-PID or arbitrary-DLL interface and refuses elevated or Windows-system
targets. The traditional proxy mode remains available. In that mode, never
overwrite an existing game `dinput8.dll`; preserve and restore the exact file.

## Build the Windows producers

Install Visual Studio 2022/2026 C++ tools, Windows SDK, CMake 3.20+, and
Ninja. From a Visual Studio developer prompt:

```powershell
cmake --preset msvc-x64-release
cmake --build --preset x64-release --target dinput8 ffb_hook ffb_launcher ffb_protocol_tests ffb_wrapper_tests ffb_dinput_wrapper_tests ffb_performance_tests ffb_telemetry_tests ffb_iat_hook_tests
cmake --preset msvc-x86-release   # run from a -arch=x86 prompt
cmake --build --preset x86-release --target dinput8 ffb_hook ffb_launcher ffb_protocol_tests ffb_wrapper_tests ffb_dinput_wrapper_tests ffb_performance_tests ffb_telemetry_tests ffb_iat_hook_tests
ctest --test-dir build/x64-release --output-on-failure
ctest --test-dir build/x86-release --output-on-failure
```

Copy the resulting `dinput8.dll` beside a game executable only after backing
up an existing proxy. The proxy lazily loads the genuine System32 DLL and
remains fail-open when the viewer is absent.

For the no-game-DLL mode, keep each architecture's
`FFBInterceptor.Launcher.exe` and `FFBInterceptor.Hook.dll` together, then run:

```powershell
.\FFBInterceptor.Launcher.exe --offline-only --game "C:\Games\Example\game.exe" --
```

The launcher synchronizes the child before its first entry-point instruction,
loads only the fixed sibling hook, restores its temporary in-memory breakpoint,
patches only an unmodified `dinput8.dll!DirectInput8Create` IAT pointer, and
then detaches. It does not change the game EXE or any game-directory DLL.

## Run the viewer

Windows x64 with Python 3.12+ and [uv](https://docs.astral.sh/uv/):

```powershell
cd viewer
uv sync --extra dev
uv run ffb-viewer
```

The viewer owns the multi-instance named-pipe server
`\\.\pipe\ffb-interceptor-v1`. Data stays in memory unless the user presses
an export control. Use the producer/device/effect selectors, 1/5/10/30 second
window, channel selector and condition-axis selector, pause and event marker
controls to inspect a bounded rolling buffer. The channel selector exposes all
observed Constant, Ramp and Periodic parameters plus Condition offset,
coefficient, saturation and deadband fields; a missing parameter is shown as
no sample rather than synthesized force. `Export CSV`, `Export PNG` and
`Save .ffbtrace` are explicit
user actions; the versioned trace contains relative time, stable in-process IDs
and redacted command fields only (never full paths, serials, account names or
host names). CSV exports additionally include the bounded producer basename and
process ID so device/effect IDs remain attributable when multiple producers
are selected. The raw-details pane shows the last selected command without
inventing condition-force samples.

## Build and use the SimHub plug-in

The plug-in and Python viewer coexist. The proxy or launcher hook writes to two independent
sinks: the existing `\\.\pipe\ffb-interceptor-v1` viewer pipe and
`\\.\pipe\ffb-interceptor-simhub-v1`. Each sink has its own fixed queue,
sender, drop accounting, and reconnect path, so a stalled consumer does not
back-pressure the other one.

With SimHub installed, build and package the plug-in against its local SDK:

```powershell
powershell -ExecutionPolicy Bypass -File simhub\tools\Build-SimHubPackage.ps1
```

This produces an ignored `simhub/dist/FFBInterceptor-SimHub-0.2.0.zip` without
redistributing SimHub assemblies. It includes the plug-in's two DLLs, an
800×480 dashboard, a 480×160 high-contrast overlay, and Traditional Chinese
installation instructions. See [simhub/README.md](simhub/README.md).

After building both launcher/hook architectures, build the recommended
no-game-DLL portable package with:

```powershell
powershell -ExecutionPolicy Bypass -File simhub\tools\Build-LauncherPackage.ps1
```

It produces `simhub/dist/FFBInterceptor-Launcher-0.2.0.zip`. Extract it and run
`Start-FFBInterceptor.cmd`; first use installs the SimHub plug-in and opens
SimHub, while later runs select and start the offline game. The archive is
allowlisted and hash-manifested, contains no `dinput8.dll`, and its lifecycle
test verifies install, tamper refusal, and restoration. See
[simhub/LAUNCHER.zh-TW.md](simhub/LAUNCHER.zh-TW.md).

The traditional proxy-based portable package is still built with:

```powershell
powershell -ExecutionPolicy Bypass -File simhub\tools\Build-ReadyToUsePackage.ps1
```

It produces `simhub/dist/FFBInterceptor-ReadyToUse-0.2.0.zip`. Users extract it
and run `Install-FFBInterceptor.cmd`; the installer asks for the game EXE,
chooses the matching x86/x64 proxy, preserves an existing `dinput8.dll`,
installs the SimHub plug-in, and opens both dashboard imports. The paired
uninstaller verifies its installed hashes before restoring backups. See
[simhub/PORTABLE.zh-TW.md](simhub/PORTABLE.zh-TW.md).

The default detector enters at 98%, exits below 95%, triggers after 100 ms of
continuous saturation or 5% clipped time in a trailing second, and holds the
exit for 500 ms. It detects DirectInput command saturation at
`DI_FFNOMINALMAX`; it does not claim physical motor torque. Constant, Ramp,
and Periodic effects are eligible. Condition and Custom effects are counted
but excluded from the verdict because their actual force cannot be recovered
from these parameters alone.

## Protocol

Protocol v1 uses an explicit little-endian 32-byte header and a bounded,
pointer-free payload. Frames are limited to 64 KiB and eight axes. Unknown or
custom effects carry only a GUID, declared length and redacted/truncated flag.
See [docs/protocol-v1.md](docs/protocol-v1.md) and
[docs/security-model.md](docs/security-model.md). The user-triggered trace
format is documented in [docs/trace-format.md](docs/trace-format.md).

## Verification and release provenance

The Windows CI matrix builds and tests both proxy and launcher/hook
architectures, Python 3.12/3.13, the net48 clipping core, and both dashboard
schemas. Its deterministic synthetic gates require the telemetry queue hot path
to stay below 100 microseconds p99 at 1,000+ events/second, named-pipe
ingestion below 5 milliseconds p99 at the same rate, and the Qt refresh path
to remain below a 30 FPS frame budget while its timer runs at 60 Hz. The pipe
tests use the actual current-user DACL, fragmented writes, reconnects and a
kernel-reported Hello PID check. The security workflow also scans complete Git
history with gitleaks and lints every workflow with actionlint and zizmor.

Releases are built only from an existing `vX.Y.Z` tag: CI checks out that tag,
then verifies the tag commit and both package versions before building,
archiving and attesting the assets. See [docs/release-process.md](docs/release-process.md).

## Contributing and licence

See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), and
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). The distribution is licensed under
the [GNU GPLv3](LICENSE). The inherited upstream notice is preserved in
[`licenses/upstream-dcs-force-feedback-fix-MIT.txt`](licenses/upstream-dcs-force-feedback-fix-MIT.txt)
and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Status

v0.2.0 is a prerelease and is marked `UNSIGNED EXPERIMENTAL`. Synthetic
protocol/queue tests are the release gate. Real hardware or commercial-game
results are not compatibility claims unless accompanied by explicit
authorization and reproducible evidence.
