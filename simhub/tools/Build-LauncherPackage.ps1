# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [string]$Configuration = 'Release',
    [string]$SimHubInstallPath = 'C:\Program Files (x86)\SimHub',
    [string]$LauncherX64Path = '',
    [string]$HookX64Path = '',
    [string]$LauncherX86Path = '',
    [string]$HookX86Path = '',
    [string]$ManagerX64Path = '',
    [string]$OutputDirectory = '',
    [string]$SigningCertificateThumbprint = $env:FFB_SIGNING_CERT_SHA1,
    [string]$TimestampUrl = 'http://timestamp.digicert.com',
    [switch]$RequireSigning
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Resolve-RequiredFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Description)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Description is missing: $Path" }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Assert-ChildPath {
    param([Parameter(Mandatory = $true)][string]$Parent, [Parameter(Mandatory = $true)][string]$Child)
    $fullParent = [IO.Path]::GetFullPath($Parent).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $fullChild = [IO.Path]::GetFullPath($Child)
    if (-not $fullChild.StartsWith($fullParent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe output path: $fullChild"
    }
    return $fullChild
}

function Assert-StableManagerSignature {
    param(
        [Parameter(Mandatory = $true)][string]$ManagerPath,
        [Parameter(Mandatory = $true)][string]$ExpectedSigner
    )

    if ($ExpectedSigner -cnotmatch '^[A-F0-9]{64}$') {
        throw 'Stable Manager build-policy signer is invalid.'
    }
    $resolvedManager = Resolve-RequiredFile -Path $ManagerPath -Description 'signed stable Manager'

    $signature = Get-AuthenticodeSignature -LiteralPath $resolvedManager
    if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or -not $signature.SignerCertificate) {
        throw "Stable Manager Authenticode signature is not valid: $($signature.StatusMessage)"
    }
    $sha256Algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $actualSigner = ([BitConverter]::ToString(
            $sha256Algorithm.ComputeHash($signature.SignerCertificate.RawData))).Replace('-', '')
    }
    finally { $sha256Algorithm.Dispose() }
    if ($actualSigner -cne $ExpectedSigner) {
        throw 'Stable Manager build-policy signer does not match its Authenticode signer certificate.'
    }
}

$simHubRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $simHubRoot '..'))
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $simHubRoot 'dist' }
$resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($resolvedOutput) | Out-Null

$pluginProjectPath = Join-Path $simHubRoot 'FFBInterceptor.SimHub\FFBInterceptor.SimHub.csproj'
[xml]$pluginProject = Get-Content -LiteralPath $pluginProjectPath -Raw -Encoding UTF8
$version = [string]($pluginProject.Project.PropertyGroup.Version | Select-Object -First 1)
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'Plug-in project has no stable SemVer Version.' }

if (-not $LauncherX64Path) { $LauncherX64Path = Join-Path $repositoryRoot 'build\x64-release\FFBInterceptor.Launcher.exe' }
if (-not $HookX64Path) { $HookX64Path = Join-Path $repositoryRoot 'build\x64-release\FFBInterceptor.Hook.dll' }
if (-not $LauncherX86Path) { $LauncherX86Path = Join-Path $repositoryRoot 'build\x86-release\FFBInterceptor.Launcher.exe' }
if (-not $HookX86Path) { $HookX86Path = Join-Path $repositoryRoot 'build\x86-release\FFBInterceptor.Hook.dll' }
if (-not $ManagerX64Path) { $ManagerX64Path = Join-Path $repositoryRoot 'build\x64-release\FFBInterceptor.Manager.exe' }

$launcherX64 = Resolve-RequiredFile -Path $LauncherX64Path -Description 'x64 launcher'
$hookX64 = Resolve-RequiredFile -Path $HookX64Path -Description 'x64 hook DLL'
$launcherX86 = Resolve-RequiredFile -Path $LauncherX86Path -Description 'x86 launcher'
$hookX86 = Resolve-RequiredFile -Path $HookX86Path -Description 'x86 hook DLL'
$managerX64 = Resolve-RequiredFile -Path $ManagerX64Path -Description 'x64 one-click manager'

$temporaryRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('ffb-interceptor-launcher-' + [Guid]::NewGuid().ToString('N'))))
$systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $temporaryRoot.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -or
    -not ([IO.Path]::GetFileName($temporaryRoot)).StartsWith('ffb-interceptor-launcher-', [StringComparison]::Ordinal)) {
    throw "Unsafe temporary path: $temporaryRoot"
}

