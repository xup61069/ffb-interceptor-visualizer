# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ManagerPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Read-FFBUInt16 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes, [Parameter(Mandatory = $true)][long]$Offset)
    if ($Offset -lt 0 -or $Offset -gt $Bytes.LongLength - 2) { throw 'Stable Manager has a truncated PE field.' }
    return [BitConverter]::ToUInt16($Bytes, [int]$Offset)
}

function Read-FFBUInt32 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes, [Parameter(Mandatory = $true)][long]$Offset)
    if ($Offset -lt 0 -or $Offset -gt $Bytes.LongLength - 4) { throw 'Stable Manager has a truncated PE field.' }
    return [BitConverter]::ToUInt32($Bytes, [int]$Offset)
}

$resolvedManager = (Resolve-Path -LiteralPath $ManagerPath -ErrorAction Stop).Path
$managerInfo = Get-Item -LiteralPath $resolvedManager -Force
if ($managerInfo.PSIsContainer -or ($managerInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
    $managerInfo.Length -le 0 -or $managerInfo.Length -gt 32MB) {
    throw 'Stable Manager is not a regular file or has an invalid file size.'
}

# Parse raw bytes instead of loading the candidate EXE. Loading it merely to
# inspect build policy would allow untrusted loader behavior to execute.
$bytes = [IO.File]::ReadAllBytes($resolvedManager)
if ($bytes.LongLength -le 0 -or $bytes.LongLength -gt 32MB) {
    throw 'Stable Manager changed to an invalid file size while it was being read.'
}
$ascii = [Text.Encoding]::ASCII.GetString($bytes)
$prefix = 'FFB_MANAGER_BUILD_POLICY_V1|'
$prefixMatches = [Text.RegularExpressions.Regex]::Matches(
    $ascii, [Text.RegularExpressions.Regex]::Escape($prefix))
if ($prefixMatches.Count -ne 1) {
    throw "Stable Manager must contain exactly one build-policy marker; found $($prefixMatches.Count)."
}
$markerPattern = 'FFB_MANAGER_BUILD_POLICY_V1\|MODE=STABLE\|SIGNER_SHA256=([A-F0-9]{64})\|END\x00'
$markerMatches = [Text.RegularExpressions.Regex]::Matches($ascii, $markerPattern)
if ($markerMatches.Count -ne 1 -or $markerMatches[0].Index -ne $prefixMatches[0].Index) {
    throw 'Stable Manager build-policy marker is missing, malformed, unpinned, or not NUL-terminated.'
}

if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
    throw 'Stable Manager is not a valid PE image.'
}
$peOffset = [long](Read-FFBUInt32 -Bytes $bytes -Offset 0x3C)
if ($peOffset -gt $bytes.LongLength - 24 -or
    $bytes[[int]$peOffset] -ne 0x50 -or $bytes[[int]$peOffset + 1] -ne 0x45 -or
    $bytes[[int]$peOffset + 2] -ne 0 -or $bytes[[int]$peOffset + 3] -ne 0) {
    throw 'Stable Manager has an invalid PE signature.'
}
$sectionCount = [int](Read-FFBUInt16 -Bytes $bytes -Offset ($peOffset + 6))
if ($sectionCount -lt 1 -or $sectionCount -gt 96) {
    throw 'Stable Manager has an invalid PE section count.'
}
$optionalHeaderSize = [long](Read-FFBUInt16 -Bytes $bytes -Offset ($peOffset + 20))
$optionalHeaderOffset = $peOffset + 24
if ($optionalHeaderSize -lt 2 -or
    $optionalHeaderOffset -gt $bytes.LongLength - $optionalHeaderSize) {
    throw 'Stable Manager has an invalid PE optional header.'
}
$optionalMagic = Read-FFBUInt16 -Bytes $bytes -Offset $optionalHeaderOffset
if ($optionalMagic -ne 0x10B -and $optionalMagic -ne 0x20B) {
    throw 'Stable Manager is not a PE32 or PE32+ image.'
}
$sectionTableOffset = $optionalHeaderOffset + $optionalHeaderSize
$sectionTableBytes = [long]$sectionCount * 40
if ($sectionTableOffset -gt $bytes.LongLength - $sectionTableBytes) {
    throw 'Stable Manager has a truncated PE section table.'
}

$markerOffset = [long]$markerMatches[0].Index
$markerEnd = $markerOffset + [long]$markerMatches[0].Length
$containingSections = @()
for ($index = 0; $index -lt $sectionCount; $index++) {
    $sectionOffset = $sectionTableOffset + ([long]$index * 40)
    $sectionName = [Text.Encoding]::ASCII.GetString($bytes, [int]$sectionOffset, 8).TrimEnd([char]0)
    $virtualSize = [long](Read-FFBUInt32 -Bytes $bytes -Offset ($sectionOffset + 8))
    $rawSize = [long](Read-FFBUInt32 -Bytes $bytes -Offset ($sectionOffset + 16))
    $rawOffset = [long](Read-FFBUInt32 -Bytes $bytes -Offset ($sectionOffset + 20))
    $characteristics = Read-FFBUInt32 -Bytes $bytes -Offset ($sectionOffset + 36)
    if ($rawSize -gt 0 -and $rawOffset -gt $bytes.LongLength - $rawSize) {
        throw "Stable Manager PE section has an invalid file range: $sectionName"
    }
    $markerRelativeOffset = $markerOffset - $rawOffset
    $markerRelativeEnd = $markerEnd - $rawOffset
    if ($rawSize -gt 0 -and $virtualSize -gt 0 -and
        $markerRelativeOffset -ge 0 -and
        $markerRelativeEnd -le $rawSize -and
        $markerRelativeEnd -le $virtualSize) {
        $containingSections += [pscustomobject]@{
            Name = $sectionName
            Characteristics = [uint32]$characteristics
        }
    }
}
if ($containingSections.Count -ne 1) {
    throw 'Stable Manager build-policy marker is not contained in exactly one PE section.'
}
$policySection = $containingSections[0]
$imageScnCntInitializedData = [uint32]0x00000040
$imageScnMemExecute = [uint32]0x20000000
$imageScnMemRead = [uint32]0x40000000
$imageScnMemWrite = [uint32]2147483648
if ($policySection.Name -cne '.rdata' -or
    ($policySection.Characteristics -band $imageScnCntInitializedData) -eq 0 -or
    ($policySection.Characteristics -band $imageScnMemRead) -eq 0 -or
    ($policySection.Characteristics -band ($imageScnMemWrite -bor $imageScnMemExecute)) -ne 0) {
    throw 'Stable Manager build-policy marker must be mapped initialized data inside the read-only, non-executable .rdata PE section.'
}

Write-Output $markerMatches[0].Groups[1].Value
