# SPDX-License-Identifier: GPL-3.0-only

function Test-FFBAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FFBFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '') }
    finally { $sha256.Dispose(); $stream.Dispose() }
}

function Assert-FFBPackageManifest {
    param([Parameter(Mandatory = $true)][string]$BundleRoot)
    $root = Get-FFBNormalizedLocalPath -Path $BundleRoot
    $manifest = Join-Path $root 'SHA256SUMS.txt'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        throw "Package manifest is missing: $manifest"
    }
    $manifestItem = Get-Item -LiteralPath $manifest -Force
    if (($manifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        $manifestItem.Length -gt 1048576) {
        throw 'Package manifest is unsafe or too large.'
    }
    $expected = @{}
    foreach ($line in [IO.File]::ReadAllLines($manifest, [Text.Encoding]::UTF8)) {
        if ($line -notmatch '^([A-Fa-f0-9]{64})  (.+)$') { throw "Invalid package manifest line: $line" }
        $relative = $Matches[2].Replace('/', '\')
        if ([IO.Path]::IsPathRooted($relative) -or $relative.Contains(':')) {
            throw "Unsafe package manifest path: $relative"
        }
        $segments = @($relative -split '\\')
        if ($segments.Count -eq 0 -or @($segments | Where-Object {
            [string]::IsNullOrWhiteSpace($_) -or $_ -eq '.' -or $_ -eq '..' -or
            $_.EndsWith('.') -or $_.EndsWith(' ')
        }).Count -gt 0) { throw "Non-canonical package manifest path: $relative" }
        $key = $relative.ToLowerInvariant()
        if ($expected.ContainsKey($key) -or $expected.Count -ge 128) {
            throw "Duplicate or excessive package manifest entry: $relative"
        }
        $candidate = [IO.Path]::GetFullPath((Join-Path $root $relative))
        if (-not (Test-FFBPathWithinOrEqual -Path $candidate -Parent $root)) {
            throw "Package manifest entry escapes the package: $relative"
        }
        $expected[$key] = [pscustomobject]@{ Path = $candidate; Hash = $Matches[1].ToUpperInvariant() }
    }
    $actualFiles = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force |
        Where-Object { -not (Test-FFBPathEqual -Left $_.FullName -Right $manifest) })
    if ($actualFiles.Count -ne $expected.Count) {
        throw 'Package manifest does not cover the exact extracted file set.'
    }
    foreach ($file in $actualFiles) {
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Package file cannot be a reparse point: $($file.FullName)"
        }
        $relative = $file.FullName.Substring($root.Length + 1).ToLowerInvariant()
        $record = $expected[$relative]
        if ($null -eq $record -or -not (Test-FFBPathEqual -Left $record.Path -Right $file.FullName) -or
            (Get-FFBFileSha256 -Path $file.FullName) -cne $record.Hash) {
            throw "Package manifest verification failed: $($file.FullName)"
        }
    }
    return $true
}

function Get-FFBStateDirectory {
    if ($env:FFB_INTERCEPTOR_PACKAGE_TEST -eq '1' -and
        -not [string]::IsNullOrWhiteSpace($env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY)) {
        $override = Get-FFBNormalizedLocalPath -Path $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY
        $temporaryRoot = Get-FFBNormalizedLocalPath -Path ([IO.Path]::GetTempPath())
        if (-not (Test-FFBPathWithinOrEqual -Path $override -Parent $temporaryRoot) -or
            $override -notmatch '(?i)[\\/]ffb-launcher-package-smoke-[a-f0-9]+[\\/]state$') {
            throw "Unsafe isolated package-test state path: $override"
        }
        return $override
    }
    $commonData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if ([string]::IsNullOrWhiteSpace($commonData)) { throw 'Common application data is unavailable.' }
    return Join-Path $commonData 'FFBInterceptor'
}

function Get-FFBStatePath {
    return Join-Path (Get-FFBStateDirectory) 'simhub-plugin-state.json'
}

function Get-FFBNormalizedLocalPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^[A-Za-z]:[\\/]') {
        throw "Only an absolute local drive path is allowed: $Path"
    }
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) {
        $full = $full.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    }
    return $full
}

