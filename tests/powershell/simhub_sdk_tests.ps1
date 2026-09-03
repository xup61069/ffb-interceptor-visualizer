# SPDX-License-Identifier: GPL-3.0-only
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$testRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) `
    ('ffb-simhub-sdk-test-' + [Guid]::NewGuid().ToString('N'))))
$systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $testRoot.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -or
    -not [IO.Path]::GetFileName($testRoot).StartsWith('ffb-simhub-sdk-test-', [StringComparison]::Ordinal)) {
    throw "Unsafe test path: $testRoot"
}

try {
    $sdk = Join-Path $testRoot 'sdk'
    [IO.Directory]::CreateDirectory($sdk) | Out-Null
    $files = @()
    foreach ($name in @('GameReaderCommon.dll', 'log4net.dll', 'SimHub.Logging.dll', 'SimHub.Plugins.dll')) {
        $path = Join-Path $sdk $name
        [IO.File]::WriteAllText($path, "fixture-$name", [Text.UTF8Encoding]::new($false))
        $item = Get-Item -LiteralPath $path
        $files += [ordered]@{
            name = $name
            length = $item.Length
            sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        }
    }
    $manifestPath = Join-Path $testRoot 'sdk.json'
    $manifest = [ordered]@{
        schemaVersion = 1
        profiles = @([ordered]@{ simHubVersion = 'test-profile'; testedOn = '2026-08-30'; files = $files })
    }
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))

    $result = & (Join-Path $root 'simhub\tools\Test-SimHubSdk.ps1') `
        -SimHubInstallPath $sdk -FingerprintPath $manifestPath
    if ($result -ne 'test-profile') { throw 'matching SDK fixture was not accepted' }

    $defaultLayout = Join-Path $testRoot 'default-layout'
    $defaultTools = Join-Path $defaultLayout 'tools'
    [IO.Directory]::CreateDirectory($defaultTools) | Out-Null
    $defaultScript = Join-Path $defaultTools 'Test-SimHubSdk.ps1'
    Copy-Item -LiteralPath (Join-Path $root 'simhub\tools\Test-SimHubSdk.ps1') `
        -Destination $defaultScript
    Copy-Item -LiteralPath $manifestPath `
        -Destination (Join-Path $defaultLayout 'sdk-compatibility.json')
    $legacyOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $defaultScript `
        -SimHubInstallPath $sdk 2>&1
    $legacyText = (@($legacyOutput) -join "`n").Trim()
    if ($LASTEXITCODE -ne 0 -or
        $legacyText -notmatch '(?m)^\uFEFF?test-profile\r?$') {
        throw "default SDK fingerprint path did not work under Windows PowerShell: $legacyText"
    }

    $previousErrorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $legacyBuildOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
            (Join-Path $root 'simhub\tools\Build-SimHubPackage.ps1') 2>&1
        $legacyBuildExitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousErrorPreference }
    if ($legacyBuildExitCode -eq 0 -or
        (@($legacyBuildOutput) -join "`n") -notmatch 'requires PowerShell 7') {
        throw 'SimHub package build did not reject Windows PowerShell with a clear diagnostic'
    }

    [IO.File]::AppendAllText((Join-Path $sdk 'SimHub.Plugins.dll'), 'tampered')
    $rejected = $false
    try {
        & (Join-Path $root 'simhub\tools\Test-SimHubSdk.ps1') `
            -SimHubInstallPath $sdk -FingerprintPath $manifestPath
    }
    catch {
        $rejected = $_.Exception.Message -match 'fingerprint'
    }
    if (-not $rejected) { throw 'tampered SDK fixture was not rejected' }
    Write-Host 'PASS exact SimHub SDK fingerprint gate'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
