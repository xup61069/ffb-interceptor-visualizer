# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$PackagePath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archivePath = (Resolve-Path -LiteralPath $PackagePath -ErrorAction Stop).Path
$zip = [IO.Compression.ZipFile]::OpenRead($archivePath)
try {
    $names = @($zip.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
    if ($names.Count -eq 0) { throw 'SimHub package is empty.' }
    $seenNames = @{}
    foreach ($name in $names) {
        if ([string]::IsNullOrWhiteSpace($name) -or $name.StartsWith('/') -or $name.Contains('\')) {
            throw "Package contains an unsafe entry name: $name"
        }
        $key = $name.ToLowerInvariant()
        if ($seenNames.ContainsKey($key)) { throw "Package contains a duplicate entry name: $name" }
        $seenNames[$key] = $true
        foreach ($segment in @($name.TrimEnd('/') -split '/')) {
            if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.' -or $segment -eq '..' -or
                $segment.Contains(':') -or $segment.EndsWith('.') -or $segment.EndsWith(' ')) {
                throw "Package contains a non-canonical entry name: $name"
            }
        }
    }
    $roots = @($names | ForEach-Object { ($_ -split '/')[0] } |
        Where-Object { $_ -like 'FFBInterceptor-SimHub-*' } | Sort-Object -Unique)
    if ($roots.Count -ne 1) { throw 'Package must contain exactly one FFBInterceptor-SimHub root.' }
    $root = $roots[0]
    $required = @(
        'FFBInterceptor.Common.ps1', 'Install-SimHubPlugin.cmd', 'Install-SimHubPlugin.ps1',
        'Uninstall-SimHubPlugin.cmd', 'Uninstall-SimHubPlugin.ps1',
        'simhub/FFBInterceptor.SimHub.dll', 'simhub/FFBInterceptor.Core.dll',
        'Dashboards/FFB Interceptor 800x480.simhubdash',
        'Dashboards/FFB Interceptor Overlay 480x160.simhubdash',
        'INSTALL.zh-TW.md', 'SIMHUB-README.md', 'SHA256SUMS.txt', 'LICENSE',
        'THIRD_PARTY_NOTICES.md', 'licenses/upstream-dcs-force-feedback-fix-MIT.txt'
    ) | ForEach-Object { "$root/$_" }
    $files = @($names | Where-Object { -not $_.EndsWith('/') })
    if ($files.Count -ne $required.Count) { throw 'SimHub package contains an unexpected file count.' }
    foreach ($entry in $files) { if ($required -cnotcontains $entry) { throw "Unexpected package file: $entry" } }
    foreach ($entry in $required) { if ($files -cnotcontains $entry) { throw "Missing package file: $entry" } }
    $allowedDirectories = @(
        "$root/",
        "$root/simhub/",
        "$root/Dashboards/",
        "$root/licenses/"
    )
    foreach ($entry in @($names | Where-Object { $_.EndsWith('/') })) {
        if ($allowedDirectories -cnotcontains $entry) { throw "Unexpected package directory: $entry" }
    }
    if ($names | Where-Object { $_ -match '(^|/)dinput8\.dll$' }) { throw 'SimHub package must not contain dinput8.dll.' }
    if ($names | Where-Object { $_ -match '/(SimHub\.Plugins|GameReaderCommon|SimHub\.Logging|log4net)\.dll$' }) {
        throw 'Package unexpectedly redistributes a SimHub-owned dependency.'
    }
}
finally { $zip.Dispose() }

$temporaryRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) `
    ('ffb-launcher-package-smoke-' + [Guid]::NewGuid().ToString('N'))))
$systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $temporaryRoot.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -or
    -not [IO.Path]::GetFileName($temporaryRoot).StartsWith('ffb-launcher-package-smoke-', [StringComparison]::Ordinal)) {
    throw "Unsafe temporary path: $temporaryRoot"
}
$oldTest = $env:FFB_INTERCEPTOR_PACKAGE_TEST
$oldState = $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY
try {
    [IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $temporaryRoot)
    $packageRoot = Join-Path $temporaryRoot $root
    $packageRootFull = [IO.Path]::GetFullPath($packageRoot)
    foreach ($entry in $names) {
        $candidate = [IO.Path]::GetFullPath((Join-Path $temporaryRoot $entry))
        if (-not $candidate.Equals($packageRootFull, [StringComparison]::OrdinalIgnoreCase) -and
            -not $candidate.StartsWith($packageRootFull + [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "Package entry escapes its root: $entry"
        }
    }
    foreach ($relative in @('FFBInterceptor.Common.ps1', 'Install-SimHubPlugin.ps1', 'Uninstall-SimHubPlugin.ps1')) {
        $tokens = $null
        $errors = $null
        [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $packageRoot $relative), [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors.Count) { throw "PowerShell parse failure in $relative : $($errors[0].Message)" }
    }
    . (Join-Path $packageRoot 'FFBInterceptor.Common.ps1')
    [void](Assert-FFBPackageManifest -BundleRoot $packageRoot)
    & (Join-Path $PSScriptRoot '..\..\tests\powershell\standalone_boundary_tests.ps1') `
        -PackageRoot $packageRoot

    $fakeSimHub = Join-Path $temporaryRoot 'fake-simhub'
    [IO.Directory]::CreateDirectory($fakeSimHub) | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $fakeSimHub 'SimHubWPF.exe'), [byte[]]@(0))
    $originalHashes = @{}
    foreach ($name in @('FFBInterceptor.SimHub.dll', 'FFBInterceptor.Core.dll')) {
        $path = Join-Path $fakeSimHub $name
        [IO.File]::WriteAllText($path, "original-$name", [Text.UTF8Encoding]::new($false))
        $originalHashes[$name] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
    $env:FFB_INTERCEPTOR_PACKAGE_TEST = '1'
    $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY = Join-Path $temporaryRoot 'state'
    $installer = Join-Path $packageRoot 'Install-SimHubPlugin.ps1'
    $uninstaller = Join-Path $packageRoot 'Uninstall-SimHubPlugin.ps1'
    if (-not (Get-Process -Name 'SimHub', 'SimHubWPF' -ErrorAction SilentlyContinue)) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer `
            -SimHubInstallPath $fakeSimHub -NoElevation -NoDashboardImport -NoPause
        if ($LASTEXITCODE -ne 0) { throw 'Standalone SimHub installer smoke failed.' }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uninstaller -NoElevation -NoPause
        if ($LASTEXITCODE -ne 0) { throw 'Standalone SimHub uninstaller smoke failed.' }
        foreach ($name in $originalHashes.Keys) {
            if ((Get-FileHash -LiteralPath (Join-Path $fakeSimHub $name) -Algorithm SHA256).Hash -ne $originalHashes[$name]) {
                throw "Standalone SimHub uninstaller did not restore $name"
            }
        }
    }
    else {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer `
            -SimHubInstallPath $fakeSimHub -NoElevation -NoDashboardImport -NoPause -WhatIf
        if ($LASTEXITCODE -ne 0) { throw 'Standalone SimHub installer WhatIf smoke failed.' }
    }
}
finally {
    $env:FFB_INTERCEPTOR_PACKAGE_TEST = $oldTest
    $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY = $oldState
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}
Write-Host "SimHub package validation passed: $archivePath"
