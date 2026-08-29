# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$GameExecutable = '',
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
        $dialog.Title = 'Select the game executable to uninstall'
        $dialog.Filter = 'Executable files (*.exe)|*.exe'
        $dialog.CheckFileExists = $true
        try {
            if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { throw 'No game executable was selected.' }
            $Path = $dialog.FileName
        }
        finally { $dialog.Dispose() }
    }
    return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
}

function Get-StatePath {
    return Join-Path (Join-Path $env:LOCALAPPDATA 'FFBInterceptor') 'install-state.json'
}

function Remove-ManagedFile {
    param([Parameter(Mandatory = $true)]$Record)

    $destination = [string]$Record.Destination
    $backup = [string]$Record.Backup
    $installedHash = [string]$Record.InstalledSha256
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        if ((Get-FileSha256 -Path $destination) -ne $installedHash) {
            if (-not [string]::IsNullOrWhiteSpace($backup) -and -not (Test-Path -LiteralPath $backup)) {
                # A previous uninstall pass already restored the original file.
                return
            }
            throw "Refusing to remove a changed file: $destination"
        }
        if ($PSCmdlet.ShouldProcess($destination, 'Remove FFB Interceptor file')) {
            Remove-Item -LiteralPath $destination -Force
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($backup) -and (Test-Path -LiteralPath $backup)) {
        if (Test-Path -LiteralPath $destination) {
            throw "Refusing to overwrite a file while restoring backup: $destination"
        }
        if ($PSCmdlet.ShouldProcess($destination, 'Restore original backup')) {
            Move-Item -LiteralPath $backup -Destination $destination
        }
    }
}

if (-not $NoElevation -and -not (Test-Administrator)) {
    try {
        Invoke-ElevatedSelf
        exit 0
    }
    catch {
        Write-Error 'Administrator approval is required to restore files in a game or SimHub folder.'
        if (-not $NoPause) { [void](Read-Host 'Press Enter to close') }
        exit 1
    }
}

try {
    $statePath = Get-StatePath
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw 'No FFB Interceptor installation state was found for this Windows user.'
    }
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $gamePath = Resolve-GameExecutable -Path $GameExecutable
    $games = @($state.Games)
    $gameRecord = @($games | Where-Object { $_.GameExecutable -ieq $gamePath }) | Select-Object -First 1
    if ($null -eq $gameRecord) { throw 'The selected game is not managed by this FFB Interceptor installation.' }

    Remove-ManagedFile -Record $gameRecord.Proxy
    $remainingGames = @($games | Where-Object { $_.GameExecutable -ine $gamePath })
    if ($remainingGames.Count -eq 0 -and $null -ne $state.SimHub) {
        foreach ($file in @($state.SimHub.Files)) { Remove-ManagedFile -Record $file }
    }

    if ($WhatIfPreference) {
        Write-Host 'WhatIf complete; installation state was not changed.'
    }
    elseif ($remainingGames.Count -eq 0) {
        Remove-Item -LiteralPath $statePath -Force
        $stateDirectory = Split-Path -Parent $statePath
        if (-not (Get-ChildItem -LiteralPath $stateDirectory -Force -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $stateDirectory -Force
        }
    }
    else {
        $updated = [ordered]@{
            SchemaVersion = 1
            InstalledAtUtc = [string]$state.InstalledAtUtc
            SimHub = $state.SimHub
            Games = $remainingGames
        }
        [IO.File]::WriteAllText($statePath, ($updated | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    }
    Write-Host 'FFB Interceptor was removed for the selected game. Any original dinput8.dll backup was restored.'
}
catch {
    Write-Error $_.Exception.Message
    if (-not $NoPause) { [void](Read-Host 'Press Enter to close') }
    exit 1
}

if (-not $NoPause) { [void](Read-Host 'Uninstall complete. Press Enter to close') }
