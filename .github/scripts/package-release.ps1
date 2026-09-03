# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [string]$SigningCertificateThumbprint = $env:FFB_SIGNING_CERT_SHA1,
    [string]$TimestampUrl = 'http://timestamp.digicert.com',
    [string]$VisualStudioInstallPath = '',
    [string]$ToolchainX64Path = '',
    [string]$ToolchainX64Sha256 = '',
    [string]$ToolchainX86Path = '',
    [string]$ToolchainX86Sha256 = '',
    [string]$ReleaseTag = $env:RELEASE_TAG,
    [string]$ExpectedCommitSha = '',
    [switch]$RequireSigning
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ReleaseTag)) { $ReleaseTag = 'local' }
if ($ReleaseTag -cne 'local' -and
    $ReleaseTag -cnotmatch '^v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\z') {
    throw 'ReleaseTag must be local or a canonical vX.Y.Z tag.'
}

function Resolve-GitCommit {
    param([Parameter(Mandatory = $true)][string]$Revision)

    $lines = @(& git rev-parse --verify "$Revision`^{commit}" 2>$null)
    if ($LASTEXITCODE -ne 0 -or $lines.Count -ne 1) {
        throw "Unable to resolve exactly one Git commit for revision: $Revision"
    }
    $commit = $lines[0].Trim().ToLowerInvariant()
    if ($commit -cnotmatch '^[0-9a-f]{40}\z') {
        throw "Git revision did not resolve to a full commit SHA: $Revision"
    }
    return $commit
}

$sourceCommit = Resolve-GitCommit -Revision 'HEAD'
if (-not [string]::IsNullOrWhiteSpace($ExpectedCommitSha)) {
    if ($ExpectedCommitSha -cnotmatch '^[0-9A-Fa-f]{40}\z' -or
        $sourceCommit -cne $ExpectedCommitSha.ToLowerInvariant()) {
        throw 'Package source HEAD does not match the expected release commit.'
    }
}
if ($ReleaseTag -cne 'local' -and
    (Resolve-GitCommit -Revision $ReleaseTag) -cne $sourceCommit) {
    throw 'Release tag does not resolve to the package source commit.'
}
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

function Invoke-CheckedNativeCommand {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Command,
        [Parameter(Mandatory = $true)][string]$FailureMessage
    )

    & $Command
    $nativeExitCode = $LASTEXITCODE
    if ($nativeExitCode -ne 0) {
        throw "$FailureMessage (exit $nativeExitCode)."
    }
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

