UNSIGNED EXPERIMENTAL — command telemetry only; not motor torque.

{{TAG}} is a prerelease of FFB Interceptor + Visualizer. It observes
DirectInput8 force-feedback commands and forwards the original calls unchanged.
It does not measure wheelbase/motor torque, synthesize force, bypass anti-cheat,
or support iRacing.

Highlights:
- Runtime viewer version metadata is now checked against the CMake and package
  versions before release packaging.
- x86 and x64 `dinput8.dll` proxy builds with fail-open forwarding and a
  bounded telemetry queue.
- x64 PyInstaller one-directory viewer plus the Python 3.12+ source viewer.
- Versioned v1 little-endian pipe protocol with current-user DACL,
  `PIPE_REJECT_REMOTE_CLIENTS`, and client PID verification.
- PID-scoped device/effect selectors prevent reused process-local IDs from
  being combined across producers.
- Producer changes reset incompatible object selections, and zero sentinel IDs
  are omitted from the object lists.
- Proxy and viewer archives include the GPL, upstream MIT, third-party notices,
  and bilingual README files needed for manual installation and redistribution.
- Command-channel selection, condition-axis inspection, time-weighted Command
  Peak/RMS, trace/CSV/PNG export, and redacted custom-effect handling.
- Sender serialization failures stay fail-open and unconfirmed pipe frames are
  counted in DropNotice; malformed stream headers now close the client rather
  than resynchronizing across arbitrary bytes.
- Release packaging now has its own pinned full-history gitleaks hard gate
  and SPDX header audit before any build provenance or asset upload.
- Disconnecting with a truncated frame tail is rejected and counted as a pipe
  protocol error instead of being silently discarded.
- Client PID lookup is now fail-closed: if the kernel API is unavailable or
  fails, the Hello frame is rejected rather than accepted without binding.
- A/W wrapper construction now validates every alias allocation and preserves
  the caller-owned COM reference when unpublished wrapper cleanup falls back
  to the original interface.
- CSV exports now include bounded producer basenames and process IDs, while
  v1 traces retain an additive multi-producer basename map.
- CI validates proxy x86/x64 and viewer Python 3.12/3.13; clean-clone rebuilds
  and synthetic protocol/queue gates are required before publication.

Assets:
- `ffb-interceptor-visualizer-{{TAG}}-source.zip`
- `ffb-proxy-x86.zip`, `ffb-proxy-x64.zip`
- `ffb-viewer-x64.zip`
- `SHA256SUMS`, `sbom.cdx.json`

Release assets carry GitHub build-provenance attestations. Verify SHA-256
values before use. This is an unsigned experimental prerelease: no installer
is provided. Follow the manual install/remove and high-torque wheelbase safety
guidance in the README; never overwrite an existing `dinput8.dll` proxy.
