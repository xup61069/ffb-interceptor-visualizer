# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$SimHubInstallPath = '',
    [switch]$NoDashboardImport,
    [switch]$NoElevation,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$commonScript = Join-Path (Split-Path -Parent $PSCommandPath) 'FFBInterceptor.Common.ps1'
if (-not (Test-Path -LiteralPath $commonScript -PathType Leaf)) { throw "Package file is missing: $commonScript" }
. $commonScript

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

function Invoke-ElevatedSelf {
    $command = "& '" + $PSCommandPath.Replace("'", "''") + "' -NoElevation -NoPause -NoDashboardImport"
    if ($SimHubInstallPath) { $command += " -SimHubInstallPath '" + $SimHubInstallPath.Replace("'", "''") + "'" }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded" -Verb RunAs -Wait -PassThru
    return $process.ExitCode
}

try {
    $bundleRoot = Split-Path -Parent $PSCommandPath
    $existingState = Read-FFBPluginState -AllowMissing -RequireSimHubExecutable
    if ($null -ne $existingState) {
        if (Test-StateValid -State $existingState) {
            if (Test-StateMatchesPackage -State $existingState -BundleRoot $bundleRoot) {
                Write-Host 'The SimHub plug-in from this package is already installed and verified.'
                exit 0
            }
            throw 'A different FFB Interceptor SimHub plug-in version is installed. Run Uninstall-SimHubPlugin.cmd, then start this package again.'
        }
        throw 'The recorded SimHub plug-in files changed or are missing. Run Uninstall-SimHubPlugin.cmd before reinstalling.'
    }

    if (-not $NoElevation -and -not $WhatIfPreference -and -not (Test-FFBAdministrator)) {
        $exitCode = Invoke-ElevatedSelf
        if ($exitCode -eq 0 -and -not $NoDashboardImport) { Open-Dashboards }
        exit $exitCode
    }

    $simHubPath = Resolve-SimHubPath -Path $SimHubInstallPath
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
