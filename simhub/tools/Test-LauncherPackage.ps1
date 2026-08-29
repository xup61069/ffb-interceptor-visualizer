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
    if ($names.Count -eq 0) { throw 'Launcher package is empty.' }
    $seenNames = @{}
    foreach ($name in $names) {
        if ([string]::IsNullOrWhiteSpace($name) -or $name.StartsWith('/') -or $name.Contains('\')) {
            throw "Package contains an unsafe entry name: $name"
        }
        $key = $name.ToLowerInvariant()
        if ($seenNames.ContainsKey($key)) { throw "Package contains a duplicate entry name: $name" }
        $seenNames[$key] = $true
        $segments = @($name.TrimEnd('/') -split '/')
        foreach ($segment in $segments) {
            if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.' -or $segment -eq '..' -or
                $segment.Contains(':') -or $segment.EndsWith('.') -or $segment.EndsWith(' ')) {
                throw "Package contains a non-canonical entry name: $name"
            }
        }
    }
    $roots = @($names | ForEach-Object { ($_ -split '/')[0] } | Where-Object { $_ -like 'FFBInterceptor-Launcher-*' } | Sort-Object -Unique)
    if ($roots.Count -ne 1) { throw 'Package must contain exactly one FFBInterceptor-Launcher root directory.' }
    $root = $roots[0]
    $required = @(
        "$root/FFBInterceptor.Common.ps1",
        "$root/Start-FFBInterceptor.cmd",
        "$root/Start-FFBInterceptor.ps1",
        "$root/Install-SimHubPlugin.cmd",
        "$root/Install-SimHubPlugin.ps1",
        "$root/Uninstall-SimHubPlugin.cmd",
        "$root/Uninstall-SimHubPlugin.ps1",
        "$root/launcher/x64/FFBInterceptor.Launcher.exe",
        "$root/launcher/x64/FFBInterceptor.Hook.dll",
        "$root/launcher/x86/FFBInterceptor.Launcher.exe",
        "$root/launcher/x86/FFBInterceptor.Hook.dll",
        "$root/simhub/FFBInterceptor.SimHub.dll",
        "$root/simhub/FFBInterceptor.Core.dll",
        "$root/Dashboards/FFB Interceptor 800x480.simhubdash",
        "$root/Dashboards/FFB Interceptor Overlay 480x160.simhubdash",
        "$root/README.zh-TW.md",
        "$root/SHA256SUMS.txt",
        "$root/LICENSE",
        "$root/THIRD_PARTY_NOTICES.md",
        "$root/licenses/upstream-dcs-force-feedback-fix-MIT.txt"
    )
    $files = @($names | Where-Object { -not $_.EndsWith('/') })
    foreach ($entry in $required) { if ($files -cnotcontains $entry) { throw "Package is missing required entry: $entry" } }
    foreach ($entry in $files) { if ($required -cnotcontains $entry) { throw "Package contains an unexpected file: $entry" } }
    $allowedDirectories = @(
        "$root/",
        "$root/launcher/",
        "$root/launcher/x64/",
        "$root/launcher/x86/",
        "$root/simhub/",
        "$root/Dashboards/",
        "$root/licenses/"
    )
    foreach ($entry in @($names | Where-Object { $_.EndsWith('/') })) {
        if ($allowedDirectories -cnotcontains $entry) { throw "Package contains an unexpected directory: $entry" }
    }
    if ($names | Where-Object { $_ -match '(^|/)dinput8\.dll$' }) { throw 'Launcher package must not contain dinput8.dll.' }
    if (@($names | Where-Object { $_ -like '*.exe' }).Count -ne 2) { throw 'Launcher package must contain exactly two executables.' }
    if (@($names | Where-Object { $_ -like '*.dll' }).Count -ne 4) { throw 'Launcher package must contain exactly four project DLLs.' }
    if ($names | Where-Object { $_ -match '/(SimHub\.Plugins|GameReaderCommon|SimHub\.Logging|log4net)\.dll$' }) {
        throw 'Package unexpectedly contains a SimHub-owned dependency.'
    }
}
finally { $zip.Dispose() }

$temporaryRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('ffb-launcher-package-smoke-' + [Guid]::NewGuid().ToString('N'))))
$systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $temporaryRoot.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -or
    -not ([IO.Path]::GetFileName($temporaryRoot)).StartsWith('ffb-launcher-package-smoke-', [StringComparison]::Ordinal)) {
    throw "Unsafe temporary path: $temporaryRoot"
}