function Test-FFBPathWithinOrEqual {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Parent
    )
    if ($Path.Equals($Parent, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $parentPrefix = $Parent.TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) +
        [IO.Path]::DirectorySeparatorChar
    return $Path.StartsWith($parentPrefix,
        [StringComparison]::OrdinalIgnoreCase)
}

function Test-FFBPathEqual {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )
    return $Left.Equals($Right, [StringComparison]::OrdinalIgnoreCase)
}

if ($null -eq ('FFBInterceptor.DirectoryMutationLock' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

namespace FFBInterceptor
{
    public static class DirectoryMutationLock
    {
        private const uint FileReadAttributes = 0x00000080;
        private const uint DeleteAccess = 0x00010000;
        private const uint FileShareRead = 0x00000001;
        private const uint FileShareWrite = 0x00000002;
        private const uint OpenExisting = 3;
        private const uint CreateNew = 1;
        private const uint FileAttributeDirectory = 0x00000010;
        private const uint FileAttributeReparsePoint = 0x00000400;
        private const uint FileAttributeTemporary = 0x00000100;
        private const uint FileFlagDeleteOnClose = 0x04000000;
        private const uint FileFlagOpenReparsePoint = 0x00200000;
        private const uint FileFlagBackupSemantics = 0x02000000;
        private const uint DriveFixed = 3;

        [StructLayout(LayoutKind.Sequential)]
        private struct ByHandleFileInformation
        {
            internal uint FileAttributes;
            internal System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            internal System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            internal System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            internal uint VolumeSerialNumber;
            internal uint FileSizeHigh;
            internal uint FileSizeLow;
            internal uint NumberOfLinks;
            internal uint FileIndexHigh;
            internal uint FileIndexLow;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle file,
            out ByHandleFileInformation information);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(
            SafeFileHandle file,
            StringBuilder filePath,
            uint filePathLength,
            uint flags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern uint GetDriveTypeW(string rootPathName);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint QueryDosDeviceW(
            string deviceName,
            StringBuilder targetPath,
            int maximumSize);

        public static string GetStableFixedDriveTarget(string driveRoot)
        {
            if (String.IsNullOrWhiteSpace(driveRoot) || driveRoot.Length < 2 ||
                driveRoot[1] != ':')
                throw new InvalidOperationException("Path is not rooted on a DOS drive");
            if (GetDriveTypeW(driveRoot) != DriveFixed)
                throw new InvalidOperationException(
                    "SimHub must be installed on a fixed local drive");

            StringBuilder target = new StringBuilder(32768);
            if (QueryDosDeviceW(driveRoot.Substring(0, 2), target, target.Capacity) == 0)
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(), "Unable to resolve the SimHub drive");

            string value = target.ToString();
            if (!IsPhysicalVolumeDeviceName(value))
                throw new InvalidOperationException(
                    "SimHub drive is not backed by a stable physical volume");
            return value;
        }

        public static bool IsPhysicalVolumeDeviceName(string target)
        {
            return !String.IsNullOrWhiteSpace(target) && Regex.IsMatch(
                target,
                @"^\\Device\\HarddiskVolume[0-9]+$",
                RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        }

        public static SafeFileHandle OpenDirectory(string path)
        {
            SafeFileHandle handle = CreateFileW(
                path,
                FileReadAttributes,
                FileShareRead | FileShareWrite,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "Unable to lock directory");
            }

            try
            {
                ByHandleFileInformation information;
                if (!GetFileInformationByHandle(handle, out information))
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(), "Unable to inspect locked directory");
                if ((information.FileAttributes & FileAttributeDirectory) == 0)
                    throw new InvalidOperationException("Locked path is not a directory");
                if ((information.FileAttributes & FileAttributeReparsePoint) != 0)
                    throw new InvalidOperationException("Locked directory is a reparse point");
                return handle;
            }
            catch
            {
                handle.Dispose();
                throw;
            }
        }

        public static string GetIdentity(SafeFileHandle handle)
        {
            ByHandleFileInformation information;
            if (handle == null || handle.IsInvalid ||
                !GetFileInformationByHandle(handle, out information))
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(), "Unable to identify locked directory");
            return String.Format("{0:X8}:{1:X8}:{2:X8}",
                information.VolumeSerialNumber,
                information.FileIndexHigh,
                information.FileIndexLow);
        }

        public static SafeFileHandle OpenMutationSentinel(string path)
        {
            SafeFileHandle handle = CreateFileW(
                path,
                FileReadAttributes | DeleteAccess,
                FileShareRead | FileShareWrite,
                IntPtr.Zero,
                CreateNew,
                FileAttributeTemporary | FileFlagDeleteOnClose,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "Unable to create destination lock file");
            }

            try
            {
                StringBuilder finalPath = new StringBuilder(32768);
                uint length = GetFinalPathNameByHandleW(
                    handle, finalPath, (uint)finalPath.Capacity, 0);
                if (length == 0 || length >= finalPath.Capacity)
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(), "Unable to resolve destination lock file");
                string resolved = finalPath.ToString();
                if (resolved.StartsWith("\\\\?\\", StringComparison.Ordinal))
                    resolved = resolved.Substring(4);
                string expected = System.IO.Path.GetFullPath(path);
                if (!resolved.Equals(expected, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException(
                        "Destination lock file resolved outside the selected SimHub path");
                return handle;
            }
            catch
            {
                handle.Dispose();
                throw;
            }
        }

        public static SafeFileHandle OpenMutationLease(string path)
        {
            SafeFileHandle handle = CreateFileW(
                path,
                FileReadAttributes | DeleteAccess,
                0,
                IntPtr.Zero,
                CreateNew,
                FileAttributeTemporary | FileFlagDeleteOnClose,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(
                    error, "Another destination mutation is active or its lease is stale");
            }

            try
            {
                StringBuilder finalPath = new StringBuilder(32768);
                uint length = GetFinalPathNameByHandleW(
                    handle, finalPath, (uint)finalPath.Capacity, 0);
                if (length == 0 || length >= finalPath.Capacity)
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(), "Unable to resolve destination mutation lease");
                string resolved = finalPath.ToString();
                if (resolved.StartsWith("\\\\?\\", StringComparison.Ordinal))
                    resolved = resolved.Substring(4);
                string expected = System.IO.Path.GetFullPath(path);
                if (!resolved.Equals(expected, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException(
                        "Destination mutation lease resolved outside the selected path");
                return handle;
            }
            catch
            {
                handle.Dispose();
                throw;
            }
        }
    }
}
'@
}

