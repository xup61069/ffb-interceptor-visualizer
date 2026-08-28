# SPDX-License-Identifier: GPL-3.0-only
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
$stageRoot = Join-Path $releaseDirectory '_stage'
New-Item -ItemType Directory -Path $stageRoot | Out-Null

function Add-ReleaseNotices {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination (Join-Path $Destination 'LICENSE')
    Copy-Item -LiteralPath (Join-Path $root 'THIRD_PARTY_NOTICES.md') -Destination (Join-Path $Destination 'THIRD_PARTY_NOTICES.md')
    Copy-Item -LiteralPath (Join-Path $root 'README.md') -Destination (Join-Path $Destination 'README.md')
    Copy-Item -LiteralPath (Join-Path $root 'README.zh-TW.md') -Destination (Join-Path $Destination 'README.zh-TW.md')
    $licenseDirectory = Join-Path $Destination 'licenses'
    New-Item -ItemType Directory -Path $licenseDirectory | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'licenses/upstream-dcs-force-feedback-fix-MIT.txt') -Destination $licenseDirectory
}

function Assert-ZipEntries {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Archive,
        [Parameter(Mandatory = $true)]
        [string[]]$RequiredEntries
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archivePath = [System.IO.Path]::GetFullPath((Join-Path $root $Archive))
    $zip = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        $entryNames = @($zip.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
        foreach ($entry in $RequiredEntries) {
            if ($entryNames -notcontains $entry) {
                throw "Archive $Archive is missing required entry: $entry"
            }
        }
    }
    finally {
        $zip.Dispose()
    }
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vsroot = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$devcmd = Join-Path $vsroot 'Common7/Tools/VsDevCmd.bat'
cmd.exe /d /c "call `"$devcmd`" -arch=x64 >nul && cmake --preset msvc-x64-release && cmake --build --preset x64-release --target dinput8"
cmd.exe /d /c "call `"$devcmd`" -arch=x86 >nul && cmake -S . -B build/x86-release -G Ninja -DCMAKE_BUILD_TYPE=Release && cmake --build build/x86-release --target dinput8"
$proxyX64Stage = Join-Path $stageRoot 'ffb-proxy-x64'
$proxyX86Stage = Join-Path $stageRoot 'ffb-proxy-x86'
New-Item -ItemType Directory -Path $proxyX64Stage, $proxyX86Stage | Out-Null
Copy-Item -LiteralPath build/x64-release/dinput8.dll -Destination $proxyX64Stage
Copy-Item -LiteralPath build/x86-release/dinput8.dll -Destination $proxyX86Stage
Add-ReleaseNotices -Destination $proxyX64Stage
Add-ReleaseNotices -Destination $proxyX86Stage
Compress-Archive -Path (Join-Path $proxyX64Stage '*') -DestinationPath release/ffb-proxy-x64.zip -Force
Compress-Archive -Path (Join-Path $proxyX86Stage '*') -DestinationPath release/ffb-proxy-x86.zip -Force
$proxyEntries = @(
    'dinput8.dll',
    'LICENSE',
    'README.md',
    'README.zh-TW.md',
    'THIRD_PARTY_NOTICES.md',
    'licenses/upstream-dcs-force-feedback-fix-MIT.txt'
)
Assert-ZipEntries -Archive 'release/ffb-proxy-x64.zip' -RequiredEntries $proxyEntries
Assert-ZipEntries -Archive 'release/ffb-proxy-x86.zip' -RequiredEntries $proxyEntries
Push-Location viewer
uv sync --extra dev
$previousPath = $env:PATH
$system32 = [System.IO.Path]::GetFullPath((Join-Path $env:SystemRoot 'System32')).TrimEnd('\\')
$safePathEntries = foreach ($entry in $previousPath -split ';') {
    if ([string]::IsNullOrWhiteSpace($entry)) {
        continue
    }
    $isSystem32 = [System.IO.Path]::GetFullPath($entry).TrimEnd('\\') -ieq $system32
    if ($isSystem32 -or -not (Test-Path (Join-Path $entry 'icuuc.dll'))) {
        $entry
    }
}
try {
    # Avoid bundling an unrelated ICU DLL exposed by the build host's PATH.
    $env:PATH = [string]::Join(';', $safePathEntries)
    uv run pyinstaller --noconfirm --clean --onedir --name ffb-viewer --paths src pyinstaller_entry.py
}
finally {
    $env:PATH = $previousPath
}
$viewerInternal = Join-Path (Get-Location) 'dist/ffb-viewer/_internal'
if (Get-ChildItem -LiteralPath $viewerInternal -File -Filter 'icu*.dll') {
    throw 'Refusing to package host-provided ICU DLLs with the viewer.'
}
$viewerDist = Join-Path (Get-Location) 'dist/ffb-viewer'
Add-ReleaseNotices -Destination $viewerDist
$previousQtPlatform = $env:QT_QPA_PLATFORM
try {
    $env:QT_QPA_PLATFORM = 'offscreen'
    $viewerProcess = Start-Process -FilePath (Join-Path (Get-Location) 'dist/ffb-viewer/ffb-viewer.exe') -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 2
    if ($viewerProcess.HasExited) {
        throw "Packaged viewer exited during smoke test with code $($viewerProcess.ExitCode)."
    }
    Stop-Process -Id $viewerProcess.Id -ErrorAction Stop
    $viewerProcess.WaitForExit()
}
finally {
    if ($null -eq $previousQtPlatform) {
        Remove-Item Env:QT_QPA_PLATFORM -ErrorAction SilentlyContinue
    }
    else {
        $env:QT_QPA_PLATFORM = $previousQtPlatform
    }
}
uv run cyclonedx-py environment --pyproject pyproject.toml --output-reproducible -o ../release/sbom.cdx.json
uv run python ../.github/scripts/generate-spdx-sbom.py --pyproject pyproject.toml --output ../release/sbom.spdx.json
Compress-Archive -Path dist/ffb-viewer -DestinationPath ../release/ffb-viewer-x64.zip -Force
Pop-Location
Assert-ZipEntries -Archive 'release/ffb-viewer-x64.zip' -RequiredEntries @(
    'ffb-viewer/ffb-viewer.exe',
    'ffb-viewer/LICENSE',
    'ffb-viewer/README.md',
    'ffb-viewer/README.zh-TW.md',
    'ffb-viewer/THIRD_PARTY_NOTICES.md',
    'ffb-viewer/licenses/upstream-dcs-force-feedback-fix-MIT.txt'
)
Remove-Item -LiteralPath $stageRoot -Recurse -Force
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
