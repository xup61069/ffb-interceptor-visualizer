# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PhysicalRuntimeRoot,
    [Parameter(Mandatory = $true)]
    [string]$RunnerTemp,
    [Parameter(Mandatory = $true)]
    [string]$RunnerToolCache,
    [string]$Workspace = '',
    [string]$RepositorySlug = $env:GITHUB_REPOSITORY
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Resolve-ExactDirectory([string]$Path, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt 1024 -or
        $Path -cnotmatch '^[A-Za-z]:\\' -or $Path.IndexOfAny([char[]]'*?') -ge 0) {
        throw "$Name must be a bounded absolute local-drive directory."
    }
    if ($Path.EndsWith('\', [StringComparison]::Ordinal) -or
        $Path -match '(?:^|\\)\.{1,2}(?:\\|$)' -or
        $Path.Substring(2).Contains(':')) {
        throw "$Name must not contain a trailing separator, dot segment, or alternate data stream."
    }
    $full = [IO.Path]::GetFullPath($Path)
    $resolved = (Resolve-Path -LiteralPath $full -ErrorAction Stop).Path
    if ($resolved -ine $full -or -not (Test-Path -LiteralPath $resolved -PathType Container)) {
        throw "$Name must resolve exactly to an existing directory."
    }
    return $resolved
}

