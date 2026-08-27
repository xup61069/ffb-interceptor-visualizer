# FFB Interceptor Viewer

The viewer is a Windows x64 PySide6 application for the `ffb-interceptor-v1`
named pipe. It displays commands and effect parameters sent through
DirectInput8. It does **not** measure wheel torque or synthesize a force.

```powershell
uv sync --extra dev
uv run ffb-viewer
```

Data is held in memory by default. Export actions are explicit and write only
relative timestamps, executable basename, and stable in-process IDs.

SPDX-License-Identifier: GPL-3.0-only
