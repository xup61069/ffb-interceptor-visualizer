<!-- SPDX-License-Identifier: GPL-3.0-only -->
# SimHub plug-in

`FFBInterceptor.SimHub` is a .NET Framework 4.8 WPF plug-in built against the
SDK installed with SimHub. It consumes protocol v1 on
`\\.\pipe\ffb-interceptor-simhub-v1`; the Python viewer remains on its
original pipe and can run at the same time.

## Build and package

Requirements: Windows, .NET Framework 4.8 developer pack, Visual Studio
2022 or newer, and a local SimHub installation containing its Plugin SDK.

```powershell
powershell -ExecutionPolicy Bypass -File simhub\tools\Build-SimHubPackage.ps1
```

Pass `-SimHubInstallPath` when SimHub is not installed at
`C:\Program Files (x86)\SimHub`. The command builds the net48 core and tests,
compiles the adapter against the installed SDK, validates both Dash Studio
definitions, and creates `simhub/dist/FFBInterceptor-SimHub-0.2.0.zip`.
No SimHub-owned DLL is copied into the package.

For core-only CI, build and execute:

```powershell
dotnet build simhub\FFBInterceptor.Core.Tests\FFBInterceptor.Core.Tests.csproj -c Release
simhub\FFBInterceptor.Core.Tests\bin\Release\net48\FFBInterceptor.Core.Tests.exe
```

## Install

Close SimHub, copy `FFBInterceptor.SimHub.dll` and
`FFBInterceptor.Core.dll` into the SimHub installation directory, then enable
**FFB Interceptor** in the plug-in settings. Import either `.simhubdash` file
by double-clicking it. The build script never writes into the SimHub
installation automatically.

## Detector

The verdict is command saturation, not physical wheel torque. For an active
effect the detector uses:

- Constant: `abs(magnitude) / 10000`
- Ramp: `max(abs(start), abs(end)) / 10000`
- Periodic: `(abs(offset) + abs(magnitude)) / 10000`, capped at one

Condition and Custom effects are counted as unsupported but excluded from the
verdict. Their actual force depends on position, velocity, custom samples, or
device processing that protocol v1 does not observe. Effect and device gain
are published separately as an after-gain estimate; they do not suppress a
pre-gain command-clipping verdict.

Defaults are 98% enter, 95% exit, 100 ms continuous saturation or 5% clipped
time in a trailing second, and a 500 ms below-exit hold. The monitor samples
held effect state at roughly 60 Hz, so a single long-lived `SetParameters`
command still contributes elapsed time. Finite effects honor DirectInput
duration, start delay, and iteration count; pause freezes their clock while
actuator muting does not. A successful device `Unacquire` or a detected
acquisition-loss result stops cached playback state, preventing a backgrounded
game from leaving a false clipping latch; later `Start` calls can reuse the
retained effect parameters.

Start SimHub before the game so the plug-in observes a complete effect
lifecycle. If the proxy reports dropped frames, stale state is discarded and
`DataReliable` becomes false (`DATA GAP` in the bundled dashboards) for that
producer session; restart the game to establish a fresh trustworthy session.

## Properties

All names have the `FFBInterceptor.` prefix.

| Property | Meaning |
|---|---|
| `Connected`, `SourceCount` | Selected-source connection and total connected producers |
| `SelectedProcessName`, `SelectedProcessId`, `SelectedSessionId` | Selected producer identity |
| `SelectionMode`, `ManualSourceAvailable` | Automatic/manual selection state |
| `CommandLevel`, `CommandPercent` | Pre-gain eligible command level |
| `PeakCommandPercent` | Peak since plug-in start or `ResetPeak` |
| `EffectiveCommandPercent` | Command × effect gain × device gain estimate |
| `EffectGainPercent`, `DeviceGainPercent` | Selected effect/device gain |
| `AtLimit`, `IsClipping`, `AnyClipping` | Instant threshold, selected latch, and global latch |
| `DataReliable` | False after a reported telemetry gap; stale effect state is discarded |
| `ClipRatio`, `ClipPercent`, `RatioWindowMilliseconds`, `ClipWindowText` | Configured-window clipped ratio and label |
| `ClipRatio1s`, `ClipPercent1s` | Backward-compatible aliases (the window is configurable) |
| `ActiveEffectCount`, `UnsupportedEffectCount`, `LastEffectKind` | Effect diagnostics |
| `DroppedFrames`, `ProtocolErrors` | Transport/parser health |
| `StatusText`, `Definition` | Human-readable state and torque disclaimer |

`ClippingStarted`/`ClippingEnded` are global `AnyClipping` edges, so overlapping
producers emit one start when the first source clips and one end after the last
source clears. `SourceConnected`/`SourceDisconnected` are aggregate source-count
change events published only after the corresponding snapshot is visible.
Actions: `ResetPeak` and `UseAutomaticSource`.

## Source selection and security

Automatic mode selects the connected producer with the most recent activity.
Manual mode accepts a PID and optional session ID. `AnyClipping` remains an
aggregate across all connected producers regardless of the selected source.

The pipe server uses a current-user/SYSTEM DACL,
`PIPE_REJECT_REMOTE_CLIENTS`, a 32-client bound, strict frame limits, a
mandatory first `Hello`, strictly increasing per-connection sequences, and
`GetNamedPipeClientProcessId` verification. Connect/read I/O is cancellable and
all workers are joined during plug-in shutdown. A
same-user process can still send synthetic telemetry; this is not a trust or
anti-cheat boundary.
