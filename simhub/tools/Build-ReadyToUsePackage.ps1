# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [string]$Configuration = 'Release',
    [string]$SimHubInstallPath = 'C:\Program Files (x86)\SimHub',
    [string]$ProxyX64Path = '',
    [string]$ProxyX86Path = '',
    [string]$OutputDirectory = ''
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

$simHubRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $simHubRoot '..'))
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $simHubRoot 'dist' }
$resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($resolvedOutput) | Out-Null

$pluginProjectPath = Join-Path $simHubRoot 'FFBInterceptor.SimHub\FFBInterceptor.SimHub.csproj'
[xml]$pluginProject = Get-Content -LiteralPath $pluginProjectPath -Raw -Encoding UTF8
$version = [string]($pluginProject.Project.PropertyGroup.Version | Select-Object -First 1)
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'Plug-in project has no stable SemVer Version.' }

if ([string]::IsNullOrWhiteSpace($ProxyX64Path)) { $ProxyX64Path = Join-Path $repositoryRoot 'build\x64-release\dinput8.dll' }
if ([string]::IsNullOrWhiteSpace($ProxyX86Path)) { $ProxyX86Path = Join-Path $repositoryRoot 'build\x86-release\dinput8.dll' }
$proxyX64 = Resolve-RequiredFile -Path $ProxyX64Path -Description 'x64 proxy DLL'
$proxyX86 = Resolve-RequiredFile -Path $ProxyX86Path -Description 'x86 proxy DLL'

$temporaryRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('ffb-interceptor-ready-' + [Guid]::NewGuid().ToString('N'))))
$systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $temporaryRoot.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -or
    -not ([IO.Path]::GetFileName($temporaryRoot)).StartsWith('ffb-interceptor-ready-', [StringComparison]::Ordinal)) {
    throw "Unsafe temporary path: $temporaryRoot"
}

try {
    $dashboardOutput = Join-Path $temporaryRoot 'dashboards'
    & (Join-Path $PSScriptRoot 'Build-SimHubPackage.ps1') -Configuration $Configuration -SimHubInstallPath $SimHubInstallPath -OutputDirectory $dashboardOutput
    if ($LASTEXITCODE -ne 0) { throw 'SimHub package build failed.' }

    $bundleName = "FFBInterceptor-ReadyToUse-$version"
    $bundleRoot = Join-Path $temporaryRoot $bundleName
    $runtimeX64 = Join-Path $bundleRoot 'runtime\x64'
    $runtimeX86 = Join-Path $bundleRoot 'runtime\x86'
    $simHubDestination = Join-Path $bundleRoot 'simhub'
    $dashboardDestination = Join-Path $bundleRoot 'Dashboards'
    [IO.Directory]::CreateDirectory($runtimeX64) | Out-Null
    [IO.Directory]::CreateDirectory($runtimeX86) | Out-Null
    [IO.Directory]::CreateDirectory($simHubDestination) | Out-Null
    [IO.Directory]::CreateDirectory($dashboardDestination) | Out-Null

    foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $simHubRoot 'portable') -File)) {
        Copy-Item -LiteralPath $file.FullName -Destination $bundleRoot
    }
    Copy-Item -LiteralPath $proxyX64 -Destination (Join-Path $runtimeX64 'dinput8.dll')
    Copy-Item -LiteralPath $proxyX86 -Destination (Join-Path $runtimeX86 'dinput8.dll')

    $pluginOutput = Join-Path $simHubRoot "FFBInterceptor.SimHub\bin\$Configuration\net48"
    foreach ($name in @('FFBInterceptor.SimHub.dll', 'FFBInterceptor.Core.dll')) {
        Copy-Item -LiteralPath (Resolve-RequiredFile -Path (Join-Path $pluginOutput $name) -Description "SimHub plug-in $name") -Destination $simHubDestination
    }
    foreach ($name in @('FFB Interceptor 800x480.simhubdash', 'FFB Interceptor Overlay 480x160.simhubdash')) {
        Copy-Item -LiteralPath (Resolve-RequiredFile -Path (Join-Path $dashboardOutput $name) -Description "Dashboard $name") -Destination $dashboardDestination
    }

    Copy-Item -LiteralPath (Join-Path $simHubRoot 'PORTABLE.zh-TW.md') -Destination (Join-Path $bundleRoot 'README.zh-TW.md')
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'LICENSE') -Destination $bundleRoot
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'THIRD_PARTY_NOTICES.md') -Destination $bundleRoot
    $licenseDestination = Join-Path $bundleRoot 'licenses'
    [IO.Directory]::CreateDirectory($licenseDestination) | Out-Null
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'licenses\upstream-dcs-force-feedback-fix-MIT.txt') -Destination $licenseDestination

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = Assert-ChildPath -Parent $resolvedOutput -Child (Join-Path $resolvedOutput ($bundleName + '.zip'))
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    [IO.Compression.ZipFile]::CreateFromDirectory($bundleRoot, $archive, [IO.Compression.CompressionLevel]::Optimal, $true)
    & (Join-Path $PSScriptRoot 'Test-ReadyToUsePackage.ps1') -PackagePath $archive
    if ($LASTEXITCODE -ne 0) { throw 'Ready-to-use package validation failed.' }
    Write-Host "Built $archive"
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}
