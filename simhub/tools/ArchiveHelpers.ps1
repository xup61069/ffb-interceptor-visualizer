# SPDX-License-Identifier: GPL-3.0-only
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if ($null -eq ('FFBInterceptor.ArchiveCrc32' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;

namespace FFBInterceptor
{
    public static class ArchiveCrc32
    {
        public static uint Compute(Stream stream)
        {
            if (stream == null) throw new ArgumentNullException("stream");
            uint crc = 0xffffffffu;
            byte[] buffer = new byte[81920];
            int count;
            while ((count = stream.Read(buffer, 0, buffer.Length)) > 0)
            {
                for (int index = 0; index < count; index++)
                {
                    crc ^= buffer[index];
                    for (int bit = 0; bit < 8; bit++)
                    {
                        crc = (crc >> 1) ^ (0xedb88320u & (uint)-(int)(crc & 1u));
                    }
                }
            }
            return ~crc;
        }
    }
}
'@
}

function New-CanonicalZipArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourceDirectory,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [switch]$IncludeBaseDirectory
    )

    $sourceRoot = (Resolve-Path -LiteralPath $SourceDirectory -ErrorAction Stop).Path.TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
        throw "Archive source is not a directory: $sourceRoot"
    }
    $sourceItem = Get-Item -LiteralPath $sourceRoot -Force
    if (($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing a reparse-point archive root: $sourceRoot"
    }
    $destination = [IO.Path]::GetFullPath($DestinationPath)
    if ($destination.StartsWith($sourceRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
        throw "Archive destination must be outside its source tree: $destination"
    }
    if (Test-Path -LiteralPath $destination) {
        throw "Refusing to overwrite an existing archive: $destination"
    }
    $destinationDirectory = [IO.Path]::GetDirectoryName($destination)
    $workingDestination = [IO.Path]::GetFullPath((Join-Path $destinationDirectory (
        '.ffb-archive-' + [Guid]::NewGuid().ToString('N') + '.tmp')))
    if (-not [string]::Equals(
        [IO.Path]::GetDirectoryName($workingDestination),
        $destinationDirectory,
        [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe private archive path: $workingDestination"
    }

    $prefix = ''
    if ($IncludeBaseDirectory) {
        $prefix = [IO.Path]::GetFileName($sourceRoot)
        if ([string]::IsNullOrWhiteSpace($prefix) -or $prefix -match '[/\\:]') {
            throw "Archive source has an unsafe base name: $sourceRoot"
        }
    }

    $entries = [Collections.Generic.SortedDictionary[string, string]]::new(
        [StringComparer]::Ordinal)
    $seenEntries = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    $pendingDirectories = [Collections.Generic.Stack[string]]::new()
    $pendingDirectories.Push($sourceRoot)
    while ($pendingDirectories.Count -gt 0) {
        $currentDirectory = $pendingDirectories.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $currentDirectory -Force)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing a reparse-point archive source: $($item.FullName)"
            }
            $fullItem = [IO.Path]::GetFullPath($item.FullName)
            if (-not $fullItem.StartsWith($sourceRoot + [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase)) {
                throw "Archive source escaped its root: $fullItem"
            }
            if ($item.PSIsContainer) {
                $pendingDirectories.Push($fullItem)
                continue
            }
            $relative = $fullItem.Substring($sourceRoot.Length + 1).Replace('\', '/')
            $entryName = if ($prefix) { "$prefix/$relative" } else { $relative }
            if ($entryName.StartsWith('/', [StringComparison]::Ordinal) -or
                $entryName.Contains('\') -or
                $entryName.IndexOf([char]0) -ge 0 -or
                @($entryName.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) {
                throw "Refusing a non-canonical archive entry name: $entryName"
            }
            if (-not $seenEntries.Add($entryName) -or $entries.ContainsKey($entryName)) {
                throw "Refusing a duplicate archive entry name: $entryName"
            }
            $entries.Add($entryName, $fullItem)
        }
    }
    if ($entries.Count -eq 0) { throw "Archive source contains no files: $sourceRoot" }

    $complete = $false
    $destinationCreated = $false
    $fileStream = $null
    $binaryWriter = $null
    try {
        $fileStream = [IO.File]::Open($workingDestination, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        $destinationCreated = $true
        $binaryWriter = [IO.BinaryWriter]::new(
            $fileStream, [Text.UTF8Encoding]::new($false), $true)
        try {
            $centralEntries = [Collections.Generic.List[object]]::new()
            $utf8 = [Text.UTF8Encoding]::new($false)
            $dosTime = [uint16]0
            $dosDate = [uint16]0x2821
            foreach ($pair in $entries.GetEnumerator()) {
                $nameBytes = $utf8.GetBytes($pair.Key)
                if ($nameBytes.Length -gt [uint16]::MaxValue) {
                    throw "Archive entry name is too long: $($pair.Key)"
                }
                if ($fileStream.Position -ge [uint32]::MaxValue) {
                    throw 'Archive exceeds the classic ZIP offset limit.'
                }
                $localOffset = [uint32]$fileStream.Position
                $input = [IO.File]::Open($pair.Value, [IO.FileMode]::Open,
                    [IO.FileAccess]::Read, [IO.FileShare]::Read)
                try {
                    if ($input.Length -ge [uint32]::MaxValue) {
                        throw "Archive entry exceeds the classic ZIP size limit: $($pair.Key)"
                    }
                    $entrySize = [uint32]$input.Length
                    $crc32 = [FFBInterceptor.ArchiveCrc32]::Compute($input)
                    $input.Position = 0

                    $binaryWriter.Write([uint32]0x04034b50)
                    $binaryWriter.Write([uint16]20)
                    $binaryWriter.Write([uint16]0x0800)
                    $binaryWriter.Write([uint16]0)
                    $binaryWriter.Write($dosTime)
                    $binaryWriter.Write($dosDate)
                    $binaryWriter.Write([uint32]$crc32)
                    $binaryWriter.Write($entrySize)
                    $binaryWriter.Write($entrySize)
                    $binaryWriter.Write([uint16]$nameBytes.Length)
                    $binaryWriter.Write([uint16]0)
                    $binaryWriter.Write($nameBytes)
                    $binaryWriter.Flush()
                    $input.CopyTo($fileStream)
                    $centralEntries.Add([pscustomobject]@{
                        NameBytes = $nameBytes
                        Crc32 = [uint32]$crc32
                        Size = $entrySize
                        LocalOffset = $localOffset
                    })
                }
                finally { $input.Dispose() }
            }

            if ($centralEntries.Count -ge [uint16]::MaxValue) {
                throw 'Archive has too many entries for classic ZIP.'
            }
            if ($fileStream.Position -ge [uint32]::MaxValue) {
                throw 'Archive exceeds the classic ZIP offset limit.'
            }
            $centralOffset = [uint32]$fileStream.Position
            foreach ($entry in $centralEntries) {
                $binaryWriter.Write([uint32]0x02014b50)
                $binaryWriter.Write([uint16]20)
                $binaryWriter.Write([uint16]20)
                $binaryWriter.Write([uint16]0x0800)
                $binaryWriter.Write([uint16]0)
                $binaryWriter.Write($dosTime)
                $binaryWriter.Write($dosDate)
                $binaryWriter.Write([uint32]$entry.Crc32)
                $binaryWriter.Write([uint32]$entry.Size)
                $binaryWriter.Write([uint32]$entry.Size)
                $binaryWriter.Write([uint16]$entry.NameBytes.Length)
                $binaryWriter.Write([uint16]0)
                $binaryWriter.Write([uint16]0)
                $binaryWriter.Write([uint16]0)
                $binaryWriter.Write([uint16]0)
                $binaryWriter.Write([uint32]0)
                $binaryWriter.Write([uint32]$entry.LocalOffset)
                $binaryWriter.Write([byte[]]$entry.NameBytes)
            }
            $centralSizeValue = $fileStream.Position - $centralOffset
            if ($centralSizeValue -ge [uint32]::MaxValue) {
                throw 'Archive central directory exceeds the classic ZIP size limit.'
            }
            $entryCount = [uint16]$centralEntries.Count
            $binaryWriter.Write([uint32]0x06054b50)
            $binaryWriter.Write([uint16]0)
            $binaryWriter.Write([uint16]0)
            $binaryWriter.Write($entryCount)
            $binaryWriter.Write($entryCount)
            $binaryWriter.Write([uint32]$centralSizeValue)
            $binaryWriter.Write($centralOffset)
            $binaryWriter.Write([uint16]0)
            $binaryWriter.Flush()
        }
        finally {
            try {
                if ($null -ne $binaryWriter) { $binaryWriter.Dispose() }
            }
            finally {
                $binaryWriter = $null
                try {
                    if ($null -ne $fileStream) { $fileStream.Dispose() }
                }
                finally { $fileStream = $null }
            }
        }
        [IO.File]::Move($workingDestination, $destination)
        $destinationCreated = $false
        $complete = $true
    }
    finally {
        try {
            try {
                if ($null -ne $binaryWriter) { $binaryWriter.Dispose() }
            }
            finally {
                $binaryWriter = $null
                try {
                    if ($null -ne $fileStream) { $fileStream.Dispose() }
                }
                finally { $fileStream = $null }
            }
        }
        finally {
            if ($destinationCreated -and -not $complete -and
                (Test-Path -LiteralPath $workingDestination -PathType Leaf)) {
                Remove-Item -LiteralPath $workingDestination -Force
            }
        }
    }
}

function Get-LockedFileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolved = [IO.Path]::GetFullPath($Path)
    $stream = [IO.File]::Open($resolved, [IO.FileMode]::Open,
        [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
}

function Publish-ValidatedArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PartialPath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )

    if ($ExpectedSha256 -cnotmatch '^[A-F0-9]{64}$') {
        throw 'Expected archive SHA-256 is invalid.'
    }
    $partial = [IO.Path]::GetFullPath($PartialPath)
    $destination = [IO.Path]::GetFullPath($DestinationPath)
    if (-not (Test-Path -LiteralPath $partial -PathType Leaf)) {
        throw "Validated partial archive is missing: $partial"
    }
    if (-not [string]::Equals(
        [IO.Path]::GetDirectoryName($partial),
        [IO.Path]::GetDirectoryName($destination),
        [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Validated archive publish must stay on one directory and volume.'
    }
    if ([string]::Equals($partial, $destination, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Partial and published archive paths must differ.'
    }

    $previous = $destination + '.' + [Guid]::NewGuid().ToString('N') + '.previous'
    $replacedExisting = Test-Path -LiteralPath $destination -PathType Leaf
    $publishRenamed = $false
    try {
        if ($replacedExisting) {
            [IO.File]::Replace($partial, $destination, $previous, $true)
        }
        else {
            [IO.File]::Move($partial, $destination)
        }
        $publishRenamed = $true

        $publishedHash = Get-LockedFileSha256 -Path $destination
        if ($publishedHash -cne $ExpectedSha256) {
            throw 'Published archive does not match the validated bytes.'
        }
        if (Test-Path -LiteralPath $previous -PathType Leaf) {
            Remove-Item -LiteralPath $previous -Force
        }
        return $publishedHash
    }
    catch {
        $publishError = $_
        $rollbackError = $null
        if ($publishRenamed -and $replacedExisting -and
            (Test-Path -LiteralPath $previous -PathType Leaf)) {
            try {
                if (Test-Path -LiteralPath $destination -PathType Leaf) {
                    $rejected = $destination + '.' + [Guid]::NewGuid().ToString('N') + '.rejected'
                    [IO.File]::Replace($previous, $destination, $rejected, $true)
                    Remove-Item -LiteralPath $rejected -Force
                }
                else {
                    [IO.File]::Move($previous, $destination)
                }
            }
            catch { $rollbackError = $_ }
        }
        elseif ($publishRenamed -and -not $replacedExisting -and
            (Test-Path -LiteralPath $destination -PathType Leaf)) {
            try { Remove-Item -LiteralPath $destination -Force }
            catch { $rollbackError = $_ }
        }
        if ($null -ne $rollbackError) {
            throw "Archive publish failed and rollback also failed; recovery copy, if any, is at '$previous': $($rollbackError.Exception.Message)"
        }
        throw $publishError
    }
    finally {
        if (Test-Path -LiteralPath $partial -PathType Leaf) {
            Remove-Item -LiteralPath $partial -Force
        }
    }
}
