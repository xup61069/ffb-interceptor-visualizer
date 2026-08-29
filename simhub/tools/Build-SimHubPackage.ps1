# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [string]$Configuration = 'Release',
    [string]$SimHubInstallPath = 'C:\Program Files (x86)\SimHub',
    [string]$OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$simhubRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $simhubRoot '..'))
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot '..\dist'
}
$resolvedOutput = [System.IO.Path]::GetFullPath($OutputDirectory)
[System.IO.Directory]::CreateDirectory($resolvedOutput) | Out-Null
$pluginProjectPath = Join-Path $simhubRoot 'FFBInterceptor.SimHub\FFBInterceptor.SimHub.csproj'
[xml]$pluginProject = Get-Content -LiteralPath $pluginProjectPath -Raw -Encoding UTF8
$packageVersion = [string]($pluginProject.Project.PropertyGroup.Version | Select-Object -First 1)
if ($packageVersion -notmatch '^\d+\.\d+\.\d+$') { throw 'Plugin project has no stable SemVer Version.' }

$env:SIMHUB_INSTALL_PATH = [System.IO.Path]::GetFullPath($SimHubInstallPath)
& dotnet build (Join-Path $simhubRoot 'FFBInterceptor.Core.Tests\FFBInterceptor.Core.Tests.csproj') -c $Configuration
if ($LASTEXITCODE -ne 0) { throw 'Core test build failed.' }
& (Join-Path $simhubRoot "FFBInterceptor.Core.Tests\bin\$Configuration\net48\FFBInterceptor.Core.Tests.exe")
if ($LASTEXITCODE -ne 0) { throw 'Core tests failed.' }
& dotnet build $pluginProjectPath -c $Configuration
if ($LASTEXITCODE -ne 0) { throw 'SimHub plugin build failed.' }

& (Join-Path $PSScriptRoot 'Test-Dashboards.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Dashboard validation failed.' }
& (Join-Path $PSScriptRoot 'Build-Dashboards.ps1') -OutputDirectory $resolvedOutput

$temporaryRoot = [System.IO.Path]::GetFullPath(
    (Join-Path ([System.IO.Path]::GetTempPath()) ('ffb-interceptor-package-' + [Guid]::NewGuid().ToString('N'))))
$systemTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
if (-not $temporaryRoot.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -or
    -not ([System.IO.Path]::GetFileName($temporaryRoot)).StartsWith('ffb-interceptor-package-', [StringComparison]::Ordinal)) {
    throw "Unsafe temporary path: $temporaryRoot"
}

try {
    $packageName = "FFBInterceptor-SimHub-$packageVersion"
    $packageRoot = Join-Path $temporaryRoot $packageName
    [System.IO.Directory]::CreateDirectory($packageRoot) | Out-Null
    $pluginOutput = Join-Path $simhubRoot "FFBInterceptor.SimHub\bin\$Configuration\net48"
    Copy-Item -LiteralPath (Join-Path $pluginOutput 'FFBInterceptor.SimHub.dll') -Destination $packageRoot
    Copy-Item -LiteralPath (Join-Path $pluginOutput 'FFBInterceptor.Core.dll') -Destination $packageRoot
    foreach ($pdbName in @('FFBInterceptor.SimHub.pdb', 'FFBInterceptor.Core.pdb')) {
        $pdbPath = Join-Path $pluginOutput $pdbName
        if (Test-Path -LiteralPath $pdbPath) { Copy-Item -LiteralPath $pdbPath -Destination $packageRoot }
    }
    Copy-Item -LiteralPath (Join-Path $simhubRoot 'INSTALL.zh-TW.md') -Destination $packageRoot
    Copy-Item -LiteralPath (Join-Path $simhubRoot 'README.md') -Destination (Join-Path $packageRoot 'SIMHUB-README.md')
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'LICENSE') -Destination $packageRoot
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'THIRD_PARTY_NOTICES.md') -Destination $packageRoot
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'licenses\upstream-dcs-force-feedback-fix-MIT.txt') -Destination $packageRoot
    Copy-Item -LiteralPath (Join-Path $resolvedOutput 'FFB Interceptor 800x480.simhubdash') -Destination $packageRoot
    Copy-Item -LiteralPath (Join-Path $resolvedOutput 'FFB Interceptor Overlay 480x160.simhubdash') -Destination $packageRoot

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Path]::GetFullPath((Join-Path $resolvedOutput ($packageName + '.zip')))
    if (-not $archive.StartsWith($resolvedOutput, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe output path: $archive"
    }
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $temporaryRoot,
        $archive,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false)
    $zip = [System.IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $entryNames = @($zip.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
        foreach ($required in @('FFBInterceptor.SimHub.dll', 'FFBInterceptor.Core.dll', 'LICENSE', 'THIRD_PARTY_NOTICES.md')) {
            if (-not ($entryNames | Where-Object { $_.EndsWith('/' + $required, [StringComparison]::Ordinal) })) {
                throw "Package is missing $required."
            }
        }
        if ($entryNames | Where-Object { $_ -match '/(SimHub\.Plugins|GameReaderCommon|SimHub\.Logging|log4net)\.dll$' }) {
            throw 'Package unexpectedly contains a SimHub-owned dependency.'
        }
    }
    finally { $zip.Dispose() }
    Write-Host "Built $archive"
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
