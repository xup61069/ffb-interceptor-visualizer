# Contributing

Contributions are welcome for protocol compatibility, tests, documentation and
viewer usability. Please open an issue before large changes and include a
minimal synthetic reproduction. Do not submit proprietary game captures or
hardware serials.

Use CMake/Ninja for both proxy architectures and `uv sync --extra dev` for the
viewer. Before opening a pull request run:

```powershell
cmake --build --preset x64-release --target ffb_protocol_tests dinput8
ctest --test-dir build/x64-release --output-on-failure
cd viewer; uv run ruff check .; uv run ty check src; uv run pytest
.github/scripts/check-license-headers.ps1
```

Commits follow the Developer Certificate of Origin. Add a `Signed-off-by:`
trailer with the same name and email as the commit author. By contributing you
agree that your work is licensed under GPL-3.0-only, while inherited MIT files
remain under their original notice.
