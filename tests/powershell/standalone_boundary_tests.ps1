# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$PackageRoot)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-ChildPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Parent
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullParent = [IO.Path]::GetFullPath($Parent).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (-not $fullPath.StartsWith(
        $fullParent + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe fixture path: $fullPath"
    }
    return $fullPath
}

function Invoke-TamperedHelperFixture {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$FixtureParent,
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Uninstall')][string]$Mode,
        [switch]$RewriteManifest
    )
    $variant = if ($RewriteManifest) { 'signature' } else { 'manifest' }
    $fixtureRoot = Assert-ChildPath -Parent $FixtureParent -Path (
        Join-Path $FixtureParent (
            $Mode.ToLowerInvariant() + '-' + $variant + '-' + [Guid]::NewGuid().ToString('N')))
    [IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
    foreach ($child in @(Get-ChildItem -LiteralPath $SourceRoot -Force)) {
        Copy-Item -LiteralPath $child.FullName -Destination $fixtureRoot -Recurse -Force
    }

    $sentinel = Assert-ChildPath -Parent $FixtureParent -Path (Join-Path $FixtureParent (
        $Mode.ToLowerInvariant() + '-helper-executed.txt'))
    $commonPath = Join-Path $fixtureRoot 'FFBInterceptor.Common.ps1'
    $original = [IO.File]::ReadAllText($commonPath, [Text.Encoding]::UTF8)
    $escapedSentinel = $sentinel.Replace("'", "''")
    $tampered = "[IO.File]::WriteAllText('$escapedSentinel', 'UNSAFE')`r`n" + $original
    [IO.File]::WriteAllText($commonPath, $tampered, [Text.UTF8Encoding]::new($false))
    if ($RewriteManifest) {
        $manifestPath = Join-Path $fixtureRoot 'SHA256SUMS.txt'
        $replacement = (Get-FileHash -LiteralPath $commonPath -Algorithm SHA256).Hash +
            '  FFBInterceptor.Common.ps1'
        $replaced = 0
        $lines = @(Get-Content -LiteralPath $manifestPath | ForEach-Object {
            if ($_ -match '^[A-Fa-f0-9]{64}  FFBInterceptor\.Common\.ps1$') {
                $replaced++
                $replacement
            }
            else { $_ }
        })
        if ($replaced -ne 1) { throw 'Fixture could not rewrite exactly one Common helper manifest entry.' }
        [IO.File]::WriteAllLines($manifestPath, $lines, [Text.UTF8Encoding]::new($false))
    }

    $savedErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Mode -eq 'Install') {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (
                Join-Path $fixtureRoot 'Install-SimHubPlugin.ps1') `
                -NoElevation -NoDashboardImport -NoPause -WhatIf 2>$null | Out-Null
        }
        else {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (
                Join-Path $fixtureRoot 'Uninstall-SimHubPlugin.ps1') `
                -NoElevation -NoPause -WhatIf 2>$null | Out-Null
        }
        $fixtureExitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedErrorAction }
    if ($fixtureExitCode -eq 0) {
        throw "$Mode $variant fixture accepted a tampered helper."
    }
    if (Test-Path -LiteralPath $sentinel) {
        throw "$Mode $variant fixture executed the helper before the self-contained package boundary passed."
    }
}

$resolvedRoot = (Resolve-Path -LiteralPath $PackageRoot -ErrorAction Stop).Path
$rootItem = Get-Item -LiteralPath $resolvedRoot -Force
if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "Package fixture root is unsafe: $resolvedRoot"
}

foreach ($name in @('Install-SimHubPlugin.ps1', 'Uninstall-SimHubPlugin.ps1')) {
    $path = Join-Path $resolvedRoot $name
    $source = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    if ($source -match '(?i)-Verb\s+RunAs|Invoke-ElevatedSelf|\s-EncodedCommand\s') {
        throw "$name still contains a standalone UAC self-elevation path."
    }
    $boundaryIndex = $source.IndexOf(
        '$packageBoundary = Enter-FFBStandalonePackageBoundary', [StringComparison]::Ordinal)
    $dotSourceIndex = $source.IndexOf('. $commonScript', [StringComparison]::Ordinal)
    if ($boundaryIndex -lt 0 -or $dotSourceIndex -lt 0 -or $dotSourceIndex -le $boundaryIndex) {
        throw "$name does not establish its self-contained package boundary before dot-sourcing the helper."
    }
    $managerOpenIndex = $source.IndexOf(
        '[Threading.EventWaitHandle]::OpenExisting', [StringComparison]::Ordinal)
    $managerSignalIndex = $source.IndexOf(
        '$managerInvocationHandle.Set()', [StringComparison]::Ordinal)
    if ($managerOpenIndex -le $boundaryIndex -or $managerOpenIndex -ge $dotSourceIndex -or
        $managerSignalIndex -le $dotSourceIndex) {
        throw "$name does not reopen the Manager handshake after package validation and signal only after the verified helper loads."
    }
    foreach ($marker in @('[IO.FileShare]::Read', 'Get-AuthenticodeSignature', 'SHA256SUMS.txt')) {
        if ($source.IndexOf($marker, [StringComparison]::Ordinal) -lt 0) {
            throw "$name is missing boundary control: $marker"
        }
    }
}

