$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path
New-Item -ItemType Directory -Force -Path release | Out-Null
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vsroot = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$devcmd = Join-Path $vsroot 'Common7/Tools/VsDevCmd.bat'
cmd.exe /d /c "call `"$devcmd`" -arch=x64 >nul && cmake --preset msvc-x64-release && cmake --build --preset x64-release --target dinput8"
cmd.exe /d /c "call `"$devcmd`" -arch=x86 >nul && cmake -S . -B build/x86-release -G Ninja -DCMAKE_BUILD_TYPE=Release && cmake --build build/x86-release --target dinput8"
Compress-Archive -Path build/x64-release/dinput8.dll -DestinationPath release/ffb-proxy-x64.zip -Force
Compress-Archive -Path build/x86-release/dinput8.dll -DestinationPath release/ffb-proxy-x86.zip -Force
Push-Location viewer
uv sync --extra dev
uv run pyinstaller --noconfirm --clean --onedir --name ffb-viewer src/ffb_visualizer/main.py
Compress-Archive -Path dist/ffb-viewer -DestinationPath ../release/ffb-viewer-x64.zip -Force
Pop-Location
Get-ChildItem release -File | Get-FileHash -Algorithm SHA256 | ForEach-Object { "$($_.Hash)  $($_.Path.Substring($root.Length + 1))" } | Set-Content release/SHA256SUMS
