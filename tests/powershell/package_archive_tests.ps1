# SPDX-License-Identifier: GPL-3.0-only
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression

$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$validator = Join-Path $root 'simhub\tools\Test-SimHubPackage.ps1'
$testRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) `
    ('ffb-package-archive-test-' + [Guid]::NewGuid().ToString('N'))))
$systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not $testRoot.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -or
    -not [IO.Path]::GetFileName($testRoot).StartsWith('ffb-package-archive-test-',
        [StringComparison]::Ordinal)) {
    throw "Unsafe package archive test path: $testRoot"
}

function New-FixtureArchive {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Entries
    )
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            foreach ($name in $Entries) { [void]$archive.CreateEntry($name) }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }
}

try {
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $duplicate = Join-Path $testRoot 'duplicate.zip'
    New-FixtureArchive -Path $duplicate -Entries @(
        'FFBInterceptor-SimHub-0.3.0/',
        'ffbinterceptor-simhub-0.3.0/'
    )
    $duplicateRejected = $false
    try { & $validator -PackagePath $duplicate }
    catch { $duplicateRejected = $_.Exception.Message -match 'duplicate entry name' }
    if (-not $duplicateRejected) { throw 'case-insensitive duplicate ZIP entries were not rejected' }

    $traversal = Join-Path $testRoot 'traversal.zip'
    New-FixtureArchive -Path $traversal -Entries @(
        'FFBInterceptor-SimHub-0.3.0/',
        'FFBInterceptor-SimHub-0.3.0/../escape/'
    )
    $traversalRejected = $false
    try { & $validator -PackagePath $traversal }
    catch { $traversalRejected = $_.Exception.Message -match 'non-canonical entry name' }
    if (-not $traversalRejected) { throw 'traversing ZIP directory entry was not rejected' }

    Write-Host 'PASS package archive canonicalization fixtures'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
