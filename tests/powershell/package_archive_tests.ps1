# SPDX-License-Identifier: GPL-3.0-only
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression

$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$validator = Join-Path $root 'simhub\tools\Test-SimHubPackage.ps1'
. (Join-Path $root 'simhub\tools\ArchiveHelpers.ps1')
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
    $crcFixture = [IO.MemoryStream]::new([Text.Encoding]::ASCII.GetBytes('123456789'), $false)
    try { $crcFixtureValue = [FFBInterceptor.ArchiveCrc32]::Compute($crcFixture) }
    finally { $crcFixture.Dispose() }
    if ($crcFixtureValue -ne [Convert]::ToUInt32('CBF43926', 16)) {
        throw "canonical ZIP CRC-32 implementation failed its known vector: $crcFixtureValue"
    }

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

    $source = Join-Path $testRoot 'canonical-source'
    $nested = Join-Path $source 'nested'
    [IO.Directory]::CreateDirectory($nested) | Out-Null
    [IO.File]::WriteAllText((Join-Path $source 'a.txt'), 'alpha', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $nested 'z.txt'), 'omega', [Text.UTF8Encoding]::new($false))
    $binaryPayload = New-Object byte[] 131072
    for ($index = 0; $index -lt $binaryPayload.Length; $index++) {
        $binaryPayload[$index] = (($index * 31) + ($index -shr 8)) -band 0xff
    }
    [IO.File]::WriteAllBytes((Join-Path $source 'payload.bin'), $binaryPayload)
    $first = Join-Path $testRoot 'canonical-first.zip'
    $second = Join-Path $testRoot 'canonical-second.zip'
    New-CanonicalZipArchive -SourceDirectory $source -DestinationPath $first -IncludeBaseDirectory
    (Get-Item -LiteralPath (Join-Path $source 'a.txt')).LastWriteTimeUtc = [datetime]'2031-01-02T03:04:05Z'
    (Get-Item -LiteralPath (Join-Path $nested 'z.txt')).LastWriteTimeUtc = [datetime]'1999-08-07T06:05:04Z'
    New-CanonicalZipArchive -SourceDirectory $source -DestinationPath $second -IncludeBaseDirectory
    $firstHash = (Get-FileHash -LiteralPath $first -Algorithm SHA256).Hash
    $secondHash = (Get-FileHash -LiteralPath $second -Algorithm SHA256).Hash
    if ($firstHash -cne $secondHash) { throw 'canonical ZIP output changed with source timestamps' }
    $canonical = [IO.Compression.ZipFile]::OpenRead($first)
    try {
        $names = @($canonical.Entries | ForEach-Object FullName)
        $expectedNames = @(
            'canonical-source/a.txt',
            'canonical-source/nested/z.txt',
            'canonical-source/payload.bin'
        )
        if ([string]::Join('|', $names) -cne [string]::Join('|', $expectedNames)) {
            throw 'canonical ZIP entries are not in ordinal path order'
        }
        foreach ($entry in $canonical.Entries) {
            if ($entry.LastWriteTime.DateTime -ne [datetime]'2000-01-01T00:00:00') {
                throw "canonical ZIP entry timestamp changed: $($entry.FullName)"
            }
        }
    }
    finally { $canonical.Dispose() }

    $failedArchive = Join-Path $testRoot 'canonical-failed.zip'
    $lockedSource = [IO.File]::Open((Join-Path $source 'a.txt'), [IO.FileMode]::Open,
        [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $writeFailureObserved = $false
    try {
        try { New-CanonicalZipArchive -SourceDirectory $source -DestinationPath $failedArchive }
        catch { $writeFailureObserved = $true }
    }
    finally { $lockedSource.Dispose() }
    if (-not $writeFailureObserved -or (Test-Path -LiteralPath $failedArchive)) {
        throw 'failed canonical ZIP write did not remove its partial destination'
    }
    if (@(Get-ChildItem -LiteralPath $testRoot -Filter '.ffb-archive-*.tmp').Count -ne 0) {
        throw 'failed canonical ZIP write left its private working file behind'
    }

    $occupiedArchive = Join-Path $testRoot 'canonical-occupied.zip'
    [IO.File]::WriteAllText($occupiedArchive, 'owned by another build', [Text.UTF8Encoding]::new($false))
    $occupiedStream = [IO.File]::Open($occupiedArchive, [IO.FileMode]::Open,
        [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $occupiedRejected = $false
    try {
        try { New-CanonicalZipArchive -SourceDirectory $source -DestinationPath $occupiedArchive }
        catch { $occupiedRejected = $_.Exception.Message -match 'existing archive' }
    }
    finally { $occupiedStream.Dispose() }
    if (-not $occupiedRejected -or
        [IO.File]::ReadAllText($occupiedArchive, [Text.Encoding]::UTF8) -cne 'owned by another build') {
        throw 'an archive owned by another build was deleted or overwritten'
    }

    $wrongHash = '0' * 64
    $existingPublished = Join-Path $testRoot 'publish-existing.zip'
    $existingPartial = Join-Path $testRoot 'publish-existing.partial.zip'
    [IO.File]::WriteAllText($existingPublished, 'known-good-old', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($existingPartial, 'tampered-new', [Text.UTF8Encoding]::new($false))
    $existingMismatch = $false
    try {
        Publish-ValidatedArchive -PartialPath $existingPartial `
            -DestinationPath $existingPublished -ExpectedSha256 $wrongHash
    }
    catch { $existingMismatch = $_.Exception.Message -match 'does not match' }
    if (-not $existingMismatch -or
        [IO.File]::ReadAllText($existingPublished, [Text.Encoding]::UTF8) -cne 'known-good-old' -or
        (Test-Path -LiteralPath $existingPartial) -or
        @(Get-ChildItem -LiteralPath $testRoot -Filter 'publish-existing.zip.*.previous').Count -ne 0) {
        throw 'existing archive was not restored after a post-publish identity mismatch'
    }

    $firstPublished = Join-Path $testRoot 'publish-first.zip'
    $firstPartial = Join-Path $testRoot 'publish-first.partial.zip'
    [IO.File]::WriteAllText($firstPartial, 'tampered-first', [Text.UTF8Encoding]::new($false))
    $firstMismatch = $false
    try {
        Publish-ValidatedArchive -PartialPath $firstPartial `
            -DestinationPath $firstPublished -ExpectedSha256 $wrongHash
    }
    catch { $firstMismatch = $_.Exception.Message -match 'does not match' }
    if (-not $firstMismatch -or (Test-Path -LiteralPath $firstPublished) -or
        (Test-Path -LiteralPath $firstPartial)) {
        throw 'first-publish identity mismatch left an unvalidated archive behind'
    }

    $validPublished = Join-Path $testRoot 'publish-valid.zip'
    $validPartial = Join-Path $testRoot 'publish-valid.partial.zip'
    [IO.File]::WriteAllText($validPartial, 'validated', [Text.UTF8Encoding]::new($false))
    $validHash = Get-LockedFileSha256 -Path $validPartial
    [void](Publish-ValidatedArchive -PartialPath $validPartial `
        -DestinationPath $validPublished -ExpectedSha256 $validHash)
    if ((Get-LockedFileSha256 -Path $validPublished) -cne $validHash -or
        (Test-Path -LiteralPath $validPartial)) {
        throw 'valid archive publish did not preserve the validated bytes'
    }

    $caseAlias = Join-Path $testRoot 'publish-case-alias.zip'
    $caseAliasDestination = Join-Path $testRoot 'PUBLISH-CASE-ALIAS.ZIP'
    [IO.File]::WriteAllText($caseAlias, 'case-alias-owned', [Text.UTF8Encoding]::new($false))
    $caseAliasRejected = $false
    try {
        Publish-ValidatedArchive -PartialPath $caseAlias `
            -DestinationPath $caseAliasDestination `
            -ExpectedSha256 (Get-LockedFileSha256 -Path $caseAlias)
    }
    catch { $caseAliasRejected = $_.Exception.Message -match 'paths must differ' }
    if (-not $caseAliasRejected -or -not (Test-Path -LiteralPath $caseAlias) -or
        [IO.File]::ReadAllText($caseAlias, [Text.Encoding]::UTF8) -cne 'case-alias-owned') {
        throw 'case-only path aliases were not rejected without deleting the source'
    }

    $junctionTarget = Join-Path $testRoot 'junction-target'
    $junctionSource = Join-Path $testRoot 'junction-source'
    $junctionPath = Join-Path $junctionSource 'redirected'
    [IO.Directory]::CreateDirectory($junctionTarget) | Out-Null
    [IO.Directory]::CreateDirectory($junctionSource) | Out-Null
    [IO.File]::WriteAllText((Join-Path $junctionSource 'ordinary.txt'), 'ordinary',
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $junctionTarget 'outside.txt'), 'outside',
        [Text.UTF8Encoding]::new($false))
    $junctionArchive = Join-Path $testRoot 'canonical-junction.zip'
    try {
        New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget | Out-Null
        $junctionRejected = $false
        try { New-CanonicalZipArchive -SourceDirectory $junctionSource -DestinationPath $junctionArchive }
        catch { $junctionRejected = $_.Exception.Message -match 'reparse-point archive source' }
        if (-not $junctionRejected -or (Test-Path -LiteralPath $junctionArchive)) {
            throw 'a directory junction was not rejected before archive creation'
        }
    }
    finally {
        if (Test-Path -LiteralPath $junctionPath) { [IO.Directory]::Delete($junctionPath) }
    }

    if ($PSVersionTable.PSEdition -eq 'Core') {
        $ps5Archive = Join-Path $testRoot 'canonical-ps5.zip'
        $ps5Script = Join-Path $testRoot 'build-canonical-ps5.ps1'
        [IO.File]::WriteAllText($ps5Script, @'
param([string]$HelperPath, [string]$SourcePath, [string]$ArchivePath)
$ErrorActionPreference = 'Stop'
. $HelperPath
New-CanonicalZipArchive -SourceDirectory $SourcePath -DestinationPath $ArchivePath -IncludeBaseDirectory
'@, [Text.UTF8Encoding]::new($true))
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ps5Script `
            -HelperPath (Join-Path $root 'simhub\tools\ArchiveHelpers.ps1') `
            -SourcePath $source -ArchivePath $ps5Archive
        if ($LASTEXITCODE -ne 0) { throw 'Windows PowerShell canonical ZIP fixture failed' }
        $ps5Hash = (Get-FileHash -LiteralPath $ps5Archive -Algorithm SHA256).Hash
        if ($ps5Hash -cne $firstHash) {
            $firstBytes = [IO.File]::ReadAllBytes($first)
            $ps5Bytes = [IO.File]::ReadAllBytes($ps5Archive)
            $firstDifference = -1
            for ($offset = 0; $offset -lt [Math]::Min($firstBytes.Length, $ps5Bytes.Length); $offset++) {
                if ($firstBytes[$offset] -ne $ps5Bytes[$offset]) { $firstDifference = $offset; break }
            }
            throw "PowerShell 7 and Windows PowerShell 5.1 canonical ZIP bytes differ: PS7=$firstHash/$($firstBytes.Length) PS5=$ps5Hash/$($ps5Bytes.Length) first_difference=$firstDifference"
        }
    }

    Write-Host 'PASS package archive safety and deterministic-output fixtures'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
