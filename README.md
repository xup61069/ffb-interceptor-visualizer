# FFB Interceptor + Visualizer

FFB Interceptor is an **unsigned experimental** Windows tool that observes
Force-Feedback commands sent through DirectInput8 and displays their command
parameters in a live viewer. It forwards every DirectInput call and HRESULT
unchanged. A graph labelled **Command Peak/RMS** describes the selected API
channel; it is not a measurement of motor torque.

Version 0.1.0 supports a C++17 `dinput8.dll` proxy for x86 and x64 and a
Python 3.12+ x64 PySide6/pyqtgraph viewer. The proxy is derived from
[walmis/dcs-force-feedback-fix](https://github.com/walmis/dcs-force-feedback-fix)
v0.2 (MIT) and keeps its history. New code is GPL-3.0-only.

## Scope and safety

Only DirectInput8 devices created through `DirectInput8Create` are supported.
GameInput, WinRT, XInput and private SDK paths are outside v0.1. There is no
anti-cheat bypass, online-competition feature, driver/HID hook, memory scan,
network service, SimHub plug-in, or physical torque measurement. iRacing is
explicitly unsupported as a support policy; GPL does not impose an additional
use restriction.

High-torque wheelbases can move unexpectedly. Keep hands clear, use a physical
stop, begin at minimum gain, and test offline. A game directory may already
contain another `dinput8.dll`: never overwrite it. Rename it to a backup and
restore that exact file when removing this experiment. If the game fails to
start, remove the proxy and viewer; the game then uses its normal system DLL.

## Build the proxy

Install Visual Studio 2022/2026 C++ tools, Windows SDK, CMake 3.20+, and
Ninja. From a Visual Studio developer prompt:

```powershell
cmake --preset msvc-x64-release
cmake --build --preset x64-release --target dinput8 ffb_protocol_tests ffb_wrapper_tests
cmake --preset msvc-x86-release   # run from a -arch=x86 prompt
cmake --build --preset x86-release --target dinput8
ctest --test-dir build/x64-release --output-on-failure
```

Copy the resulting `dinput8.dll` beside a game executable only after backing
up an existing proxy. The proxy lazily loads the genuine System32 DLL and
remains fail-open when the viewer is absent.

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
window, channel selector, pause and event marker controls to inspect a bounded
rolling buffer. `Export CSV`, `Export PNG` and `Save .ffbtrace` are explicit
user actions; the versioned trace contains relative time, stable in-process IDs
and redacted command fields only (never full paths, serials, account names or
host names). The raw-details pane shows the last selected command without
inventing condition-force samples.

## Protocol

Protocol v1 uses an explicit little-endian 32-byte header and a bounded,
pointer-free payload. Frames are limited to 64 KiB and eight axes. Unknown or
custom effects carry only a GUID, declared length and redacted/truncated flag.
See [docs/protocol-v1.md](docs/protocol-v1.md) and
[docs/security-model.md](docs/security-model.md). The user-triggered trace
format is documented in [docs/trace-format.md](docs/trace-format.md).

## Contributing and licence

See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), and
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). The distribution is licensed under
the [GNU GPLv3](LICENSE). The inherited upstream notice is preserved in
[`licenses/upstream-dcs-force-feedback-fix-MIT.txt`](licenses/upstream-dcs-force-feedback-fix-MIT.txt)
and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Status

v0.1.0 is a prerelease and is marked `UNSIGNED EXPERIMENTAL`. Synthetic
protocol/queue tests are the release gate. Real hardware or commercial-game
results are not compatibility claims unless accompanied by explicit
authorization and reproducible evidence.
