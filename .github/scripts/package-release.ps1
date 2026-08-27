$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path
New-Item -ItemType Directory -Force -Path release | Out-Null
cmake --preset msvc-x64-release
cmake --build --preset x64-release --target dinput8
cmake -S . -B build/x86-release -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build/x86-release --target dinput8
Compress-Archive -Path build/x64-release/dinput8.dll -DestinationPath release/ffb-proxy-x64.zip -Force
Compress-Archive -Path build/x86-release/dinput8.dll -DestinationPath release/ffb-proxy-x86.zip -Force
Push-Location viewer
python -m pip install pyinstaller
uv run pyinstaller --noconfirm --clean --onedir --name ffb-viewer src/ffb_visualizer/main.py
Compress-Archive -Path dist/ffb-viewer -DestinationPath ../release/ffb-viewer-x64.zip -Force
Pop-Location
Get-ChildItem release -File | Get-FileHash -Algorithm SHA256 | ForEach-Object { "$($_.Hash)  $($_.Path.Substring($root.Length + 1))" } | Set-Content release/SHA256SUMS
