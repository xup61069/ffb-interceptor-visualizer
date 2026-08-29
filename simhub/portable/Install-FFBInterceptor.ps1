# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$GameExecutable = '',
    [string]$SimHubInstallPath = '',
    [switch]$SkipSimHub,
    [switch]$NoDashboardImport,
    [switch]$NoElevation,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ElevatedSelf {
    $command = "& '" + $PSCommandPath.Replace("'", "''") + "'"
    if (-not [string]::IsNullOrWhiteSpace($GameExecutable)) {
        $command += " -GameExecutable '" + $GameExecutable.Replace("'", "''") + "'"
    }
    if (-not [string]::IsNullOrWhiteSpace($SimHubInstallPath)) {
        $command += " -SimHubInstallPath '" + $SimHubInstallPath.Replace("'", "''") + "'"
    }
    if ($SkipSimHub) { $command += ' -SkipSimHub' }
    if ($NoDashboardImport) { $command += ' -NoDashboardImport' }
    if ($NoPause) { $command += ' -NoPause' }

    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    $startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"
    $startInfo.UseShellExecute = $true
    $startInfo.Verb = 'runas'
    [Diagnostics.Process]::Start($startInfo) | Out-Null
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Resolve-GameExecutable {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = 'Select the game executable'
        $dialog.Filter = 'Executable files (*.exe)|*.exe'
        $dialog.CheckFileExists = $true
        $dialog.Multiselect = $false
        try {
            if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
                throw 'No game executable was selected.'
            }
            $Path = $dialog.FileName
        }
        finally {
            $dialog.Dispose()
        }
    }

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf) -or
        [IO.Path]::GetExtension($resolved) -ine '.exe') {
        throw "GameExecutable must point to an existing .exe file: $Path"
    }
    return $resolved
}

function Get-PortableArchitecture {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw 'The selected file is not a PE executable.' }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        if ($peOffset -lt 0x40 -or $peOffset -gt ($stream.Length - 6)) {
            throw 'The selected executable has an invalid PE header offset.'
        }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw 'The selected file is not a PE executable.' }

        switch ($reader.ReadUInt16()) {
            0x014c { return 'x86' }
            0x8664 { return 'x64' }
            default { throw 'Only x86 and x64 game executables are supported by this package.' }
        }
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Resolve-SimHubInstallPath {
    param([string]$Path)

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
        if (-not (Test-Path -LiteralPath (Join-Path $resolved 'SimHub.exe') -PathType Leaf)) {
            throw "SimHub.exe was not found in: $resolved"
        }
        return $resolved
    }

    $candidates = @()
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'SimHub') }
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'SimHub') }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'SimHub.exe') -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Select the SimHub installation folder'
    try {
        if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
            throw 'SimHub installation folder was not selected.'
        }
        return Resolve-SimHubInstallPath -Path $dialog.SelectedPath
    }
    finally {
        $dialog.Dispose()
    }
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

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Package file is missing: $Source"
    }

    $sourceHash = Get-FileSha256 -Path $Source
    if ((Test-Path -LiteralPath $Destination -PathType Leaf) -and
        (Get-FileSha256 -Path $Destination) -eq $sourceHash) {
        return [ordered]@{
            Destination = $Destination
            Backup = ''
            InstalledSha256 = $sourceHash
            Changed = $false
        }
    }

    $backup = ''
    if ($PSCmdlet.ShouldProcess($Destination, "Install $([IO.Path]::GetFileName($Source))")) {
        $temporary = "$Destination.ffb-interceptor-new-$PID"
        try {
            if (Test-Path -LiteralPath $Destination -PathType Leaf) {
                $backup = Get-BackupPath -Destination $Destination
                Move-Item -LiteralPath $Destination -Destination $backup -ErrorAction Stop
            }
            Copy-Item -LiteralPath $Source -Destination $temporary -ErrorAction Stop
            Move-Item -LiteralPath $temporary -Destination $Destination -ErrorAction Stop
        }
        catch {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $Destination) -and -not [string]::IsNullOrWhiteSpace($backup) -and
                (Test-Path -LiteralPath $backup)) {
                Move-Item -LiteralPath $backup -Destination $Destination -ErrorAction SilentlyContinue
            }
            throw
        }
    }

    return [ordered]@{
        Destination = $Destination
        Backup = $backup
        InstalledSha256 = $sourceHash
        Changed = $true
    }
}

function Restore-ManagedFile {
    param([Parameter(Mandatory = $true)]$Record)

    if (-not $Record.Changed) { return }
    $destination = [string]$Record.Destination
    if ((Test-Path -LiteralPath $destination -PathType Leaf) -and
        (Get-FileSha256 -Path $destination) -eq [string]$Record.InstalledSha256) {
        Remove-Item -LiteralPath $destination -Force
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Record.Backup) -and
        (Test-Path -LiteralPath ([string]$Record.Backup)) -and
        -not (Test-Path -LiteralPath $destination)) {
        Move-Item -LiteralPath ([string]$Record.Backup) -Destination $destination
    }
}