try {
    $dashboardOutput = Join-Path $temporaryRoot 'dashboards'
    $simHubPackageArguments = @{
        Configuration = $Configuration
        SimHubInstallPath = $SimHubInstallPath
        OutputDirectory = $dashboardOutput
        SigningCertificateThumbprint = $SigningCertificateThumbprint
        TimestampUrl = $TimestampUrl
    }
    if ($RequireSigning) { $simHubPackageArguments.RequireSigning = $true }
    & (Join-Path $PSScriptRoot 'Build-SimHubPackage.ps1') @simHubPackageArguments
    if ($LASTEXITCODE -ne 0) { throw 'SimHub package build failed.' }

    $bundleName = "FFBInterceptor-Launcher-$version"
    $bundleRoot = Join-Path $temporaryRoot $bundleName
    $launcherX64Destination = Join-Path $bundleRoot 'launcher\x64'
    $launcherX86Destination = Join-Path $bundleRoot 'launcher\x86'
    $simHubDestination = Join-Path $bundleRoot 'simhub'
    $dashboardDestination = Join-Path $bundleRoot 'Dashboards'
    foreach ($directory in @($launcherX64Destination, $launcherX86Destination, $simHubDestination, $dashboardDestination)) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }

    foreach ($name in @(
        'FFBInterceptor.Common.ps1',
        'Install-SimHubPlugin.cmd',
        'Install-SimHubPlugin.ps1',
        'Start-FFBInterceptor.cmd',
        'Start-FFBInterceptor.ps1',
        'Uninstall-SimHubPlugin.cmd',
        'Uninstall-SimHubPlugin.ps1'
    )) {
        Copy-Item -LiteralPath (Resolve-RequiredFile `
            -Path (Join-Path (Join-Path $simHubRoot 'launcher-portable') $name) `
            -Description "portable launcher file $name") -Destination $bundleRoot
    }
    Copy-Item -LiteralPath $launcherX64 -Destination (Join-Path $launcherX64Destination 'FFBInterceptor.Launcher.exe')
    Copy-Item -LiteralPath $hookX64 -Destination (Join-Path $launcherX64Destination 'FFBInterceptor.Hook.dll')
    Copy-Item -LiteralPath $launcherX86 -Destination (Join-Path $launcherX86Destination 'FFBInterceptor.Launcher.exe')
    Copy-Item -LiteralPath $hookX86 -Destination (Join-Path $launcherX86Destination 'FFBInterceptor.Hook.dll')
    Copy-Item -LiteralPath $managerX64 -Destination (Join-Path $bundleRoot 'FFBInterceptor.Manager.exe')
    $stableManagerSigner = ''
    if ($RequireSigning) {
        $stableManagerSigner = [string](& (Join-Path $PSScriptRoot 'Test-ManagerBuildPolicy.ps1') `
            -ManagerPath (Join-Path $bundleRoot 'FFBInterceptor.Manager.exe'))
    }

    $pluginOutput = Join-Path $simHubRoot "FFBInterceptor.SimHub\bin\$Configuration\net48"
    foreach ($name in @('FFBInterceptor.SimHub.dll', 'FFBInterceptor.Core.dll')) {
        Copy-Item -LiteralPath (Resolve-RequiredFile -Path (Join-Path $pluginOutput $name) -Description "SimHub plug-in $name") `
            -Destination $simHubDestination
    }
    foreach ($name in @('FFB Interceptor 800x480.simhubdash', 'FFB Interceptor Overlay 480x160.simhubdash')) {
        Copy-Item -LiteralPath (Resolve-RequiredFile -Path (Join-Path $dashboardOutput $name) -Description "Dashboard $name") `
            -Destination $dashboardDestination
    }

    Copy-Item -LiteralPath (Join-Path $simHubRoot 'LAUNCHER.zh-TW.md') -Destination (Join-Path $bundleRoot 'README.zh-TW.md')
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'launcher\MANAGER.zh-TW.md') -Destination $bundleRoot
    foreach ($name in @('LICENSE', 'THIRD_PARTY_NOTICES.md')) {
        Copy-Item -LiteralPath (Join-Path $repositoryRoot $name) -Destination $bundleRoot
    }
    $licenseDestination = Join-Path $bundleRoot 'licenses'
    [IO.Directory]::CreateDirectory($licenseDestination) | Out-Null
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'licenses\upstream-dcs-force-feedback-fix-MIT.txt') -Destination $licenseDestination

    $signingTargets = @(
        (Join-Path $bundleRoot 'FFBInterceptor.Manager.exe'),
        (Join-Path $bundleRoot 'FFBInterceptor.Common.ps1'),
        (Join-Path $bundleRoot 'Install-SimHubPlugin.ps1'),
        (Join-Path $bundleRoot 'Start-FFBInterceptor.ps1'),
        (Join-Path $bundleRoot 'Uninstall-SimHubPlugin.ps1'),
        (Join-Path $launcherX64Destination 'FFBInterceptor.Launcher.exe'),
        (Join-Path $launcherX64Destination 'FFBInterceptor.Hook.dll'),
        (Join-Path $launcherX86Destination 'FFBInterceptor.Launcher.exe'),
        (Join-Path $launcherX86Destination 'FFBInterceptor.Hook.dll'),
        (Join-Path $simHubDestination 'FFBInterceptor.SimHub.dll'),
        (Join-Path $simHubDestination 'FFBInterceptor.Core.dll')
    )
    $signingArguments = @{
        Paths = $signingTargets
        CertificateThumbprint = $SigningCertificateThumbprint
        TimestampUrl = $TimestampUrl
    }
    if ($RequireSigning) { $signingArguments.RequireSigning = $true }
    & (Join-Path $repositoryRoot '.github\scripts\sign-windows-artifacts.ps1') @signingArguments
    if ($RequireSigning) {
        $signedManagerPolicySigner = [string](& (Join-Path $PSScriptRoot 'Test-ManagerBuildPolicy.ps1') `
            -ManagerPath (Join-Path $bundleRoot 'FFBInterceptor.Manager.exe'))
        if ($signedManagerPolicySigner -cne $stableManagerSigner) {
            throw 'Signed stable Manager build-policy marker changed during signing.'
        }
        Assert-StableManagerSignature `
            -ManagerPath (Join-Path $bundleRoot 'FFBInterceptor.Manager.exe') `
            -ExpectedSigner $stableManagerSigner
    }

    $manifestLines = @(
        Get-ChildItem -LiteralPath $bundleRoot -Recurse -File |
            Sort-Object FullName |
            ForEach-Object {
                $relative = $_.FullName.Substring($bundleRoot.Length + 1).Replace('\', '/')
                "$(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256 | Select-Object -ExpandProperty Hash)  $relative"
            }
    )
    [IO.File]::WriteAllLines((Join-Path $bundleRoot 'SHA256SUMS.txt'), $manifestLines, [Text.UTF8Encoding]::new($false))

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = Assert-ChildPath -Parent $resolvedOutput -Child (Join-Path $resolvedOutput ($bundleName + '.zip'))
    $partialArchive = Assert-ChildPath -Parent $resolvedOutput -Child `
        (Join-Path $resolvedOutput ($bundleName + '.' + [Guid]::NewGuid().ToString('N') + '.partial.zip'))
    $previousArchive = ''
    try {
        [IO.Compression.ZipFile]::CreateFromDirectory(
            $bundleRoot, $partialArchive, [IO.Compression.CompressionLevel]::Optimal, $true)
        & (Join-Path $PSScriptRoot 'Test-LauncherPackage.ps1') -PackagePath $partialArchive
        if ($LASTEXITCODE -ne 0) { throw 'Launcher package validation failed.' }
        if (Test-Path -LiteralPath $archive -PathType Leaf) {
            $previousArchive = Assert-ChildPath -Parent $resolvedOutput -Child `
                (Join-Path $resolvedOutput ($bundleName + '.' + [Guid]::NewGuid().ToString('N') + '.previous.zip'))
            [IO.File]::Replace($partialArchive, $archive, $previousArchive, $true)
            Remove-Item -LiteralPath $previousArchive -Force
            $previousArchive = ''
        }
        else {
            [IO.File]::Move($partialArchive, $archive)
        }
    }
    finally {
        if (Test-Path -LiteralPath $partialArchive) { Remove-Item -LiteralPath $partialArchive -Force }
        if ($previousArchive -and (Test-Path -LiteralPath $previousArchive)) {
            Remove-Item -LiteralPath $previousArchive -Force
        }
    }
    Write-Host "Built $archive"
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}