$originalPackageTest = $env:FFB_INTERCEPTOR_PACKAGE_TEST
$originalTestStateDirectory = $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY
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

    foreach ($relativeScript in @(
        'FFBInterceptor.Common.ps1',
        'Install-SimHubPlugin.ps1',
        'Uninstall-SimHubPlugin.ps1',
        'Start-FFBInterceptor.ps1'
    )) {
        $scriptPath = Join-Path $packageRoot $relativeScript
        $tokens = $null
        $errors = $null
        [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors.Count -gt 0) { throw "PowerShell syntax error in packaged $relativeScript : $($errors[0].Message)" }
    }

    $manifestPath = Join-Path $packageRoot 'SHA256SUMS.txt'
    $expectedManifestEntries = @($required | Where-Object { $_ -cne "$root/SHA256SUMS.txt" } |
        ForEach-Object { $_.Substring($root.Length + 1) })
    $manifestEntries = @{}
    foreach ($line in (Get-Content -LiteralPath $manifestPath)) {
        if ($line -notmatch '^([A-F0-9]{64})  (.+)$') { throw "Invalid manifest line: $line" }
        $relative = $Matches[2]
        if ($expectedManifestEntries -cnotcontains $relative -or $manifestEntries.ContainsKey($relative)) {
            throw "Unexpected or duplicate manifest entry: $relative"
        }
        $manifestEntries[$relative] = $true
        $candidate = [IO.Path]::GetFullPath((Join-Path $packageRoot $relative))
        if (-not $candidate.StartsWith($packageRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe manifest path: $candidate"
        }
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf) -or
            (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -ne $Matches[1]) {
            throw "Manifest verification failed: $candidate"
        }
    }
    if ($manifestEntries.Count -ne $expectedManifestEntries.Count) {
        throw 'SHA256SUMS.txt does not cover every packaged file.'
    }

    $fakeSimHub = Join-Path $temporaryRoot 'fake-simhub'
    [IO.Directory]::CreateDirectory($fakeSimHub) | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $fakeSimHub 'SimHubWPF.exe'), [byte[]]@(0))

    $installer = Join-Path $packageRoot 'Install-SimHubPlugin.ps1'
    $uninstaller = Join-Path $packageRoot 'Uninstall-SimHubPlugin.ps1'
    $simHubRunning = $null -ne (Get-Process -Name 'SimHub', 'SimHubWPF' -ErrorAction SilentlyContinue)
    if (-not $simHubRunning) {
        $env:FFB_INTERCEPTOR_PACKAGE_TEST = '1'
        $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY = Join-Path $temporaryRoot 'state'

        $collision = Join-Path $fakeSimHub 'FFBInterceptor.SimHub.dll'
        [IO.Directory]::CreateDirectory($collision) | Out-Null
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -SimHubInstallPath $fakeSimHub `
            -NoElevation -NoDashboardImport -NoPause
        if ($LASTEXITCODE -eq 0) { throw 'Packaged installer accepted a directory at a managed-file destination.' }
        if (@(Get-ChildItem -LiteralPath $collision -Force).Count -ne 0) {
            throw 'Packaged installer moved a file into a managed-file destination directory.'
        }
        if (Test-Path -LiteralPath $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY) {
            throw 'Rejected directory collision created installation state.'
        }
        Remove-Item -LiteralPath $collision -Force

        $originalFiles = @{}
        foreach ($name in @('FFBInterceptor.SimHub.dll', 'FFBInterceptor.Core.dll')) {
            $destination = Join-Path $fakeSimHub $name
            [IO.File]::WriteAllText($destination, "original-$name", [Text.UTF8Encoding]::new($false))
            $originalFiles[$name] = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        }

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -SimHubInstallPath $fakeSimHub `
            -NoElevation -NoDashboardImport -NoPause
        if ($LASTEXITCODE -ne 0) { throw 'Packaged SimHub installer lifecycle smoke test failed.' }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -SimHubInstallPath $fakeSimHub `
            -NoElevation -NoDashboardImport -NoPause
        if ($LASTEXITCODE -ne 0) { throw 'Packaged SimHub installer is not idempotent.' }

        $upgradeSource = Join-Path $packageRoot 'simhub\FFBInterceptor.Core.dll'
        $upgradeSourceBytes = [IO.File]::ReadAllBytes($upgradeSource)
        $installedCore = Join-Path $fakeSimHub 'FFBInterceptor.Core.dll'
        $installedCoreHash = (Get-FileHash -LiteralPath $installedCore -Algorithm SHA256).Hash
        $stateFile = Join-Path $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY 'simhub-plugin-state.json'
        $stateHash = (Get-FileHash -LiteralPath $stateFile -Algorithm SHA256).Hash
        try {
            [IO.File]::AppendAllText($upgradeSource, 'different-package-version')
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -SimHubInstallPath $fakeSimHub `
                -NoElevation -NoDashboardImport -NoPause
            if ($LASTEXITCODE -eq 0) { throw 'Packaged installer treated a different package version as already installed.' }
            if ((Get-FileHash -LiteralPath $installedCore -Algorithm SHA256).Hash -ne $installedCoreHash) {
                throw 'Rejected package upgrade changed the installed plug-in.'
            }
            if (-not (Test-Path -LiteralPath $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY -PathType Container)) {
                throw 'Rejected package upgrade removed installation state.'
            }
            if ((Get-FileHash -LiteralPath $stateFile -Algorithm SHA256).Hash -ne $stateHash) {
                throw 'Rejected package upgrade changed installation state.'
            }
        }
        finally {
            [IO.File]::WriteAllBytes($upgradeSource, $upgradeSourceBytes)
        }

        $tampered = Join-Path $fakeSimHub 'FFBInterceptor.SimHub.dll'
        [IO.File]::AppendAllText($tampered, 'tampered')
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uninstaller -NoElevation -NoPause
        if ($LASTEXITCODE -eq 0) { throw 'Packaged uninstaller accepted a changed managed file.' }
        Copy-Item -LiteralPath (Join-Path $packageRoot 'simhub\FFBInterceptor.SimHub.dll') `
            -Destination $tampered -Force

        $directoryCollision = Join-Path $fakeSimHub 'FFBInterceptor.Core.dll'
        Remove-Item -LiteralPath $directoryCollision -Force
        [IO.Directory]::CreateDirectory($directoryCollision) | Out-Null
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uninstaller -NoElevation -NoPause
        if ($LASTEXITCODE -eq 0) { throw 'Packaged uninstaller accepted a directory at a managed-file destination.' }
        if (-not (Test-Path -LiteralPath $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY -PathType Container)) {
            throw 'Rejected uninstall directory collision removed installation state.'
        }
        Remove-Item -LiteralPath $directoryCollision -Force
        Copy-Item -LiteralPath (Join-Path $packageRoot 'simhub\FFBInterceptor.Core.dll') `
            -Destination $directoryCollision

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uninstaller -NoElevation -NoPause
        if ($LASTEXITCODE -ne 0) { throw 'Packaged SimHub uninstaller lifecycle smoke test failed.' }
        foreach ($name in $originalFiles.Keys) {
            $restored = Join-Path $fakeSimHub $name
            if ((Get-FileHash -LiteralPath $restored -Algorithm SHA256).Hash -ne $originalFiles[$name]) {
                throw "Packaged uninstaller did not restore the original file: $name"
            }
        }
        if (Test-Path -LiteralPath $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY) {
            $leftoverState = @(Get-ChildItem -LiteralPath $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY -Force)
            if ($leftoverState.Count -ne 0) { throw 'Packaged uninstaller left installation state behind.' }
        }
    }
    else {
        Write-Warning 'Full installer lifecycle smoke requires SimHub to be closed; running WhatIf only.'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -SimHubInstallPath $fakeSimHub `
            -NoElevation -NoDashboardImport -NoPause -WhatIf
        if ($LASTEXITCODE -ne 0) { throw 'Packaged SimHub installer WhatIf smoke test failed.' }
    }

    $starter = Join-Path $packageRoot 'Start-FFBInterceptor.ps1'
    foreach ($architecture in @('x64', 'x86')) {
        $testTarget = Join-Path $packageRoot "launcher\$architecture\FFBInterceptor.Launcher.exe"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $starter -GameExecutable $testTarget `
            -SkipSimHubCheck -ValidateOnly -NoPause
        if ($LASTEXITCODE -ne 0) { throw "Packaged $architecture launcher validation failed." }
    }
}
finally {
    $env:FFB_INTERCEPTOR_PACKAGE_TEST = $originalPackageTest
    $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY = $originalTestStateDirectory
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

Write-Output "Launcher package validation passed: $archivePath"
