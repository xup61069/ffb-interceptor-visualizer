# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PackagePath,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][ValidateSet('Launcher', 'SimHub')][string]$PackageKind
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($Version -cnotmatch '^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\z') {
    throw "Invalid release package version: $Version"
}
if ($PackageKind -cnotin @('Launcher', 'SimHub')) {
    throw "Invalid release package kind: $PackageKind"
}

Add-Type -AssemblyName System.IO.Compression

if ($null -eq ('FFBInterceptor.ReleaseArchiveCrc32' -as [type])) {
    Add-Type -TypeDefinition @'
using System;

namespace FFBInterceptor
{
    public static class ReleaseArchiveCrc32
    {
        public static uint Compute(byte[] data)
        {
            if (data == null) throw new ArgumentNullException("data");
            uint crc = 0xffffffffu;
            for (int index = 0; index < data.Length; index++)
            {
                crc ^= data[index];
                for (int bit = 0; bit < 8; bit++)
                    crc = (crc >> 1) ^ (0xedb88320u & (uint)-(int)(crc & 1u));
            }
            return ~crc;
        }
    }
}
'@
}

function Assert-FFBCanonicalStoredZip {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open,
        [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $reader = [IO.BinaryReader]::new($stream, [Text.UTF8Encoding]::new($false, $true), $true)
    try {
        if ($stream.Length -lt 22 -or $stream.Length -gt 256MB) {
            throw 'Release package is outside the canonical ZIP size bounds.'
        }
        [long]$eocdOffset = $stream.Length - 22
        $stream.Position = $eocdOffset
        if ($reader.ReadUInt32() -ne 0x06054B50 -or
            $reader.ReadUInt16() -ne 0 -or $reader.ReadUInt16() -ne 0) {
            throw 'Release package has no canonical single-disk EOCD.'
        }
        $entriesOnDisk = $reader.ReadUInt16()
        $entryCount = $reader.ReadUInt16()
        $centralSize = $reader.ReadUInt32()
        $centralOffset = $reader.ReadUInt32()
        $commentLength = $reader.ReadUInt16()
        if ($entryCount -lt 1 -or $entryCount -gt 64 -or
            $entriesOnDisk -ne $entryCount -or $commentLength -ne 0 -or
            [uint64]$centralOffset + [uint64]$centralSize -ne [uint64]$eocdOffset) {
            throw 'Release package EOCD is not canonical or has trailing/overlapping data.'
        }

        $utf8 = [Text.UTF8Encoding]::new($false, $true)
        $locals = [Collections.Generic.List[object]]::new()
        $stream.Position = 0
        [uint64]$totalPayload = 0
        for ($index = 0; $index -lt $entryCount; ++$index) {
            if ($stream.Position -ge $centralOffset) {
                throw 'Release package has fewer local records than its EOCD declares.'
            }
            $localOffset = [uint32]$stream.Position
            if ($reader.ReadUInt32() -ne 0x04034B50) {
                throw 'Release package local records are not contiguous and canonical.'
            }
            $versionNeeded = $reader.ReadUInt16()
            $flags = $reader.ReadUInt16()
            $method = $reader.ReadUInt16()
            $dosTime = $reader.ReadUInt16()
            $dosDate = $reader.ReadUInt16()
            $crc32 = $reader.ReadUInt32()
            $compressedSize = $reader.ReadUInt32()
            $uncompressedSize = $reader.ReadUInt32()
            $nameLength = $reader.ReadUInt16()
            $extraLength = $reader.ReadUInt16()
            if ($versionNeeded -ne 20 -or $flags -ne 0x0800 -or $method -ne 0 -or
                $dosTime -ne 0 -or $dosDate -ne 0x2821 -or
                $compressedSize -ne $uncompressedSize -or $compressedSize -gt 128MB -or
                $nameLength -lt 1 -or $extraLength -ne 0) {
                throw 'Release package local header is not canonical stored UTF-8 ZIP.'
            }
            $nameBytes = $reader.ReadBytes($nameLength)
            if ($nameBytes.Length -ne $nameLength) {
                throw 'Release package local entry name is truncated.'
            }
            try { $name = $utf8.GetString($nameBytes) }
            catch { throw 'Release package local entry name is not strict UTF-8.' }
            $data = $reader.ReadBytes([int]$compressedSize)
            if ($data.Length -ne [int]$compressedSize -or
                $stream.Position -gt $centralOffset) {
                throw "Release package local payload is truncated or overlaps metadata: $name"
            }
            $totalPayload += $compressedSize
            if ($totalPayload -gt 512MB -or
                [FFBInterceptor.ReleaseArchiveCrc32]::Compute($data) -ne $crc32) {
                throw "Release package local payload size or CRC is invalid: $name"
            }
            $locals.Add([pscustomobject]@{
                Name = $name
                NameBytes = [Convert]::ToBase64String($nameBytes)
                Crc32 = [uint32]$crc32
                Size = [uint32]$compressedSize
                Offset = [uint32]$localOffset
            })
        }
        if ($stream.Position -ne $centralOffset) {
            throw 'Release package has undeclared data between local records and central directory.'
        }

        for ($index = 0; $index -lt $entryCount; ++$index) {
            $local = $locals[$index]
            if ($reader.ReadUInt32() -ne 0x02014B50) {
                throw 'Release package central directory is truncated or non-canonical.'
            }
            $versionMadeBy = $reader.ReadUInt16()
            $versionNeeded = $reader.ReadUInt16()
            $flags = $reader.ReadUInt16()
            $method = $reader.ReadUInt16()
            $dosTime = $reader.ReadUInt16()
            $dosDate = $reader.ReadUInt16()
            $crc32 = $reader.ReadUInt32()
            $compressedSize = $reader.ReadUInt32()
            $uncompressedSize = $reader.ReadUInt32()
            $nameLength = $reader.ReadUInt16()
            $extraLength = $reader.ReadUInt16()
            $entryCommentLength = $reader.ReadUInt16()
            $diskNumber = $reader.ReadUInt16()
            $internalAttributes = $reader.ReadUInt16()
            $externalAttributes = $reader.ReadUInt32()
            $localOffset = $reader.ReadUInt32()
            if ($versionMadeBy -ne 20 -or $versionNeeded -ne 20 -or
                $flags -ne 0x0800 -or $method -ne 0 -or $dosTime -ne 0 -or
                $dosDate -ne 0x2821 -or $crc32 -ne $local.Crc32 -or
                $compressedSize -ne $local.Size -or $uncompressedSize -ne $local.Size -or
                $extraLength -ne 0 -or $entryCommentLength -ne 0 -or $diskNumber -ne 0 -or
                $internalAttributes -ne 0 -or $externalAttributes -ne 0 -or
                $localOffset -ne $local.Offset) {
                throw "Release package central/local metadata mismatch: $($local.Name)"
            }
            $nameBytes = $reader.ReadBytes($nameLength)
            if ($nameLength -lt 1 -or $nameBytes.Length -ne $nameLength -or
                [Convert]::ToBase64String($nameBytes) -cne $local.NameBytes) {
                throw "Release package central/local entry-name mismatch: $($local.Name)"
            }
        }
        if ($stream.Position -ne $eocdOffset) {
            throw 'Release package central directory size/count does not match the EOCD.'
        }
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

$archivePath = (Resolve-Path -LiteralPath $PackagePath -ErrorAction Stop).Path
$archiveItem = Get-Item -LiteralPath $archivePath -Force
if ($archiveItem.PSIsContainer -or
    ($archiveItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
    $archiveItem.Length -le 0 -or $archiveItem.Length -gt 256MB) {
    throw "$PackageKind archive must be a bounded, non-reparse regular file."
}
Assert-FFBCanonicalStoredZip -Path $archivePath

$root = "FFBInterceptor-$PackageKind-$Version"
$requiredRelativeFiles = if ($PackageKind -ceq 'Launcher') {
    @(
        'FFBInterceptor.Common.ps1',
        'FFBInterceptor.Manager.exe',
        'Start-FFBInterceptor.cmd',
        'Start-FFBInterceptor.ps1',
        'Install-SimHubPlugin.cmd',
        'Install-SimHubPlugin.ps1',
        'Uninstall-SimHubPlugin.cmd',
        'Uninstall-SimHubPlugin.ps1',
        'launcher/x64/FFBInterceptor.Launcher.exe',
        'launcher/x64/FFBInterceptor.Hook.dll',
        'launcher/x86/FFBInterceptor.Launcher.exe',
        'launcher/x86/FFBInterceptor.Hook.dll',
        'simhub/FFBInterceptor.SimHub.dll',
        'simhub/FFBInterceptor.Core.dll',
        'Dashboards/FFB Interceptor 800x480.simhubdash',
        'Dashboards/FFB Interceptor Overlay 480x160.simhubdash',
        'README.zh-TW.md',
        'MANAGER.zh-TW.md',
        'SHA256SUMS.txt',
        'LICENSE',
        'THIRD_PARTY_NOTICES.md',
        'licenses/upstream-dcs-force-feedback-fix-MIT.txt'
    )
}
else {
    @(
        'FFBInterceptor.Common.ps1',
        'Install-SimHubPlugin.cmd',
        'Install-SimHubPlugin.ps1',
        'Uninstall-SimHubPlugin.cmd',
        'Uninstall-SimHubPlugin.ps1',
        'simhub/FFBInterceptor.SimHub.dll',
        'simhub/FFBInterceptor.Core.dll',
        'Dashboards/FFB Interceptor 800x480.simhubdash',
        'Dashboards/FFB Interceptor Overlay 480x160.simhubdash',
        'INSTALL.zh-TW.md',
        'SIMHUB-README.md',
        'SHA256SUMS.txt',
        'LICENSE',
        'THIRD_PARTY_NOTICES.md',
        'licenses/upstream-dcs-force-feedback-fix-MIT.txt'
    )
}
$expectedFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($relative in $requiredRelativeFiles) {
    [void]$expectedFiles.Add("$root/$relative")
}
$allowedDirectories = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($directory in @(
    "$root/", "$root/simhub/", "$root/Dashboards/", "$root/licenses/"
) + $(if ($PackageKind -ceq 'Launcher') {
    @("$root/launcher/", "$root/launcher/x64/", "$root/launcher/x86/")
} else { @() })) {
    [void]$allowedDirectories.Add($directory)
}

$fileStream = [IO.File]::Open($archivePath, [IO.FileMode]::Open,
    [IO.FileAccess]::Read, [IO.FileShare]::Read)
$archive = $null
try {
    $archive = [IO.Compression.ZipArchive]::new(
        $fileStream, [IO.Compression.ZipArchiveMode]::Read, $false)
    $seenNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    $entries = [Collections.Generic.Dictionary[string,IO.Compression.ZipArchiveEntry]]::new(
        [StringComparer]::Ordinal)
    [long]$totalLength = 0

    foreach ($entry in $archive.Entries) {
        $name = $entry.FullName
        if ([string]::IsNullOrWhiteSpace($name) -or $name.StartsWith('/') -or
            $name.Contains('\') -or $name -match '[\x00-\x1F\x7F]' -or
            -not $seenNames.Add($name)) {
            throw "$PackageKind archive contains an unsafe or case-insensitive duplicate entry: $name"
        }
        $trimmedName = $name.TrimEnd('/')
        $segments = @($trimmedName -split '/')
        foreach ($segment in $segments) {
            if ([string]::IsNullOrWhiteSpace($segment) -or $segment -in @('.', '..') -or
                $segment.Contains(':') -or $segment.EndsWith('.') -or $segment.EndsWith(' ')) {
                throw "$PackageKind archive contains a non-canonical entry: $name"
            }
        }

        $externalAttributes = [BitConverter]::ToUInt32(
            [BitConverter]::GetBytes([int]$entry.ExternalAttributes), 0)
        $unixType = ($externalAttributes -shr 16) -band 0xF000
        $dosAttributes = $externalAttributes -band 0xFFFF

        if ($name.EndsWith('/')) {
            if ($unixType -notin @(0, 0x4000) -or
                ($dosAttributes -band 0x1440) -ne 0 -or
                -not $allowedDirectories.Contains($name) -or
                $entry.Length -ne 0 -or $entry.CompressedLength -ne 0) {
                throw "$PackageKind archive contains an unexpected directory: $name"
            }
            continue
        }
        if ($unixType -notin @(0, 0x8000) -or
            ($dosAttributes -band 0x1450) -ne 0) {
            throw "$PackageKind archive contains a non-regular, link, or reparse file entry: $name"
        }
        $baseName = [IO.Path]::GetFileName($name)
        if ($baseName -ieq 'dinput8.dll') {
            throw "$PackageKind archive unexpectedly contains dinput8.dll."
        }
        if ($baseName -iin @(
            'GameReaderCommon.dll', 'log4net.dll', 'SimHub.Logging.dll', 'SimHub.Plugins.dll'
        )) {
            throw "$PackageKind archive unexpectedly redistributes a SimHub-owned SDK dependency: $baseName"
        }
        if (-not $expectedFiles.Contains($name)) {
            throw "$PackageKind archive contains an unexpected file: $name"
        }
        if ($entry.Length -le 0 -or $entry.Length -gt 128MB) {
            throw "$PackageKind archive contains an empty or oversized file: $name"
        }
        $totalLength += $entry.Length
        if ($totalLength -gt 512MB) {
            throw "$PackageKind archive exceeds the maximum total uncompressed size."
        }
        $entries.Add($name, $entry)
    }

    if ($entries.Count -ne $expectedFiles.Count) {
        throw "$PackageKind archive does not contain the exact required file set."
    }
    foreach ($expected in $expectedFiles) {
        if (-not $entries.ContainsKey($expected)) {
            throw "$PackageKind archive is missing a required file: $expected"
        }
    }

    $manifestName = "$root/SHA256SUMS.txt"
    $manifestEntry = $entries[$manifestName]
    if ($manifestEntry.Length -gt 1MB) {
        throw "$PackageKind archive manifest exceeds the maximum size."
    }
    $manifestStream = $manifestEntry.Open()
    $manifestReader = [IO.StreamReader]::new(
        $manifestStream, [Text.UTF8Encoding]::new($false, $true), $false, 4096, $false)
    try { $manifestText = $manifestReader.ReadToEnd() }
    finally { $manifestReader.Dispose() }
    if ($manifestText.StartsWith([string][char]0xFEFF, [StringComparison]::Ordinal) -or
        $manifestText -match '\r(?!\n)') {
        throw "$PackageKind archive manifest is not canonical UTF-8 text."
    }
    $manifestBody = $manifestText.TrimEnd("`r", "`n")
    if ([string]::IsNullOrWhiteSpace($manifestBody)) {
        throw "$PackageKind archive manifest is empty."
    }
    $manifestLines = @($manifestBody -split '\r?\n')
    $expectedManifest = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($relative in $requiredRelativeFiles) {
        if ($relative -cne 'SHA256SUMS.txt') { [void]$expectedManifest.Add($relative) }
    }
    $seenManifest = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($line in $manifestLines) {
        if ($line -cnotmatch '^(?<hash>[A-F0-9]{64})  (?<name>.+)\z' -or
            -not $expectedManifest.Contains($Matches.name) -or
            -not $seenManifest.Add($Matches.name)) {
            throw "$PackageKind archive manifest contains an invalid or duplicate entry: $line"
        }
        $payloadEntry = $entries["$root/$($Matches.name)"]
        $payloadStream = $payloadEntry.Open()
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            $actualHash = [BitConverter]::ToString(
                $sha256.ComputeHash($payloadStream)).Replace('-', '')
        }
        finally {
            $sha256.Dispose()
            $payloadStream.Dispose()
        }
        if ($actualHash -cne $Matches.hash) {
            throw "$PackageKind archive manifest hash mismatch: $($Matches.name)"
        }
    }
    if ($seenManifest.Count -ne $expectedManifest.Count) {
        throw "$PackageKind archive manifest does not cover every payload file exactly once."
    }
}
finally {
    if ($archive) { $archive.Dispose() }
    $fileStream.Dispose()
}

Write-Output "Static $PackageKind archive validation passed: $archivePath"