function Get-StatePath {
    return Join-Path (Join-Path $env:LOCALAPPDATA 'FFBInterceptor') 'install-state.json'
}

function Read-InstallState {
    $path = Get-StatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    }
    catch {
        throw "The existing installation state is invalid: $path"
    }
}

function Save-InstallState {
    param([Parameter(Mandatory = $true)]$State)
    $path = Get-StatePath
    $directory = Split-Path -Parent $path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    [IO.File]::WriteAllText($path, ($State | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}

if (-not $NoElevation -and -not (Test-Administrator)) {
    try {
        Invoke-ElevatedSelf
        exit 0
    }
    catch {
        Write-Error 'Administrator approval is required to install into a game or SimHub folder.'
        if (-not $NoPause) { [void](Read-Host 'Press Enter to close') }
        exit 1
    }
}

try {
    $bundleRoot = Split-Path -Parent $PSCommandPath
    $gamePath = Resolve-GameExecutable -Path $GameExecutable
    $architecture = Get-PortableArchitecture -Path $gamePath
    $proxySource = Join-Path $bundleRoot (Join-Path 'runtime' (Join-Path $architecture 'dinput8.dll'))
    $state = Read-InstallState
    $existingGames = if ($null -eq $state) { @() } else { @($state.Games) }
    if ($existingGames | Where-Object { $_.GameExecutable -ieq $gamePath }) {
        throw 'This game is already managed by FFB Interceptor. Run Uninstall-FFBInterceptor.cmd before changing versions.'
    }

    $changes = New-Object System.Collections.ArrayList
    $simHubRecord = if ($null -eq $state) { $null } else { $state.SimHub }
    try {
        if (-not $SkipSimHub -and $null -eq $simHubRecord) {
            $simHubPath = Resolve-SimHubInstallPath -Path $SimHubInstallPath
            if (Get-Process -Name 'SimHub' -ErrorAction SilentlyContinue) {
                throw 'Close SimHub before installing the plug-in.'
            }
            $simHubFiles = @()
            foreach ($name in @('FFBInterceptor.SimHub.dll', 'FFBInterceptor.Core.dll')) {
                $record = Install-ManagedFile -Source (Join-Path $bundleRoot (Join-Path 'simhub' $name)) -Destination (Join-Path $simHubPath $name)
                [void]$changes.Add($record)
                $simHubFiles += $record
            }
            $simHubRecord = [ordered]@{ InstallPath = $simHubPath; Files = $simHubFiles }
        }
        elseif (-not $SkipSimHub -and -not [string]::IsNullOrWhiteSpace($SimHubInstallPath) -and
                $simHubRecord.InstallPath -ine (Resolve-SimHubInstallPath -Path $SimHubInstallPath)) {
            throw 'A different SimHub installation is already managed. Uninstall the existing game before changing SimHub paths.'
        }

        $proxyRecord = Install-ManagedFile -Source $proxySource -Destination (Join-Path (Split-Path -Parent $gamePath) 'dinput8.dll')
        [void]$changes.Add($proxyRecord)
    }
    catch {
        for ($index = $changes.Count - 1; $index -ge 0; $index--) {
            Restore-ManagedFile -Record $changes[$index]
        }
        throw
    }

    $gameRecord = [ordered]@{ GameExecutable = $gamePath; Architecture = $architecture; Proxy = $proxyRecord }
    $updatedState = [ordered]@{
        SchemaVersion = 1
        InstalledAtUtc = [DateTime]::UtcNow.ToString('o')
        SimHub = $simHubRecord
        Games = @($existingGames) + @($gameRecord)
    }
    if (-not $WhatIfPreference) { Save-InstallState -State $updatedState }

    Write-Host ''
    Write-Host "Installed the $architecture proxy beside: $gamePath"
    if ($SkipSimHub) {
        Write-Host 'SimHub plug-in installation was skipped.'
    }
    else {
        Write-Host "Installed the SimHub plug-in in: $($simHubRecord.InstallPath)"
        if (-not $NoDashboardImport -and -not $WhatIfPreference) {
            foreach ($dashboard in @('FFB Interceptor 800x480.simhubdash', 'FFB Interceptor Overlay 480x160.simhubdash')) {
                try { Start-Process -FilePath (Join-Path $bundleRoot (Join-Path 'Dashboards' $dashboard)) | Out-Null }
                catch { Write-Warning "Open this dashboard manually: $dashboard" }
            }
        }
    }
    Write-Host 'Start SimHub, enable FFB Interceptor in Settings > Plugins, then start the game.'
}
catch {
    Write-Error $_.Exception.Message
    if (-not $NoPause) { [void](Read-Host 'Press Enter to close') }
    exit 1
}

if (-not $NoPause) { [void](Read-Host 'Installation complete. Press Enter to close') }
