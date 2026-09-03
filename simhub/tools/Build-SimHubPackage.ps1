# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [string]$Configuration = 'Release',
    [string]$SimHubInstallPath = 'C:\Program Files (x86)\SimHub',
    [string]$SdkFingerprintPath = '',
    [string]$OutputDirectory = '',
    [string]$SigningCertificateThumbprint = $env:FFB_SIGNING_CERT_SHA1,
    [string]$TimestampUrl = 'http://timestamp.digicert.com',
    [switch]$RequireSigning
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'Build-SimHubPackage requires PowerShell 7 or newer; run it with pwsh.'
}
. (Join-Path $PSScriptRoot 'ArchiveHelpers.ps1')

$simhubRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $simhubRoot '..'))
if ([string]::IsNullOrWhiteSpace($SdkFingerprintPath)) {
    $SdkFingerprintPath = Join-Path $simhubRoot 'sdk-compatibility.json'
}
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
$verifiedSimHubVersion = & (Join-Path $PSScriptRoot 'Test-SimHubSdk.ps1') `
    -SimHubInstallPath $env:SIMHUB_INSTALL_PATH -FingerprintPath $SdkFingerprintPath
if ([string]::IsNullOrWhiteSpace($verifiedSimHubVersion)) {
    throw 'SimHub SDK fingerprint verification failed.'
}
Write-Host "Verified SimHub SDK profile $verifiedSimHubVersion"
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
    $pluginDirectory = Join-Path $packageRoot 'simhub'
    $dashboardDirectory = Join-Path $packageRoot 'Dashboards'
    $licenseDirectory = Join-Path $packageRoot 'licenses'
    [System.IO.Directory]::CreateDirectory($pluginDirectory) | Out-Null
    [System.IO.Directory]::CreateDirectory($dashboardDirectory) | Out-Null
    [System.IO.Directory]::CreateDirectory($licenseDirectory) | Out-Null
    $pluginOutput = Join-Path $simhubRoot "FFBInterceptor.SimHub\bin\$Configuration\net48"
    Copy-Item -LiteralPath (Join-Path $pluginOutput 'FFBInterceptor.SimHub.dll') -Destination $pluginDirectory
    Copy-Item -LiteralPath (Join-Path $pluginOutput 'FFBInterceptor.Core.dll') -Destination $pluginDirectory
    foreach ($name in @(
        'FFBInterceptor.Common.ps1',
        'Install-SimHubPlugin.cmd',
        'Install-SimHubPlugin.ps1',
        'Uninstall-SimHubPlugin.cmd',
        'Uninstall-SimHubPlugin.ps1'
    )) {
        Copy-Item -LiteralPath (Join-Path $simhubRoot "launcher-portable\$name") -Destination $packageRoot
    }
    Copy-Item -LiteralPath (Join-Path $simhubRoot 'INSTALL.zh-TW.md') -Destination $packageRoot
    Copy-Item -LiteralPath (Join-Path $simhubRoot 'README.md') -Destination (Join-Path $packageRoot 'SIMHUB-README.md')
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'LICENSE') -Destination $packageRoot
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'THIRD_PARTY_NOTICES.md') -Destination $packageRoot
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'licenses\upstream-dcs-force-feedback-fix-MIT.txt') -Destination $licenseDirectory
    Copy-Item -LiteralPath (Join-Path $resolvedOutput 'FFB Interceptor 800x480.simhubdash') -Destination $dashboardDirectory
    Copy-Item -LiteralPath (Join-Path $resolvedOutput 'FFB Interceptor Overlay 480x160.simhubdash') -Destination $dashboardDirectory

    $signingTargets = @(
        (Join-Path $pluginDirectory 'FFBInterceptor.SimHub.dll'),
        (Join-Path $pluginDirectory 'FFBInterceptor.Core.dll'),
        (Join-Path $packageRoot 'FFBInterceptor.Common.ps1'),
        (Join-Path $packageRoot 'Install-SimHubPlugin.ps1'),
        (Join-Path $packageRoot 'Uninstall-SimHubPlugin.ps1')
    )
    $signingArguments = @{
        Paths = $signingTargets
        CertificateThumbprint = $SigningCertificateThumbprint
        TimestampUrl = $TimestampUrl
    }
    if ($RequireSigning) { $signingArguments.RequireSigning = $true }
    & (Join-Path $repositoryRoot '.github\scripts\sign-windows-artifacts.ps1') @signingArguments

    $manifestLines = @(Get-ChildItem -LiteralPath $packageRoot -Recurse -File |
        Sort-Object FullName | ForEach-Object {
            $relative = $_.FullName.Substring($packageRoot.Length + 1).Replace('\', '/')
            "$(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256 | Select-Object -ExpandProperty Hash)  $relative"
        })
    [IO.File]::WriteAllLines((Join-Path $packageRoot 'SHA256SUMS.txt'),
        $manifestLines, [Text.UTF8Encoding]::new($false))

    $archive = [System.IO.Path]::GetFullPath((Join-Path $resolvedOutput ($packageName + '.zip')))
    $outputPrefix = $resolvedOutput.TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) +
        [IO.Path]::DirectorySeparatorChar
    if (-not $archive.StartsWith($outputPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe output path: $archive"
    }
    $partialArchive = [IO.Path]::GetFullPath((Join-Path $resolvedOutput (
        $packageName + '.' + [Guid]::NewGuid().ToString('N') + '.partial.zip')))
    if (-not $partialArchive.StartsWith($outputPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe partial output path: $partialArchive"
    }
    try {
        New-CanonicalZipArchive -SourceDirectory $temporaryRoot -DestinationPath $partialArchive
        $zip = [System.IO.Compression.ZipFile]::OpenRead($partialArchive)
        try {
            $entryNames = @($zip.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
            foreach ($required in @('simhub/FFBInterceptor.SimHub.dll', 'simhub/FFBInterceptor.Core.dll',
                'Install-SimHubPlugin.ps1', 'Uninstall-SimHubPlugin.ps1', 'SHA256SUMS.txt',
                'LICENSE', 'THIRD_PARTY_NOTICES.md')) {
                if (-not ($entryNames | Where-Object { $_.EndsWith('/' + $required, [StringComparison]::Ordinal) })) {
                    throw "Package is missing $required."
                }
            }
            if ($entryNames | Where-Object { $_ -match '/(SimHub\.Plugins|GameReaderCommon|SimHub\.Logging|log4net)\.dll$' }) {
                throw 'Package unexpectedly contains a SimHub-owned dependency.'
            }
        }
        finally { $zip.Dispose() }
        $validatedHash = Get-LockedFileSha256 -Path $partialArchive
        & (Join-Path $PSScriptRoot 'Test-SimHubPackage.ps1') -PackagePath $partialArchive
        if ($LASTEXITCODE -ne 0) { throw 'SimHub package validation failed.' }
        $postValidationHash = Get-LockedFileSha256 -Path $partialArchive
        if ($postValidationHash -cne $validatedHash) {
            throw 'SimHub package bytes changed while they were being validated.'
        }
        [void](Publish-ValidatedArchive -PartialPath $partialArchive `
            -DestinationPath $archive -ExpectedSha256 $validatedHash)
    }
    finally {
        if (Test-Path -LiteralPath $partialArchive) {
            Remove-Item -LiteralPath $partialArchive -Force
        }
    }
    Write-Host "Built $archive"
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
