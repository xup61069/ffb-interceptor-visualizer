# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$NoElevation,
    [switch]$NoPause,
    [string]$ManagerInvocationEvent = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# UAC must not turn a user-writable PSModulePath entry into an elevated helper.
# Resolve the running engine without invoking any auto-loaded cmdlet, then load
# the inbox signature module from that engine's fixed PSHOME only.
$runtimePath = [IO.Path]::GetFullPath(
    [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$runtimeHome = [IO.Path]::GetFullPath([IO.Path]::GetDirectoryName($runtimePath))
$trustedPSHome = [IO.Path]::GetFullPath([string]$PSHOME)
if (-not $runtimeHome.Equals($trustedPSHome, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The running PowerShell engine does not match its fixed PSHOME.'
}
if (-not [string]::IsNullOrWhiteSpace($ManagerInvocationEvent)) {
    # PSHOME is engine-owned. Do not trust inherited SystemRoot or module paths
    # before the standalone package boundary has authenticated its own code.
    $expectedRuntime = [IO.Path]::GetFullPath(
        [IO.Path]::Combine($trustedPSHome, 'powershell.exe'))
    if (-not $runtimePath.Equals($expectedRuntime, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'A controlled Manager invocation requires the exact System32 Windows PowerShell.'
    }
}
$script:PSModuleAutoLoadingPreference = 'None'
$env:PSModulePath = [IO.Path]::Combine($trustedPSHome, 'Modules')
$trustedModuleNames = @(
    'Microsoft.PowerShell.Management',
    'Microsoft.PowerShell.Utility',
    'Microsoft.PowerShell.Security'
)
foreach ($trustedModuleName in $trustedModuleNames) {
    $trustedModule = [IO.Path]::Combine(
        $trustedPSHome, 'Modules', $trustedModuleName,
        ($trustedModuleName + '.psd1'))
    if (-not [IO.File]::Exists($trustedModule)) {
        throw "The inbox PowerShell module is missing: $trustedModuleName"
    }
    Import-Module -Name $trustedModule -Force -ErrorAction Stop
}

function Get-FFBStandaloneStreamSha256 {
    param([Parameter(Mandatory = $true)][IO.Stream]$Stream)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $Stream.Position = 0
        $hash = ([BitConverter]::ToString($sha256.ComputeHash($Stream))).Replace('-', '')
        $Stream.Position = 0
        return $hash
    }
    finally { $sha256.Dispose() }
}

function Get-FFBStandaloneSignerSha256 {
    param([Parameter(Mandatory = $true)][Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha256.ComputeHash($Certificate.RawData))).Replace('-', '') }
    finally { $sha256.Dispose() }
}

function Test-FFBStandaloneChildPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )
    $prefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) +
        [IO.Path]::DirectorySeparatorChar
    return $Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Enter-FFBStandalonePackageBoundary {
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string[]]$RequiredRelativePaths
    )
    $root = [IO.Path]::GetFullPath($BundleRoot).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Package root is not a regular directory: $root"
    }
    $locks = New-Object System.Collections.ArrayList
    try {
        $manifestPath = Join-Path $root 'SHA256SUMS.txt'
        $manifestItem = Get-Item -LiteralPath $manifestPath -Force -ErrorAction Stop
        if ($manifestItem.PSIsContainer -or
            ($manifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $manifestItem.Length -le 0 -or $manifestItem.Length -gt 1048576) {
            throw 'Package manifest is unsafe, empty, or too large.'
        }
        $manifestStream = [IO.File]::Open(
            $manifestPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        [void]$locks.Add($manifestStream)
        $reader = [IO.StreamReader]::new(
            $manifestStream, [Text.UTF8Encoding]::new($false, $true), $true, 4096, $true)
        try {
            $expected = @{}
            while ($null -ne ($line = $reader.ReadLine())) {
                if ($line -notmatch '^([A-Fa-f0-9]{64})  (.+)$') {
                    throw "Invalid package manifest line: $line"
                }
                $relative = $Matches[2].Replace('/', '\')
                if ([IO.Path]::IsPathRooted($relative) -or $relative.Contains(':')) {
                    throw "Unsafe package manifest path: $relative"
                }
                $segments = @($relative -split '\\')
                if ($segments.Count -eq 0 -or @($segments | Where-Object {
                    [string]::IsNullOrWhiteSpace($_) -or $_ -eq '.' -or $_ -eq '..' -or
                    $_.EndsWith('.') -or $_.EndsWith(' ')
                }).Count -gt 0) {
                    throw "Non-canonical package manifest path: $relative"
                }
                $key = $relative.ToLowerInvariant()
                if ($expected.ContainsKey($key) -or $expected.Count -ge 128) {
                    throw "Duplicate or excessive package manifest entry: $relative"
                }
                $candidate = [IO.Path]::GetFullPath((Join-Path $root $relative))
                if (-not (Test-FFBStandaloneChildPath -Path $candidate -Root $root)) {
                    throw "Package manifest entry escapes the package: $relative"
                }
                $expected[$key] = [pscustomobject]@{
                    Relative = $relative
                    Path = $candidate
                    Hash = $Matches[1].ToUpperInvariant()
                }
            }
        }
        finally { $reader.Dispose() }
        if ($expected.Count -eq 0) { throw 'Package manifest is empty.' }

        foreach ($required in $RequiredRelativePaths) {
            if (-not $expected.ContainsKey($required.Replace('/', '\').ToLowerInvariant())) {
                throw "Package manifest is missing a required file: $required"
            }
        }
        $pendingDirectories = [Collections.Generic.Queue[string]]::new()
        $pendingDirectories.Enqueue($root)
        $discoveredFiles = New-Object System.Collections.ArrayList
        $directoryCount = 0
        while ($pendingDirectories.Count -gt 0) {
            $directoryPath = $pendingDirectories.Dequeue()
            foreach ($child in @(Get-ChildItem -LiteralPath $directoryPath -Force)) {
                if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    throw "Package entry cannot be a reparse point: $($child.FullName)"
                }
                if ($child.PSIsContainer) {
                    $directoryCount++
                    if ($directoryCount -gt 128) { throw 'Package contains too many directories.' }
                    $pendingDirectories.Enqueue($child.FullName)
                }
                else {
                    if ($discoveredFiles.Count -ge 129) { throw 'Package contains too many files.' }
                    [void]$discoveredFiles.Add($child)
                }
            }
        }
        $actualFiles = @($discoveredFiles | Where-Object {
            -not $_.FullName.Equals($manifestPath, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($actualFiles.Count -ne $expected.Count) {
            throw 'Package manifest does not cover the exact extracted file set.'
        }
        foreach ($file in $actualFiles) {
            if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Package file cannot be a reparse point: $($file.FullName)"
            }
            $relative = $file.FullName.Substring($root.Length + 1).ToLowerInvariant()
            if (-not $expected.ContainsKey($relative)) {
                throw "Package contains a file not listed in its manifest: $($file.FullName)"
            }
        }

        $lockedFiles = @{}
        foreach ($record in @($expected.Values | Sort-Object Path)) {
            $item = Get-Item -LiteralPath $record.Path -Force -ErrorAction Stop
            if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Package file is not regular: $($record.Path)"
            }
            $stream = [IO.File]::Open(
                $record.Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            [void]$locks.Add($stream)
            if ((Get-FFBStandaloneStreamSha256 -Stream $stream) -cne $record.Hash) {
                throw "Package manifest verification failed: $($record.Path)"
            }
            $lockedFiles[$record.Relative.ToLowerInvariant()] = $stream
        }

        $codeRecords = @($expected.Values | Where-Object {
            [IO.Path]::GetExtension($_.Path) -in @('.ps1', '.psm1', '.dll', '.exe')
        })
        $selfSignature = Get-AuthenticodeSignature -LiteralPath $PSCommandPath
        if ($selfSignature.Status -eq [Management.Automation.SignatureStatus]::Valid -and
            $null -ne $selfSignature.SignerCertificate) {
            $expectedSigner = Get-FFBStandaloneSignerSha256 -Certificate $selfSignature.SignerCertificate
            foreach ($record in $codeRecords) {
                $signature = Get-AuthenticodeSignature -LiteralPath $record.Path
                if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
                    $null -eq $signature.SignerCertificate -or
                    (Get-FFBStandaloneSignerSha256 -Certificate $signature.SignerCertificate) -cne $expectedSigner) {
                    throw "Signed package code has an invalid or mismatched Authenticode signature: $($record.Relative)"
                }
            }
        }
        elseif ($selfSignature.Status -eq [Management.Automation.SignatureStatus]::NotSigned) {
            foreach ($record in $codeRecords) {
                $signature = Get-AuthenticodeSignature -LiteralPath $record.Path
                if ($signature.Status -ne [Management.Automation.SignatureStatus]::NotSigned) {
                    throw "Unsigned package mixes Authenticode states and is not safe to execute: $($record.Relative)"
                }
            }
        }
        else {
            throw "Uninstaller Authenticode validation failed: $($selfSignature.StatusMessage)"
        }

        return [pscustomobject]@{ Root = $root; Locks = $locks; Files = $lockedFiles }
    }
    catch {
        foreach ($lock in $locks) { try { $lock.Dispose() } catch { } }
        throw
    }
}

$packageBoundary = $null
$simHubMutationBoundary = $null
$stateMutationBoundary = $null
$managerInvocationHandle = $null
$bundleRoot = Split-Path -Parent $PSCommandPath
try {
    $packageBoundary = Enter-FFBStandalonePackageBoundary -BundleRoot $bundleRoot -RequiredRelativePaths @(
        'FFBInterceptor.Common.ps1',
        'Uninstall-SimHubPlugin.ps1'
    )
    $bootstrapIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $bootstrapPrincipal = New-Object Security.Principal.WindowsPrincipal($bootstrapIdentity)
    $isAdministrator = $bootstrapPrincipal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not [string]::IsNullOrWhiteSpace($ManagerInvocationEvent)) {
        if ($NoElevation -or $WhatIfPreference -or -not $isAdministrator) {
            throw 'A controlled Manager invocation is only valid in a real elevated uninstall.'
        }
        if ($ManagerInvocationEvent -cnotmatch '^Local\\FFBInterceptor\.ManagerElevation\.v1\.[A-F0-9]{64}$') {
            throw 'The controlled Manager invocation identifier is invalid.'
        }
        try {
            $managerInvocationHandle = [Threading.EventWaitHandle]::OpenExisting(
                $ManagerInvocationEvent)
        }
        catch {
            throw 'The controlled Manager invocation is no longer active.'
        }
    }
    elseif (-not $NoElevation -and -not $WhatIfPreference) {
        if (-not $isAdministrator) {
            throw 'The standalone uninstaller no longer requests administrator rights. Open FFBInterceptor.Manager.exe normally and use Uninstall Plugin. Use -NoElevation only for a directory that does not require administrator rights.'
        }
        throw 'Elevated removal is accepted only from the verified FFBInterceptor.Manager.exe flow. Reopen Manager normally and use Uninstall Plugin.'
    }
    $commonScript = Join-Path $bundleRoot 'FFBInterceptor.Common.ps1'
    . $commonScript
    if ($null -ne $managerInvocationHandle -and -not $managerInvocationHandle.Set()) {
        throw 'Could not confirm the verified package boundary to Manager.'
    }
}
catch {
    if ($null -ne $managerInvocationHandle) {
        try { $managerInvocationHandle.Dispose() } catch { }
        $managerInvocationHandle = $null
    }
    if ($null -ne $packageBoundary) {
        foreach ($lock in $packageBoundary.Locks) { try { $lock.Dispose() } catch { } }
    }
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    if (-not $NoPause) { [void](Read-Host 'Press Enter to close') }
    exit 1
}

function Get-UninstallStagingPath {
    param([Parameter(Mandatory = $true)][string]$Destination)
    do {
        $candidate = $Destination + '.ffb-interceptor-remove-' + [Guid]::NewGuid().ToString('N')
    } while (Test-Path -LiteralPath $candidate)
    return $candidate
}

try {
    $statePath = Get-FFBStatePath
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        Write-Host 'No managed SimHub plug-in installation was found.'
        exit 0
    }
    $state = Read-FFBPluginState
    $simHubMutationBoundary = Enter-FFBSimHubMutationBoundary `
        -Path ([string]$state.InstallPath) `
        -ReadOnly:$WhatIfPreference
    $stateMutationBoundary = Enter-FFBStateMutationBoundary `
        -ReadOnly:$WhatIfPreference
    $state = Read-FFBPluginState
    if (-not (Test-FFBPathEqual -Left ([string]$state.InstallPath) `
            -Right ([string]$simHubMutationBoundary.Root))) {
        throw 'The protected plug-in state changed its SimHub destination while locks were being acquired.'
    }
    if (-not $WhatIfPreference -and (Get-Process -Name 'SimHub', 'SimHubWPF' -ErrorAction SilentlyContinue)) {
        throw 'Close SimHub before uninstalling the plug-in.'
    }

    foreach ($file in @($state.Files)) {
        if (-not [bool]$file.Changed) { continue }
        $destination = [string]$file.Destination
        if (Test-Path -LiteralPath $destination) {
            $destinationItem = Get-Item -LiteralPath $destination -Force
            if ($destinationItem.PSIsContainer -or
                ($destinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
                (Get-FFBFileSha256 -Path $destination) -ne [string]$file.InstalledSha256) {
                throw "Refusing to remove a changed, redirected, or non-regular file: $destination"
            }
        }
        if ($file.Backup) {
            $backup = [string]$file.Backup
            if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) {
                throw "The recorded backup is missing: $backup"
            }
            $backupItem = Get-Item -LiteralPath $backup -Force
            if (($backupItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
                (Get-FFBFileSha256 -Path $backup) -ne [string]$file.BackupSha256) {
                throw "Refusing to restore a changed or redirected backup: $backup"
            }
        }
    }

    if ($WhatIfPreference) {
        foreach ($file in @($state.Files)) {
            if (-not [bool]$file.Changed) { continue }
            [void]$PSCmdlet.ShouldProcess([string]$file.Destination, 'Restore the pre-install SimHub plug-in file state')
        }
        [void]$PSCmdlet.ShouldProcess($statePath, 'Remove installation state')
        Write-Host 'SimHub plug-in uninstall validation passed (WhatIf).'
        exit 0
    }
    if (-not $PSCmdlet.ShouldProcess([string]$state.InstallPath, 'Uninstall the managed FFB Interceptor SimHub plug-in')) {
        exit 0
    }

    $operations = New-Object System.Collections.ArrayList
    try {
        foreach ($file in @($state.Files)) {
            if (-not [bool]$file.Changed) { continue }
            $destination = [string]$file.Destination
            $operation = [pscustomobject]@{
                Destination = $destination
                Backup = [string]$file.Backup
                Staged = ''
                PlugInStaged = $false
                BackupRestored = $false
            }
            [void]$operations.Add($operation)
            if (Test-Path -LiteralPath $destination -PathType Leaf) {
                $operation.Staged = Get-UninstallStagingPath -Destination $destination
                [IO.File]::Move($destination, $operation.Staged)
                $operation.PlugInStaged = $true
            }
            if ($operation.Backup) {
                [IO.File]::Move($operation.Backup, $destination)
                $operation.BackupRestored = $true
            }
        }
        Remove-Item -LiteralPath $statePath -Force -ErrorAction Stop
    }
    catch {
        for ($index = $operations.Count - 1; $index -ge 0; $index--) {
            $operation = $operations[$index]
            if ($operation.BackupRestored -and
                (Test-Path -LiteralPath $operation.Destination -PathType Leaf) -and
                -not (Test-Path -LiteralPath $operation.Backup)) {
                try { [IO.File]::Move($operation.Destination, $operation.Backup) } catch { }
            }
            if ($operation.PlugInStaged -and
                (Test-Path -LiteralPath $operation.Staged -PathType Leaf) -and
                -not (Test-Path -LiteralPath $operation.Destination)) {
                try { [IO.File]::Move($operation.Staged, $operation.Destination) } catch { }
            }
        }
        throw
    }

    foreach ($operation in $operations) {
        if ($operation.PlugInStaged -and (Test-Path -LiteralPath $operation.Staged -PathType Leaf)) {
            try { Remove-Item -LiteralPath $operation.Staged -Force -ErrorAction Stop }
            catch { Write-Warning "The removed plug-in copy could not be deleted: $($operation.Staged)" }
        }
    }
    Write-Host 'Removed the managed SimHub plug-in files. Imported dashboards are left untouched.'
}
catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    if (-not $NoPause) { [void](Read-Host 'Press Enter to close') }
    exit 1
}
finally {
    Exit-FFBSimHubMutationBoundary -Boundary $stateMutationBoundary
    Exit-FFBSimHubMutationBoundary -Boundary $simHubMutationBoundary
    if ($null -ne $managerInvocationHandle) {
        try { $managerInvocationHandle.Dispose() } catch { }
    }
    if ($null -ne $packageBoundary) {
        foreach ($lock in $packageBoundary.Locks) { try { $lock.Dispose() } catch { } }
    }
}