function Assert-NoReparseSegments([string]$Root, [string]$Path, [string]$Name) {
    $rootPath = $Root.TrimEnd('\')
    if ($rootPath -match '^[A-Za-z]:$') { $rootPath += '\' }
    $rootPrefix = $rootPath.TrimEnd('\') + '\'
    if ($Path -ine $rootPath -and
        -not $Path.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name escaped its bound root."
    }
    $rootItem = Get-Item -LiteralPath $rootPath -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Name root contains a reparse point: $rootPath"
    }
    $current = $rootPath
    $relative = if ($Path.Length -gt $rootPath.Length) {
        $Path.Substring($rootPath.Length).TrimStart('\')
    } else { '' }
    foreach ($segment in @($relative -split '\\' | Where-Object { $_ })) {
        $current = [IO.Path]::Combine($current, $segment)
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Name contains a reparse point: $current"
        }
    }
}

if (-not ('Ffb.ReleaseGate.DirectoryIdentity' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Ffb.ReleaseGate {
    public static class DirectoryIdentity {
        [StructLayout(LayoutKind.Sequential)]
        private struct FileInformation {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string fileName, uint desiredAccess, uint shareMode, IntPtr securityAttributes,
            uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle file, out FileInformation information);

        private static FileInformation GetIdentity(string path) {
            const uint FileReadAttributes = 0x80;
            const uint ShareAll = 0x1 | 0x2 | 0x4;
            const uint OpenExisting = 3;
            const uint BackupSemantics = 0x02000000;
            using (SafeFileHandle handle = CreateFileW(path, FileReadAttributes, ShareAll,
                    IntPtr.Zero, OpenExisting, BackupSemantics, IntPtr.Zero)) {
                if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                FileInformation value;
                if (!GetFileInformationByHandle(handle, out value))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                return value;
            }
        }

        public static bool Same(string left, string right) {
            FileInformation a = GetIdentity(left);
            FileInformation b = GetIdentity(right);
            return a.VolumeSerialNumber == b.VolumeSerialNumber &&
                a.FileIndexHigh == b.FileIndexHigh && a.FileIndexLow == b.FileIndexLow;
        }
    }
}
'@
}

function Convert-ToPhysicalCounterpart(
    [string]$MappedPath, [string]$MappedRoot, [string]$PhysicalRoot, [string]$Name) {
    if (-not $MappedPath.StartsWith($MappedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name is outside the state-bound mapped drive."
    }
    $relative = $MappedPath.Substring($MappedRoot.Length)
    $candidate = [IO.Path]::GetFullPath([IO.Path]::Combine($PhysicalRoot, $relative))
    $physicalPrefix = $PhysicalRoot.TrimEnd('\') + '\'
    if ($candidate -ine $PhysicalRoot -and
        -not $candidate.StartsWith($physicalPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name physical counterpart escaped the disposable runtime."
    }
    return Resolve-ExactDirectory $candidate "$Name physical counterpart"
}

$physicalRoot = Resolve-ExactDirectory $PhysicalRuntimeRoot 'Physical runtime root'
if ($physicalRoot -cnotmatch '^C:\\ffb-v1-[0-9a-f]{32}$') {
    throw 'Physical runtime root is outside the bound disposable runtime pattern.'
}
$temp = Resolve-ExactDirectory $RunnerTemp 'RUNNER_TEMP'
if ($temp -cnotmatch '^(?<drive>[D-Z]):\\_work\\_temp$') {
    throw 'RUNNER_TEMP must be exactly <D-Z>:\_work\_temp.'
}
$drive = $Matches.drive.ToUpperInvariant() + ':'
$mappedRoot = $drive + '\'
$mappedWork = $drive + '\_work'
$toolCache = Resolve-ExactDirectory $RunnerToolCache 'RUNNER_TOOL_CACHE'
if ($toolCache -cne ($drive + '\ToolCache')) {
    throw 'RUNNER_TOOL_CACHE must be exactly on the state-bound mapped drive.'
}

$resolvedWorkspace = ''
if (-not [string]::IsNullOrWhiteSpace($Workspace)) {
    $resolvedWorkspace = Resolve-ExactDirectory $Workspace 'GITHUB_WORKSPACE'
    if ($RepositorySlug -cnotmatch '^[A-Za-z0-9_.-]+/(?<repo>[A-Za-z0-9_.-]+)$') {
        throw 'GITHUB_REPOSITORY must be a canonical owner/repository slug.'
    }
    $repositoryName = [string]$Matches.repo
    $expectedWorkspace = [IO.Path]::Combine($mappedWork, $repositoryName, $repositoryName)
    if ($resolvedWorkspace -ine $expectedWorkspace) {
        throw 'GITHUB_WORKSPACE must be exactly <drive>:\_work\<repository>\<repository>.'
    }
}

$physicalWork = Convert-ToPhysicalCounterpart $mappedWork $mappedRoot $physicalRoot `
    'Mapped runner work root'
$physicalTemp = Convert-ToPhysicalCounterpart $temp $mappedRoot $physicalRoot 'RUNNER_TEMP'
$physicalToolCache = Convert-ToPhysicalCounterpart $toolCache $mappedRoot $physicalRoot `
    'RUNNER_TOOL_CACHE'
$physicalWorkspace = if ($resolvedWorkspace) {
    Convert-ToPhysicalCounterpart $resolvedWorkspace $mappedRoot $physicalRoot 'GITHUB_WORKSPACE'
} else { '' }

Assert-NoReparseSegments $physicalRoot $physicalRoot 'Physical runtime root'
Assert-NoReparseSegments $physicalRoot $physicalWork 'Physical runner work root'
Assert-NoReparseSegments $physicalRoot $physicalTemp 'RUNNER_TEMP physical counterpart'
Assert-NoReparseSegments $physicalRoot $physicalToolCache 'RUNNER_TOOL_CACHE physical counterpart'
Assert-NoReparseSegments $mappedRoot $mappedRoot 'Mapped runtime root'
Assert-NoReparseSegments $mappedRoot $mappedWork 'Mapped runner work root'
Assert-NoReparseSegments $mappedRoot $temp 'RUNNER_TEMP'
Assert-NoReparseSegments $mappedRoot $toolCache 'RUNNER_TOOL_CACHE'
if ($resolvedWorkspace) {
    Assert-NoReparseSegments $physicalRoot $physicalWorkspace 'GITHUB_WORKSPACE physical counterpart'
    Assert-NoReparseSegments $mappedRoot $resolvedWorkspace 'GITHUB_WORKSPACE'
}

$pairs = [Collections.Generic.List[object]]::new()
$pairs.Add([object[]]@($mappedRoot, $physicalRoot, 'runtime root'))
$pairs.Add([object[]]@($mappedWork, $physicalWork, 'runner work root'))
$pairs.Add([object[]]@($temp, $physicalTemp, 'RUNNER_TEMP'))
$pairs.Add([object[]]@($toolCache, $physicalToolCache, 'RUNNER_TOOL_CACHE'))
if ($resolvedWorkspace) {
    $pairs.Add([object[]]@($resolvedWorkspace, $physicalWorkspace, 'GITHUB_WORKSPACE'))
}
foreach ($pair in $pairs) {
    if (-not [Ffb.ReleaseGate.DirectoryIdentity]::Same($pair[0], $pair[1])) {
        throw "$($pair[2]) mapped/physical directory identity mismatch."
    }
}

[pscustomobject]@{
    RunnerDrive = $drive
    MappedRoot = $mappedRoot
    MappedWorkRoot = $mappedWork
    PhysicalRuntimeRoot = $physicalRoot
    PhysicalWorkRoot = $physicalWork
    RunnerTemp = $temp
    PhysicalRunnerTemp = $physicalTemp
    RunnerToolCache = $toolCache
    PhysicalRunnerToolCache = $physicalToolCache
    Workspace = $resolvedWorkspace
    PhysicalWorkspace = $physicalWorkspace
}
