$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path
$releaseDirectory = Join-Path $root 'release'
if (Test-Path -LiteralPath $releaseDirectory) {
    $resolvedRelease = (Resolve-Path -LiteralPath $releaseDirectory).Path
    if ([System.IO.Path]::GetFullPath($resolvedRelease) -ne [System.IO.Path]::GetFullPath($releaseDirectory)) {
        throw "Refusing to replace unexpected release directory: $resolvedRelease"
    }
    Remove-Item -LiteralPath $releaseDirectory -Recurse -Force
}
New-Item -ItemType Directory -Path $releaseDirectory | Out-Null
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
uv run cyclonedx-py environment --pyproject pyproject.toml --output-reproducible -o ../release/sbom.cdx.json
Compress-Archive -Path dist/ffb-viewer -DestinationPath ../release/ffb-viewer-x64.zip -Force
Pop-Location
if (-not $env:RELEASE_TAG) { $env:RELEASE_TAG = 'local' }
$archiveRef = if ($env:RELEASE_TAG -eq 'local') { 'HEAD' } else { $env:RELEASE_TAG }
git archive --format=zip --output="release/ffb-interceptor-visualizer-$($env:RELEASE_TAG)-source.zip" $archiveRef
$checksums = Get-ChildItem release -File |
    Get-FileHash -Algorithm SHA256 |
    ForEach-Object { "$($_.Hash)  $([System.IO.Path]::GetFileName($_.Path))" }
[System.IO.File]::WriteAllLines(
    (Join-Path $root 'release/SHA256SUMS'),
    $checksums,
    [System.Text.UTF8Encoding]::new($false))
