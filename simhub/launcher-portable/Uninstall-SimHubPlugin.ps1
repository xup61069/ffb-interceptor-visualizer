# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding(SupportsShouldProcess = $true)]
param([switch]$NoElevation, [switch]$NoPause)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$commonScript = Join-Path (Split-Path -Parent $PSCommandPath) 'FFBInterceptor.Common.ps1'
if (-not (Test-Path -LiteralPath $commonScript -PathType Leaf)) { throw "Package file is missing: $commonScript" }
. $commonScript

function Invoke-ElevatedSelf {
    $command = "& '" + $PSCommandPath.Replace("'", "''") + "' -NoElevation -NoPause"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded" -Verb RunAs -Wait -PassThru
    return $process.ExitCode
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
    if (-not $NoElevation -and -not $WhatIfPreference -and -not (Test-FFBAdministrator)) { exit (Invoke-ElevatedSelf) }
    $state = Read-FFBPluginState
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
