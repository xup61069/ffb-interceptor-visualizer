# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$SimHubInstallPath = '',
    [switch]$NoDashboardImport,
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
            throw "Installer Authenticode validation failed: $($selfSignature.StatusMessage)"
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
        'Install-SimHubPlugin.ps1',
        'simhub\FFBInterceptor.SimHub.dll',
        'simhub\FFBInterceptor.Core.dll'
    )
    $bootstrapIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $bootstrapPrincipal = New-Object Security.Principal.WindowsPrincipal($bootstrapIdentity)
    $isAdministrator = $bootstrapPrincipal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not [string]::IsNullOrWhiteSpace($ManagerInvocationEvent)) {
        if ($NoElevation -or $WhatIfPreference -or -not $isAdministrator) {
            throw 'A controlled Manager invocation is only valid in a real elevated install.'
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
            throw 'The standalone installer no longer requests administrator rights. Open FFBInterceptor.Manager.exe normally and use Install/Update Plugin. Use -NoElevation only for a directory that does not require administrator rights.'
        }
        throw 'Elevated installation is accepted only from the verified FFBInterceptor.Manager.exe flow. Reopen Manager normally and use Install/Update Plugin.'
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

function Test-StateValid {
    param($State)
    if ($null -eq $State) { return $false }
    foreach ($file in @($State.Files)) {
        if (-not (Test-Path -LiteralPath ([string]$file.Destination) -PathType Leaf)) { return $false }
        if ((Get-FFBFileSha256 -Path ([string]$file.Destination)) -ne [string]$file.InstalledSha256) { return $false }
    }
    return $true
}

function Test-StateMatchesPackage {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$BundleRoot
    )
    $stateFiles = @{}
    foreach ($file in @($State.Files)) {
        $stateFiles[[IO.Path]::GetFileName([string]$file.Destination).ToLowerInvariant()] = $file
    }
    foreach ($name in @('FFBInterceptor.SimHub.dll', 'FFBInterceptor.Core.dll')) {
        $source = Join-Path $BundleRoot (Join-Path 'simhub' $name)
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Package file is missing: $source" }
        $sourceItem = Get-Item -LiteralPath $source -Force
        if ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Package file cannot be a reparse point: $source"
        }
        $record = $stateFiles[$name.ToLowerInvariant()]
        if ($null -eq $record -or
            (Get-FFBFileSha256 -Path $source) -ne [string]$record.InstalledSha256) {
            return $false
        }
    }
    return $true
}

function Resolve-SimHubPath {
    param([string]$Path)
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
        return Assert-FFBSimHubRoot -Path $resolved -RequireExecutable
    }

    $candidates = @()
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'SimHub') }
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'SimHub') }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            try { return Assert-FFBSimHubRoot -Path (Resolve-Path -LiteralPath $candidate).Path -RequireExecutable }
            catch { }
        }
    }

    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Select the SimHub installation folder'
    try {
        if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
            throw 'No SimHub installation folder was selected.'
        }
        return Resolve-SimHubPath -Path $dialog.SelectedPath
    }
    finally { $dialog.Dispose() }
}

function Get-BackupPath {
    param([Parameter(Mandatory = $true)][string]$Destination)
    $candidate = "$Destination.ffb-interceptor-backup"
    $index = 1
    while (Test-Path -LiteralPath $candidate) {
        $candidate = "$Destination.ffb-interceptor-backup.$index"
        $index++
    }
    return $candidate
}

function Install-ManagedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Package file is missing: $Source" }
    $sourceHash = Get-FFBFileSha256 -Path $Source
    $sourceItem = Get-Item -LiteralPath $Source -Force
    if ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Package file cannot be a reparse point: $Source" }

    if (Test-Path -LiteralPath $Destination) {
        $destinationItem = Get-Item -LiteralPath $Destination -Force
        if ($destinationItem.PSIsContainer -or
            ($destinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Refusing to replace a non-regular file: $Destination"
        }
    }
    if ((Test-Path -LiteralPath $Destination -PathType Leaf) -and
        (Get-FFBFileSha256 -Path $Destination) -eq $sourceHash) {
        return [pscustomobject][ordered]@{ Destination = $Destination; Backup = ''; BackupSha256 = ''; InstalledSha256 = $sourceHash; Changed = $false }
    }

    $backup = ''
    $backupHash = ''
    if ($PSCmdlet.ShouldProcess($Destination, "Install $([IO.Path]::GetFileName($Source))")) {
        $temporary = "$Destination.ffb-interceptor-new-$([Guid]::NewGuid().ToString('N'))"
        try {
            if (Test-Path -LiteralPath $Destination -PathType Leaf) {
                $destinationItem = Get-Item -LiteralPath $Destination -Force
                if ($destinationItem.PSIsContainer -or
                    ($destinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    throw "Refusing to replace a non-regular file: $Destination"
                }
                $backupHash = Get-FFBFileSha256 -Path $Destination
                $backup = Get-BackupPath -Destination $Destination
                [IO.File]::Move($Destination, $backup)
            }
            [IO.File]::Copy($Source, $temporary, $false)
            [IO.File]::Move($temporary, $Destination)
        }
        catch {
            if (Test-Path -LiteralPath $temporary -PathType Leaf) {
                [IO.File]::Delete($temporary)
            }
            if (-not (Test-Path -LiteralPath $Destination) -and $backup -and (Test-Path -LiteralPath $backup)) {
                try { [IO.File]::Move($backup, $Destination) } catch { }
            }
            throw
        }
    }
    return [pscustomobject][ordered]@{ Destination = $Destination; Backup = $backup; BackupSha256 = $backupHash; InstalledSha256 = $sourceHash; Changed = $true }
}

function Restore-ManagedFile {
    param([Parameter(Mandatory = $true)]$Record)
    if (-not $Record.Changed) { return }
    $destination = [string]$Record.Destination
    if ((Test-Path -LiteralPath $destination -PathType Leaf) -and
        (Get-FFBFileSha256 -Path $destination) -eq [string]$Record.InstalledSha256) {
        Remove-Item -LiteralPath $destination -Force
    }
    if ($Record.Backup -and (Test-Path -LiteralPath ([string]$Record.Backup)) -and
        -not (Test-Path -LiteralPath $destination)) {
        if ((Get-FFBFileSha256 -Path ([string]$Record.Backup)) -ne [string]$Record.BackupSha256) {
            throw "Refusing to restore a changed backup: $($Record.Backup)"
        }
        [IO.File]::Move([string]$Record.Backup, $destination)
    }
}

function Open-Dashboards {
    $bundleRoot = Split-Path -Parent $PSCommandPath
    foreach ($name in @('FFB Interceptor 800x480.simhubdash', 'FFB Interceptor Overlay 480x160.simhubdash')) {
        $path = Join-Path $bundleRoot (Join-Path 'Dashboards' $name)
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try { Start-Process -FilePath $path | Out-Null }
            catch { Write-Warning "Open this dashboard manually: $path" }
        }
    }
}

