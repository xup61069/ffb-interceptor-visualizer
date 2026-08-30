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
    $roots = @($names | ForEach-Object { ($_ -split '/')[0] } | Where-Object { $_ -like 'FFBInterceptor-ReadyToUse-*' } | Sort-Object -Unique)
    if ($roots.Count -ne 1) { throw 'Package must contain exactly one FFBInterceptor-ReadyToUse root directory.' }
    $root = $roots[0]
    $required = @(
        "$root/Install-FFBInterceptor.cmd",
        "$root/Install-FFBInterceptor.ps1",
        "$root/Uninstall-FFBInterceptor.cmd",
        "$root/Uninstall-FFBInterceptor.ps1",
        "$root/runtime/x64/dinput8.dll",
        "$root/runtime/x86/dinput8.dll",
        "$root/simhub/FFBInterceptor.SimHub.dll",
        "$root/simhub/FFBInterceptor.Core.dll",
        "$root/Dashboards/FFB Interceptor 800x480.simhubdash",
        "$root/Dashboards/FFB Interceptor Overlay 480x160.simhubdash",
        "$root/README.zh-TW.md",
        "$root/LICENSE",
        "$root/THIRD_PARTY_NOTICES.md",
        "$root/licenses/upstream-dcs-force-feedback-fix-MIT.txt"
    )
    foreach ($entry in $required) {
        if ($names -notcontains $entry) { throw "Package is missing required entry: $entry" }
    }
    $dllEntries = @($names | Where-Object { $_ -like '*.dll' })
    if ($dllEntries.Count -ne 4) { throw "Package contains an unexpected DLL count: $($dllEntries.Count)" }
    if ($dllEntries | Where-Object { $_ -match '/(SimHub\.Plugins|GameReaderCommon|SimHub\.Logging|log4net)\.dll$' }) {
        throw 'Package unexpectedly contains a SimHub-owned dependency.'
    }
}
finally {
    $zip.Dispose()
}

$scriptPaths = @(
    (Join-Path (Split-Path -Parent $PSScriptRoot) 'portable\Install-FFBInterceptor.ps1'),
    (Join-Path (Split-Path -Parent $PSScriptRoot) 'portable\Uninstall-FFBInterceptor.ps1')
)
foreach ($scriptPath in $scriptPaths) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        throw "PowerShell syntax error in $scriptPath : $($errors[0].Message)"
    }
}

$temporaryRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('ffb-ready-package-smoke-' + [Guid]::NewGuid().ToString('N'))))
$systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $temporaryRoot.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -or
    -not ([IO.Path]::GetFileName($temporaryRoot)).StartsWith('ffb-ready-package-smoke-', [StringComparison]::Ordinal)) {
    throw "Unsafe temporary path: $temporaryRoot"
}
try {
    [IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $temporaryRoot)
    $installer = Join-Path $temporaryRoot (Join-Path $root 'Install-FFBInterceptor.ps1')
    $notepad = Join-Path $env:SystemRoot 'System32\notepad.exe'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -GameExecutable $notepad `
        -SkipSimHub -NoDashboardImport -NoElevation -NoPause -WhatIf
    if ($LASTEXITCODE -ne 0) { throw 'Packaged installer WhatIf smoke test failed.' }
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

Write-Output "Ready-to-use package validation passed: $archivePath"