function Resolve-ToolchainSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Sha256,
        [Parameter(Mandatory = $true)]
        [string]$Architecture
    )

    if ($Sha256 -cnotmatch '^[A-F0-9]{64}$') {
        throw "$Architecture toolchain snapshot requires an uppercase SHA-256 pin."
    }
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $safePattern = '^C:\\ffb-v1-[0-9a-f]{32}\\Toolchain\\' +
        [regex]::Escape($Architecture) + '\.cmd\z'
    if ($resolved -notmatch $safePattern -or
        $resolved.IndexOfAny([char[]]'%!^&|<>') -ge 0) {
        throw "$Architecture toolchain snapshot is outside its bound disposable runtime path."
    }
    if ([IO.Path]::GetExtension($resolved) -cne '.cmd') {
        throw "$Architecture toolchain snapshot must be a .cmd file."
    }
    $item = Get-Item -LiteralPath $resolved -Force
    $toolchainDirectory = Get-Item -LiteralPath ([IO.Path]::GetDirectoryName($resolved)) -Force
    $runtimeDirectory = Get-Item -LiteralPath $toolchainDirectory.Parent.FullName -Force
    foreach ($entry in @($item, $toolchainDirectory, $runtimeDirectory)) {
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Architecture toolchain snapshot path must not contain a reparse point."
        }
    }
    if (($item.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) {
        throw "$Architecture toolchain snapshot must rely on ACL isolation, not a DOS read-only attribute."
    }
    if ((Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash -cne $Sha256) {
        throw "$Architecture toolchain snapshot failed SHA-256 verification."
    }
    $lines = [IO.File]::ReadAllLines($resolved)
    if ($lines.Count -lt 2 -or $lines[0] -cne '@echo off') {
        throw "$Architecture toolchain snapshot has an invalid header."
    }
    $allowedNames = @(
        'CommandPromptType', 'DevEnvDir', 'ExtensionSdkDir', 'FrameworkDir',
        'FrameworkDir32', 'FrameworkVersion', 'FrameworkVersion32', 'INCLUDE', 'LIB',
        'LIBPATH', 'NETFXSDKDir', 'PATH', 'UCRTVersion', 'UniversalCRTSdkDir',
        'VCIDEInstallDir', 'VCINSTALLDIR', 'VCToolsInstallDir', 'VCToolsRedistDir',
        'VisualStudioVersion', 'VSINSTALLDIR', 'VSCMD_ARG_app_plat',
        'VSCMD_ARG_HOST_ARCH', 'VSCMD_ARG_TGT_ARCH', 'VSCMD_VER', 'WindowsLibPath',
        'WindowsSdkBinPath', 'WindowsSdkDir', 'WindowsSDKLibVersion', 'WindowsSDKVersion'
    )
    $values = [Collections.Generic.Dictionary[string,string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $lines[1..($lines.Count - 1)]) {
        if ($line.IndexOfAny([char[]]'%!^&|<>') -ge 0 -or
            $line -cnotmatch '^set "(?<name>[A-Za-z_][A-Za-z0-9_()]*)=(?<value>[^"\r\n]*)"\z' -or
            $allowedNames -notcontains $Matches.name -or
            -not $values.TryAdd($Matches.name, $Matches.value)) {
            throw "$Architecture toolchain snapshot contains an unsafe or duplicate command."
        }
    }
    foreach ($requiredName in @(
        'PATH', 'INCLUDE', 'LIB', 'LIBPATH', 'VCINSTALLDIR', 'VCToolsInstallDir',
        'VSINSTALLDIR', 'WindowsSdkDir', 'VSCMD_ARG_HOST_ARCH', 'VSCMD_ARG_TGT_ARCH'
    )) {
        if (-not $values.ContainsKey($requiredName) -or
            [string]::IsNullOrWhiteSpace($values[$requiredName])) {
            throw "$Architecture toolchain snapshot is missing $requiredName."
        }
    }
    if ($values['VSCMD_ARG_TGT_ARCH'] -cne $Architecture -or
        $values['VSCMD_ARG_HOST_ARCH'] -cne 'x64') {
        throw "$Architecture toolchain snapshot does not bind the expected host/target architecture."
    }
    $writeStream = $null
    $fileWriteDenied = $false
    try {
        $writeStream = [IO.File]::Open($resolved, [IO.FileMode]::Open,
            [IO.FileAccess]::Write, [IO.FileShare]::Read)
    }
    catch [UnauthorizedAccessException] { $fileWriteDenied = $true }
    finally { if ($writeStream) { $writeStream.Dispose() } }
    if (-not $fileWriteDenied) {
        throw "$Architecture toolchain snapshot is writable by the release job."
    }
    $probePath = Join-Path $toolchainDirectory.FullName `
        ('.ffb-directory-write-probe-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $probeStream = $null
    $directoryWriteDenied = $false
    try {
        $probeStream = [IO.File]::Open($probePath, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
    }
    catch [UnauthorizedAccessException] { $directoryWriteDenied = $true }
    finally {
        if ($probeStream) { $probeStream.Dispose() }
        if (Test-Path -LiteralPath $probePath) {
            Remove-Item -LiteralPath $probePath -Force
        }
    }
    if (-not $directoryWriteDenied) {
        throw "$Architecture toolchain snapshot directory is writable by the release job."
    }
    return $resolved
}

$snapshotValues = @($ToolchainX64Path, $ToolchainX64Sha256, $ToolchainX86Path, $ToolchainX86Sha256)
$useSnapshots = @($snapshotValues | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0
if ($useSnapshots -and @($snapshotValues | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
    throw 'Both x64 and x86 toolchain snapshot paths and SHA-256 pins are required together.'
}

if ($useSnapshots) {
    $toolchainX64 = Resolve-ToolchainSnapshot -Path $ToolchainX64Path `
        -Sha256 $ToolchainX64Sha256 -Architecture 'x64'
    $toolchainX86 = Resolve-ToolchainSnapshot -Path $ToolchainX86Path `
        -Sha256 $ToolchainX86Sha256 -Architecture 'x86'
    $runtimeX64 = [IO.Directory]::GetParent([IO.Path]::GetDirectoryName($toolchainX64)).FullName
    $runtimeX86 = [IO.Directory]::GetParent([IO.Path]::GetDirectoryName($toolchainX86)).FullName
    if ($toolchainX64 -ieq $toolchainX86 -or $runtimeX64 -ine $runtimeX86) {
        throw 'x64 and x86 toolchain snapshots must be distinct files in one disposable runtime.'
    }
    $expectedSimHubPath = [IO.Path]::Combine($runtimeX64, 'Sdk')
    $actualSimHubPath = (Resolve-Path -LiteralPath $env:SIMHUB_INSTALL_PATH -ErrorAction Stop).Path
    if ($actualSimHubPath -ine $expectedSimHubPath) {
        throw 'The SimHub SDK snapshot is not bound to the toolchain disposable runtime.'
    }
    $runnerTemp = (Resolve-Path -LiteralPath $env:RUNNER_TEMP -ErrorAction Stop).Path.TrimEnd('\')
    $runtimePrefix = $runtimeX64.TrimEnd('\') + '\'
    if (-not $runnerTemp.StartsWith($runtimePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'RUNNER_TEMP is outside the toolchain disposable runtime.'
    }
    foreach ($boundPath in @($expectedSimHubPath, $runnerTemp)) {
        $current = $runtimeX64
        $relative = $boundPath.Substring($runtimeX64.Length).TrimStart('\')
        foreach ($segment in @($relative -split '\\' | Where-Object { $_ })) {
            $current = Join-Path $current $segment
            if (((Get-Item -LiteralPath $current -Force).Attributes -band
                    [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Bound disposable runtime path contains a reparse point: $current"
            }
        }
    }
}
else {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    if ([string]::IsNullOrWhiteSpace($VisualStudioInstallPath)) {
        $vsroot = & $vswhere -latest -products * `
            -version '[17.0,18.0)' `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($vsroot)) {
            throw 'Visual Studio C++ tools were not found.'
        }
    }
    else {
        $vsroot = (Resolve-Path -LiteralPath $VisualStudioInstallPath -ErrorAction Stop).Path
    }
    $devcmd = Join-Path $vsroot 'Common7/Tools/VsDevCmd.bat'
    if (-not (Test-Path -LiteralPath $devcmd -PathType Leaf)) {
        throw 'Visual Studio developer command script was not found.'
    }
    $toolchainX64 = $devcmd
    $toolchainX86 = $devcmd
}
$x64Arguments = if ($useSnapshots) { '' } else { ' -arch=x64 >nul' }
$x86Arguments = if ($useSnapshots) { '' } else { ' -arch=x86 >nul' }
cmd.exe /d /c "call `"$toolchainX64`"$x64Arguments && cmake --preset msvc-x64-release && cmake --build --preset x64-release --target dinput8"
if ($LASTEXITCODE -ne 0) { throw 'x64 proxy build failed.' }
cmd.exe /d /c "call `"$toolchainX86`"$x86Arguments && cmake -S . -B build/x86-release -G Ninja -DCMAKE_BUILD_TYPE=Release && cmake --build build/x86-release --target dinput8"
if ($LASTEXITCODE -ne 0) { throw 'x86 proxy build failed.' }
$proxyX64Stage = Join-Path $stageRoot 'ffb-proxy-x64'
$proxyX86Stage = Join-Path $stageRoot 'ffb-proxy-x86'
New-Item -ItemType Directory -Path $proxyX64Stage, $proxyX86Stage | Out-Null
Copy-Item -LiteralPath build/x64-release/dinput8.dll -Destination $proxyX64Stage
Copy-Item -LiteralPath build/x86-release/dinput8.dll -Destination $proxyX86Stage
Add-ReleaseNotices -Destination $proxyX64Stage
Add-ReleaseNotices -Destination $proxyX86Stage
$proxySigningArguments = @{
    Paths = @(
        (Join-Path $proxyX64Stage 'dinput8.dll'),
        (Join-Path $proxyX86Stage 'dinput8.dll')
    )
    CertificateThumbprint = $SigningCertificateThumbprint
    TimestampUrl = $TimestampUrl
}
if ($RequireSigning) { $proxySigningArguments.RequireSigning = $true }
& (Join-Path $root '.github\scripts\sign-windows-artifacts.ps1') @proxySigningArguments
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
try {
    uv sync --locked --extra dev
    if ($LASTEXITCODE -ne 0) { throw 'Locked viewer environment restore failed.' }
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
        Invoke-CheckedNativeCommand -FailureMessage 'Packaged viewer build failed' -Command {
            uv run pyinstaller --noconfirm --clean --onedir --name ffb-viewer --paths src pyinstaller_entry.py
        }
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
    $viewerSigningArguments = @{
        Paths = @((Join-Path $viewerDist 'ffb-viewer.exe'))
        CertificateThumbprint = $SigningCertificateThumbprint
        TimestampUrl = $TimestampUrl
    }
    if ($RequireSigning) { $viewerSigningArguments.RequireSigning = $true }
    & (Join-Path $root '.github\scripts\sign-windows-artifacts.ps1') @viewerSigningArguments
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
    uv run cyclonedx-py environment --pyproject pyproject.toml --output-reproducible `
        -o ../release/python-environment.cdx.json
    if ($LASTEXITCODE -ne 0) { throw 'Python CycloneDX SBOM generation failed.' }
    uv run python ../.github/scripts/generate-spdx-sbom.py --pyproject pyproject.toml `
        --output ../release/python-environment.spdx.json
    if ($LASTEXITCODE -ne 0) { throw 'Python SPDX SBOM generation failed.' }
    Compress-Archive -Path dist/ffb-viewer -DestinationPath ../release/ffb-viewer-x64.zip -Force
}
finally {
    Pop-Location
}
uv run --project viewer python .github/scripts/generate-component-sbom.py `
    --cyclonedx release/sbom.cdx.json --spdx release/sbom.spdx.json
if ($LASTEXITCODE -ne 0) { throw 'Repository component SBOM generation failed.' }
Assert-ZipEntries -Archive 'release/ffb-viewer-x64.zip' -RequiredEntries @(
    'ffb-viewer/ffb-viewer.exe',
    'ffb-viewer/LICENSE',
    'ffb-viewer/README.md',
    'ffb-viewer/README.zh-TW.md',
    'ffb-viewer/THIRD_PARTY_NOTICES.md',
    'ffb-viewer/licenses/upstream-dcs-force-feedback-fix-MIT.txt'
)
Remove-Item -LiteralPath $stageRoot -Recurse -Force
$sourceArchiveName = "ffb-interceptor-visualizer-$ReleaseTag-source.zip"
$resolvedReleaseRoot = (Resolve-Path -LiteralPath $releaseDirectory -ErrorAction Stop).Path
$sourceArchivePath = [IO.Path]::GetFullPath((Join-Path $resolvedReleaseRoot $sourceArchiveName))
if ([IO.Path]::GetDirectoryName($sourceArchivePath) -ine $resolvedReleaseRoot) {
    throw 'Source archive output escaped the release directory.'
}
if ((Resolve-GitCommit -Revision 'HEAD') -cne $sourceCommit) {
    throw 'Package source HEAD changed while building release assets.'
}
if ($ReleaseTag -cne 'local' -and
    (Resolve-GitCommit -Revision $ReleaseTag) -cne $sourceCommit) {
    throw 'Release tag changed while building release assets.'
}
git archive --format=zip "--output=$sourceArchivePath" $sourceCommit
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $sourceArchivePath -PathType Leaf)) {
    throw "Source archive creation failed for commit $sourceCommit."
}
$sourceArchiveItem = Get-Item -LiteralPath $sourceArchivePath -Force
if (($sourceArchiveItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
    $sourceArchiveItem.Length -le 0) {
    throw 'Source archive output is not a nonempty regular file.'
}
if ((Resolve-GitCommit -Revision 'HEAD') -cne $sourceCommit -or
    ($ReleaseTag -cne 'local' -and
        (Resolve-GitCommit -Revision $ReleaseTag) -cne $sourceCommit)) {
    throw 'Git release bindings changed while creating the source archive.'
}
$checksums = Get-ChildItem release -File |
    Get-FileHash -Algorithm SHA256 |
    ForEach-Object { "$($_.Hash)  $([System.IO.Path]::GetFileName($_.Path))" }
[System.IO.File]::WriteAllLines(
    (Join-Path $root 'release/SHA256SUMS'),
    $checksums,
    [System.Text.UTF8Encoding]::new($false))