try {
    $bundleRoot = Split-Path -Parent $PSCommandPath
    [void](Assert-FFBPackageManifest -BundleRoot $bundleRoot)
    $existingState = Read-FFBPluginState -AllowMissing -RequireSimHubExecutable
    $hadExistingState = $null -ne $existingState
    $requestedSimHubPath = ''
    if (-not [string]::IsNullOrWhiteSpace($SimHubInstallPath)) {
        $requestedSimHubPath = Resolve-SimHubPath -Path $SimHubInstallPath
    }
    $simHubPath = if ($hadExistingState) {
        [string]$existingState.InstallPath
    }
    elseif (-not [string]::IsNullOrWhiteSpace($requestedSimHubPath)) {
        $requestedSimHubPath
    }
    else {
        Resolve-SimHubPath -Path ''
    }
    $simHubMutationBoundary = Enter-FFBSimHubMutationBoundary `
        -Path $simHubPath -RequireExecutable -ReadOnly:$WhatIfPreference
    $simHubPath = [string]$simHubMutationBoundary.Root

    # Re-read under the SimHub lease. Existing installations also acquire the
    # state lease in the same SimHub -> state order as uninstall before they
    # can report idempotent success.
    $existingState = Read-FFBPluginState -AllowMissing -RequireSimHubExecutable
    if ($hadExistingState -and $null -eq $existingState) {
        throw 'The protected plug-in state changed while the destination lock was being acquired. Retry the operation.'
    }
    if ($null -ne $existingState) {
        $stateMutationBoundary = Enter-FFBStateMutationBoundary `
            -ReadOnly:$WhatIfPreference
        $existingState = Read-FFBPluginState -RequireSimHubExecutable
        if (-not (Test-FFBPathEqual -Left ([string]$existingState.InstallPath) `
                -Right $simHubPath)) {
            throw 'The protected plug-in state changed its SimHub destination while locks were being acquired.'
        }
        if (-not [string]::IsNullOrWhiteSpace($requestedSimHubPath) -and
            -not (Test-FFBPathEqual -Left $requestedSimHubPath `
                -Right ([string]$existingState.InstallPath))) {
            throw 'FFB Interceptor is already installed in a different SimHub directory. Uninstall it before switching directories.'
        }
        if (Test-StateValid -State $existingState) {
            if (Test-StateMatchesPackage -State $existingState -BundleRoot $bundleRoot) {
                Write-Host 'The SimHub plug-in from this package is already installed and verified.'
                exit 0
            }
            throw 'A different FFB Interceptor SimHub plug-in version is installed. Run Uninstall-SimHubPlugin.cmd, then start this package again.'
        }
        throw 'The recorded SimHub plug-in files changed or are missing. Run Uninstall-SimHubPlugin.cmd before reinstalling.'
    }
    if (-not $WhatIfPreference -and (Get-Process -Name 'SimHub', 'SimHubWPF' -ErrorAction SilentlyContinue)) {
        throw 'Close SimHub before installing the plug-in.'
    }

    $changes = New-Object System.Collections.ArrayList
    try {
        foreach ($name in @('FFBInterceptor.SimHub.dll', 'FFBInterceptor.Core.dll')) {
            $record = Install-ManagedFile -Source (Join-Path $bundleRoot (Join-Path 'simhub' $name)) `
                -Destination (Join-Path $simHubPath $name)
            [void]$changes.Add($record)
        }
    }
    catch {
        if (-not $WhatIfPreference) {
            for ($index = $changes.Count - 1; $index -ge 0; $index--) { Restore-ManagedFile -Record $changes[$index] }
        }
        throw
    }

    $state = [pscustomobject][ordered]@{
        SchemaVersion = 1
        InstalledAtUtc = [DateTime]::UtcNow.ToString('o')
        InstallPath = $simHubPath
        Files = @($changes)
    }
    if (-not $WhatIfPreference) {
        try { Save-FFBPluginState -State $state }
        catch {
            for ($index = $changes.Count - 1; $index -ge 0; $index--) { Restore-ManagedFile -Record $changes[$index] }
            throw
        }
    }
    if (-not $NoDashboardImport -and -not (Test-FFBAdministrator) -and -not $WhatIfPreference) { Open-Dashboards }
    Write-Host "Installed the FFB Interceptor SimHub plug-in in: $simHubPath"
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