foreach ($name in @('Install-SimHubPlugin.ps1', 'Uninstall-SimHubPlugin.ps1')) {
    $savedErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (
            Join-Path $resolvedRoot $name) -NoElevation -NoPause -WhatIf `
            -ManagerInvocationEvent (
                'Local\FFBInterceptor.ManagerElevation.v1.' + ('A' * 64)) `
            2>$null | Out-Null
        $fixtureExitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedErrorAction }
    if ($fixtureExitCode -eq 0) {
        throw "$name accepted an ambiguous NoElevation/Manager handshake invocation."
    }
}

$temporaryParent = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) (
    'ffb-standalone-boundary-' + [Guid]::NewGuid().ToString('N'))))
$systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $temporaryParent.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -or
    -not [IO.Path]::GetFileName($temporaryParent).StartsWith(
        'ffb-standalone-boundary-', [StringComparison]::Ordinal)) {
    throw "Unsafe fixture root: $temporaryParent"
}

try {
    [IO.Directory]::CreateDirectory($temporaryParent) | Out-Null
    Invoke-TamperedHelperFixture -SourceRoot $resolvedRoot -FixtureParent $temporaryParent -Mode Install
    Invoke-TamperedHelperFixture -SourceRoot $resolvedRoot -FixtureParent $temporaryParent -Mode Uninstall
    $installerSignature = Get-AuthenticodeSignature -LiteralPath (
        Join-Path $resolvedRoot 'Install-SimHubPlugin.ps1')
    if ($installerSignature.Status -eq [Management.Automation.SignatureStatus]::Valid) {
        Invoke-TamperedHelperFixture -SourceRoot $resolvedRoot -FixtureParent $temporaryParent `
            -Mode Install -RewriteManifest
        Invoke-TamperedHelperFixture -SourceRoot $resolvedRoot -FixtureParent $temporaryParent `
            -Mode Uninstall -RewriteManifest
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $canExerciseControlledHandshake = $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator) -and
        -not (Get-Process -Name 'SimHub', 'SimHubWPF' -ErrorAction SilentlyContinue)
    if ($canExerciseControlledHandshake) {
        $handshakeRoot = Join-Path $temporaryParent 'manager-handshake'
        $fakeSimHub = Join-Path $handshakeRoot 'fake-simhub'
        $savedPackageTest = $env:FFB_INTERCEPTOR_PACKAGE_TEST
        $savedStateDirectory = $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY
        try {
            [IO.Directory]::CreateDirectory($fakeSimHub) | Out-Null
            [IO.File]::WriteAllBytes((Join-Path $fakeSimHub 'SimHubWPF.exe'), [byte[]]@(0))
            $env:FFB_INTERCEPTOR_PACKAGE_TEST = '1'
            $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY = Join-Path $handshakeRoot 'state'

            $eventName = 'Local\FFBInterceptor.ManagerElevation.v1.' +
                [Guid]::NewGuid().ToString('N').ToUpperInvariant() +
                [Guid]::NewGuid().ToString('N').ToUpperInvariant()
            $ready = [Threading.EventWaitHandle]::new(
                $false, [Threading.EventResetMode]::ManualReset, $eventName)
            try {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (
                    Join-Path $resolvedRoot 'Install-SimHubPlugin.ps1') `
                    -SimHubInstallPath $fakeSimHub -NoDashboardImport -NoPause `
                    -ManagerInvocationEvent $eventName
                if ($LASTEXITCODE -ne 0 -or -not $ready.WaitOne(0)) {
                    throw 'Installer did not complete the controlled Manager handshake.'
                }
            }
            finally { $ready.Dispose() }

            $eventName = 'Local\FFBInterceptor.ManagerElevation.v1.' +
                [Guid]::NewGuid().ToString('N').ToUpperInvariant() +
                [Guid]::NewGuid().ToString('N').ToUpperInvariant()
            $ready = [Threading.EventWaitHandle]::new(
                $false, [Threading.EventResetMode]::ManualReset, $eventName)
            try {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (
                    Join-Path $resolvedRoot 'Uninstall-SimHubPlugin.ps1') `
                    -NoPause -ManagerInvocationEvent $eventName
                if ($LASTEXITCODE -ne 0 -or -not $ready.WaitOne(0)) {
                    throw 'Uninstaller did not complete the controlled Manager handshake.'
                }
            }
            finally { $ready.Dispose() }
        }
        finally {
            $env:FFB_INTERCEPTOR_PACKAGE_TEST = $savedPackageTest
            $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY = $savedStateDirectory
        }
    }
    else {
        Write-Warning 'Controlled Manager handshake runtime fixture requires an elevated runner with SimHub closed; source and fail-closed fixtures still ran.'
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryParent) {
        Remove-Item -LiteralPath $temporaryParent -Recurse -Force
    }
}

Write-Output 'Standalone elevation-boundary fixtures passed.'