function Exit-FFBSimHubMutationBoundary {
    param($Boundary)
    if ($null -eq $Boundary -or $null -eq $Boundary.Locks) { return }
    for ($index = $Boundary.Locks.Count - 1; $index -ge 0; $index--) {
        try { $Boundary.Locks[$index].Dispose() } catch { }
    }
}

function Enter-FFBSimHubMutationBoundary {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$RequireExecutable,
        [switch]$ReadOnly
    )

    $full = Get-FFBNormalizedLocalPath -Path $Path
    $driveRoot = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($driveRoot)) {
        throw "The SimHub directory has no local drive root: $full"
    }
    try {
        $driveTarget = [FFBInterceptor.DirectoryMutationLock]::GetStableFixedDriveTarget(
            $driveRoot)
    }
    catch {
        throw "Unable to establish a stable physical SimHub drive ($driveRoot): $($_.Exception.Message)"
    }

    $directories = New-Object System.Collections.ArrayList
    [void]$directories.Add($driveRoot)
    $current = $driveRoot
    $relative = $full.Substring($driveRoot.Length)
    foreach ($segment in @($relative -split '[\\/]')) {
        if ([string]::IsNullOrEmpty($segment)) { continue }
        $current = [IO.Path]::Combine($current, $segment)
        [void]$directories.Add($current)
    }

    $locks = New-Object System.Collections.ArrayList
    $directoryLocks = New-Object System.Collections.ArrayList
    try {
        foreach ($directory in $directories) {
            try {
                $handle = [FFBInterceptor.DirectoryMutationLock]::OpenDirectory(
                    [string]$directory)
            }
            catch {
                throw "Unable to lock a regular non-reparse SimHub path component ($directory): $($_.Exception.Message)"
            }
            [void]$locks.Add($handle)
            [void]$directoryLocks.Add([pscustomobject]@{
                Path = [string]$directory
                Handle = $handle
                Identity = [FFBInterceptor.DirectoryMutationLock]::GetIdentity($handle)
            })
        }

        # Real mutations add a unique delete-on-close child handle. A WhatIf
        # validation deliberately remains read-only. The identity checks
        # below still detect any component swapped while the validation
        # handles were being acquired; no path is mutated afterwards.
        if (-not $ReadOnly) {
            # A fixed, zero-share delete-on-close lease serializes real
            # mutations across processes and logon sessions. A stale or
            # attacker-created lease fails closed. The unique sentinel remains
            # separate because it anchors ancestor rename protection.
            $leasePath = Join-Path $full '.ffb-interceptor-mutation.lock'
            $lease = [FFBInterceptor.DirectoryMutationLock]::OpenMutationLease(
                $leasePath)
            [void]$locks.Add($lease)
            $sentinelPath = Join-Path $full (
                '.ffb-interceptor-mutation-' + [Guid]::NewGuid().ToString('N') + '.lock')
            $sentinel = [FFBInterceptor.DirectoryMutationLock]::OpenMutationSentinel(
                $sentinelPath)
            [void]$locks.Add($sentinel)
        }
        foreach ($lockedDirectory in $directoryLocks) {
            $verificationHandle = $null
            try {
                $verificationHandle = [FFBInterceptor.DirectoryMutationLock]::OpenDirectory(
                    [string]$lockedDirectory.Path)
                $identity = [FFBInterceptor.DirectoryMutationLock]::GetIdentity(
                    $verificationHandle)
                if (-not ([string]$lockedDirectory.Identity).Equals($identity,
                        [StringComparison]::Ordinal)) {
                    throw "A SimHub path component changed while its destination was being locked: $($lockedDirectory.Path)"
                }
            }
            finally {
                if ($null -ne $verificationHandle) { $verificationHandle.Dispose() }
            }
        }

        $verifiedDriveTarget = [FFBInterceptor.DirectoryMutationLock]::GetStableFixedDriveTarget(
            $driveRoot)
        if (-not $driveTarget.Equals($verifiedDriveTarget,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "The SimHub drive mapping changed while its destination was being locked: $driveRoot"
        }

        # For a real mutation, the delete-on-close child plus the directory
        # handles keep the selected tree from being renamed into a junction
        # between this validation and the elevated file mutations.
        $verified = Assert-FFBSimHubRoot -Path $full `
            -RequireExecutable:$RequireExecutable
        return [pscustomobject]@{ Root = $verified; Locks = $locks }
    }
    catch {
        Exit-FFBSimHubMutationBoundary -Boundary ([pscustomobject]@{ Locks = $locks })
        throw
    }
}

function Enter-FFBStateMutationBoundary {
    param(
        [switch]$AllowCreate,
        [switch]$ReadOnly
    )

    $directory = Get-FFBStateDirectory
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        if (-not $AllowCreate -or $ReadOnly) {
            throw "The protected plug-in state directory was not found: $directory"
        }

        # Creating the directory is the only operation performed before the
        # boundary. If an untrusted process wins this race with a junction,
        # the immediate OPEN_REPARSE_POINT validation below rejects it before
        # ACL or file mutations occur.
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }

    try {
        return Enter-FFBSimHubMutationBoundary -Path $directory -ReadOnly:$ReadOnly
    }
    catch {
        throw "Unable to secure the protected plug-in state directory ($directory): $($_.Exception.Message)"
    }
}

function Get-FFBSimHubExecutablePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    foreach ($name in @('SimHubWPF.exe', 'SimHub.exe')) {
        $candidate = Join-Path $Path $name
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $item = Get-Item -LiteralPath $candidate -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "The SimHub executable cannot be a reparse point: $candidate"
        }
        return $item.FullName
    }
    return ''
}

function Assert-FFBSimHubRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$RequireExecutable
    )
    $full = Get-FFBNormalizedLocalPath -Path $Path
    $root = [IO.Path]::GetPathRoot($full)
    $trimmedFull = $full.TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $trimmedRoot = $root.TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (Test-FFBPathEqual -Left $trimmedFull -Right $trimmedRoot) {
        throw "A drive root cannot be used as the SimHub directory: $full"
    }
    if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) { throw 'SystemRoot is unavailable.' }
    $windowsRoot = Get-FFBNormalizedLocalPath -Path $env:SystemRoot
    if (Test-FFBPathWithinOrEqual -Path $full -Parent $windowsRoot) {
        throw "The Windows directory cannot be used as the SimHub directory: $full"
    }
    if (Test-Path -LiteralPath $full) {
        $directoryItem = Get-Item -LiteralPath $full -Force
        if (-not $directoryItem.PSIsContainer -or
            ($directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "The SimHub directory cannot be a reparse point: $full"
        }
    }
    if ($RequireExecutable) {
        $simHubExecutable = Get-FFBSimHubExecutablePath -Path $full
        if ([string]::IsNullOrWhiteSpace($simHubExecutable)) {
            throw "SimHubWPF.exe or SimHub.exe was not found in: $full"
        }
    }
    return $full
}

function Assert-FFBPluginState {
    param(
        [Parameter(Mandatory = $true)]$State,
        [switch]$RequireSimHubExecutable
    )
    foreach ($property in @('SchemaVersion', 'InstallPath', 'Files')) {
        if ($null -eq $State.PSObject.Properties[$property]) { throw "The plug-in state is missing: $property" }
    }
    if ([string]$State.SchemaVersion -ne '1') { throw 'Unsupported SimHub plug-in state schema.' }

    $installPath = Assert-FFBSimHubRoot -Path ([string]$State.InstallPath) `
        -RequireExecutable:$RequireSimHubExecutable
    if ($env:FFB_INTERCEPTOR_PACKAGE_TEST -eq '1' -and
        -not [string]::IsNullOrWhiteSpace($env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY)) {
        $expectedTestRoot = Get-FFBNormalizedLocalPath -Path `
            (Join-Path (Split-Path -Parent (Get-FFBStateDirectory)) 'fake-simhub')
        if (-not (Test-FFBPathEqual -Left $installPath -Right $expectedTestRoot)) {
            throw "The isolated package test cannot manage this SimHub directory: $installPath"
        }
    }
    $expected = @{}
    foreach ($name in @('FFBInterceptor.SimHub.dll', 'FFBInterceptor.Core.dll')) {
        $expected[$name.ToLowerInvariant()] = Get-FFBNormalizedLocalPath -Path (Join-Path $installPath $name)
    }

    $files = @($State.Files)
    if ($files.Count -ne $expected.Count) { throw 'The plug-in state must contain exactly two managed files.' }
    $seen = @{}
    $validated = New-Object System.Collections.ArrayList
    foreach ($file in $files) {
        foreach ($property in @('Destination', 'Backup', 'BackupSha256', 'InstalledSha256', 'Changed')) {
            if ($null -eq $file.PSObject.Properties[$property]) { throw "A managed-file record is missing: $property" }
        }
        if ($file.Changed -isnot [bool]) { throw 'A managed-file Changed value is not Boolean.' }
        $destination = Get-FFBNormalizedLocalPath -Path ([string]$file.Destination)
        $nameKey = [IO.Path]::GetFileName($destination).ToLowerInvariant()
        if (-not $expected.ContainsKey($nameKey) -or
            -not (Test-FFBPathEqual -Left $destination -Right $expected[$nameKey]) -or
            $seen.ContainsKey($nameKey)) {
            throw "The plug-in state contains an unexpected or duplicate destination: $destination"
        }
        $seen[$nameKey] = $true

        $hash = ([string]$file.InstalledSha256).ToUpperInvariant()
        if ($hash -notmatch '^[A-F0-9]{64}$') { throw "The plug-in state contains an invalid SHA-256: $destination" }
        $changed = [bool]$file.Changed
        $backup = [string]$file.Backup
        if (-not $changed -and -not [string]::IsNullOrWhiteSpace($backup)) {
            throw "An unmanaged file cannot have a recorded backup: $destination"
        }
        if (-not [string]::IsNullOrWhiteSpace($backup)) {
            $backup = Get-FFBNormalizedLocalPath -Path $backup
            $backupPrefix = [regex]::Escape($destination + '.ffb-interceptor-backup')
            if ($backup -notmatch "^$backupPrefix(?:\.[1-9][0-9]*)?$") {
                throw "The plug-in state contains an unsafe backup path: $backup"
            }
        }
        $backupHash = ([string]$file.BackupSha256).ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($backup)) {
            if (-not [string]::IsNullOrWhiteSpace($backupHash)) {
                throw "A missing backup cannot have a recorded SHA-256: $destination"
            }
        }
        elseif ($backupHash -notmatch '^[A-F0-9]{64}$') {
            throw "The plug-in state contains an invalid backup SHA-256: $backup"
        }

        [void]$validated.Add([pscustomobject][ordered]@{
            Destination = $destination
            Backup = $backup
            BackupSha256 = $backupHash
            InstalledSha256 = $hash
            Changed = $changed
        })
    }
    if ($seen.Count -ne $expected.Count) { throw 'The plug-in state is incomplete.' }
    $installedAt = ''
    if ($null -ne $State.PSObject.Properties['InstalledAtUtc']) { $installedAt = [string]$State.InstalledAtUtc }
    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        InstalledAtUtc = $installedAt
        InstallPath = $installPath
        Files = @($validated)
    }
}

function Get-FFBAclIdentifiers {
    return [pscustomobject]@{
        Administrators = [Security.Principal.SecurityIdentifier]::new(
            [Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
        System = [Security.Principal.SecurityIdentifier]::new(
            [Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
        Users = [Security.Principal.SecurityIdentifier]::new(
            [Security.Principal.WellKnownSidType]::BuiltinUsersSid, $null)
        CurrentUser = [Security.Principal.WindowsIdentity]::GetCurrent().User
    }
}

function Set-FFBDirectoryAclObject {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][Security.AccessControl.DirectorySecurity]$Security
    )
    $extensions = 'System.IO.FileSystemAclExtensions' -as [type]
    if ($null -eq $extensions) {
        [IO.Directory]::SetAccessControl($Path, $Security)
        return
    }
    $method = @($extensions.GetMethods() | Where-Object {
        $_.Name -eq 'SetAccessControl' -and $_.GetParameters().Count -eq 2 -and
        $_.GetParameters()[0].ParameterType -eq [IO.DirectoryInfo]
    })[0]
    if ($null -eq $method) { throw 'Directory ACL support is unavailable.' }
    try { [void]$method.Invoke($null, @([IO.DirectoryInfo]::new($Path), $Security)) }
    catch {
        if ($null -ne $_.Exception.InnerException) { throw $_.Exception.InnerException }
        throw
    }
}

function Set-FFBFileAclObject {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][Security.AccessControl.FileSecurity]$Security
    )
    $extensions = 'System.IO.FileSystemAclExtensions' -as [type]
    if ($null -eq $extensions) {
        [IO.File]::SetAccessControl($Path, $Security)
        return
    }
    $method = @($extensions.GetMethods() | Where-Object {
        $_.Name -eq 'SetAccessControl' -and $_.GetParameters().Count -eq 2 -and
        $_.GetParameters()[0].ParameterType -eq [IO.FileInfo]
    })[0]
    if ($null -eq $method) { throw 'File ACL support is unavailable.' }
    try { [void]$method.Invoke($null, @([IO.FileInfo]::new($Path), $Security)) }
    catch {
        if ($null -ne $_.Exception.InnerException) { throw $_.Exception.InnerException }
        throw
    }
}

function Set-FFBProtectedDirectoryAcl {
    param([Parameter(Mandatory = $true)][string]$Path)
    $isAdministrator = Test-FFBAdministrator
    $isolatedTest = $env:FFB_INTERCEPTOR_PACKAGE_TEST -eq '1'
    if (-not $isAdministrator -and -not $isolatedTest) {
        throw 'Administrator rights are required to protect installation state.'
    }
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "The state directory is not a regular directory: $Path"
        }
    }
    [IO.Directory]::CreateDirectory($Path) | Out-Null
    $ids = Get-FFBAclIdentifiers
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $none = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner($(if ($isAdministrator) { $ids.Administrators } else { $ids.CurrentUser }))
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $ids.Administrators, [Security.AccessControl.FileSystemRights]::FullControl,
        $inheritance, $none, $allow))
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $ids.System, [Security.AccessControl.FileSystemRights]::FullControl,
        $inheritance, $none, $allow))
    if (-not $isAdministrator) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $ids.CurrentUser, [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance, $none, $allow))
    }
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $ids.Users, [Security.AccessControl.FileSystemRights]::ReadAndExecute,
        $inheritance, $none, $allow))
    Set-FFBDirectoryAclObject -Path $Path -Security $security
}

function Set-FFBProtectedFileAcl {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "The state file is not a regular file: $Path"
    }
    $ids = Get-FFBAclIdentifiers
    $isAdministrator = Test-FFBAdministrator
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $security = [Security.AccessControl.FileSecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner($(if ($isAdministrator) { $ids.Administrators } else { $ids.CurrentUser }))
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $ids.Administrators, [Security.AccessControl.FileSystemRights]::FullControl, $allow))
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $ids.System, [Security.AccessControl.FileSystemRights]::FullControl, $allow))
    if (-not $isAdministrator) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $ids.CurrentUser, [Security.AccessControl.FileSystemRights]::FullControl, $allow))
    }
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $ids.Users, [Security.AccessControl.FileSystemRights]::ReadAndExecute, $allow))
    Set-FFBFileAclObject -Path $Path -Security $security
}

function Test-FFBProtectedAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('File', 'Directory')][string]$Kind
    )
    try {
        $item = Get-Item -LiteralPath $Path -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            ($Kind -eq 'File' -and $item.PSIsContainer) -or
            ($Kind -eq 'Directory' -and -not $item.PSIsContainer)) { return $false }
        $security = Get-Acl -LiteralPath $Path
        if (-not $security.AreAccessRulesProtected) { return $false }
        $ids = Get-FFBAclIdentifiers
        $isolatedTest = $env:FFB_INTERCEPTOR_PACKAGE_TEST -eq '1'
        $owner = $security.GetOwner([Security.Principal.SecurityIdentifier])
        if (-not $owner.Equals($ids.Administrators) -and -not $owner.Equals($ids.System) -and
            (-not $isolatedTest -or -not $owner.Equals($ids.CurrentUser))) { return $false }
        $dangerous = [Security.AccessControl.FileSystemRights]::Write -bor
            [Security.AccessControl.FileSystemRights]::Delete -bor
            [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
            [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
            [Security.AccessControl.FileSystemRights]::TakeOwnership
        $rules = $security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
        foreach ($rule in $rules) {
            if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
            $sid = [Security.Principal.SecurityIdentifier]$rule.IdentityReference
            if ($sid.Equals($ids.Administrators) -or $sid.Equals($ids.System)) { continue }
            if ($isolatedTest -and $sid.Equals($ids.CurrentUser)) { continue }
            if (($rule.FileSystemRights -band $dangerous) -ne 0) { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Test-FFBStateProtection {
    $directory = Get-FFBStateDirectory
    $path = Get-FFBStatePath
    return (Test-Path -LiteralPath $directory -PathType Container) -and
        (Test-Path -LiteralPath $path -PathType Leaf) -and
        (Test-FFBProtectedAcl -Path $directory -Kind Directory) -and
        (Test-FFBProtectedAcl -Path $path -Kind File)
}

function Read-FFBPluginState {
    param([switch]$AllowMissing, [switch]$RequireSimHubExecutable)
    $path = Get-FFBStatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        if ($AllowMissing) { return $null }
        throw "No managed SimHub plug-in installation was found: $path"
    }
    if (-not (Test-FFBStateProtection)) { throw "The SimHub plug-in state is not administrator-protected: $path" }
    $item = Get-Item -LiteralPath $path
    if ($item.Length -gt 65536) { throw "The SimHub plug-in state is too large: $path" }
    try { $state = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json }
    catch { throw "The SimHub plug-in state is invalid: $path" }
    return Assert-FFBPluginState -State $state -RequireSimHubExecutable:$RequireSimHubExecutable
}

function Save-FFBPluginState {
    param([Parameter(Mandatory = $true)]$State)
    $validated = Assert-FFBPluginState -State $State -RequireSimHubExecutable
    $directory = Get-FFBStateDirectory
    $path = Get-FFBStatePath
    $stateBoundary = $null
    $temporary = ''
    try {
        $stateBoundary = Enter-FFBStateMutationBoundary -AllowCreate
        if (Test-Path -LiteralPath $path) {
            throw "Refusing to overwrite existing plug-in state: $path"
        }
        Set-FFBProtectedDirectoryAcl -Path $directory
        $temporary = Join-Path $directory ('.simhub-plugin-state-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::WriteAllText($temporary, ($validated | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
        Set-FFBProtectedFileAcl -Path $temporary
        [IO.File]::Move($temporary, $path)
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($temporary) -and
            (Test-Path -LiteralPath $temporary)) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
        Exit-FFBSimHubMutationBoundary -Boundary $stateBoundary
    }
}
