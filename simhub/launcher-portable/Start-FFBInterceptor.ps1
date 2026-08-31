# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [string]$GameExecutable = '',
    [string]$SimHubInstallPath = '',
    [switch]$SkipSimHubCheck,
    [switch]$ValidateOnly,
    [switch]$NoPause,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$GameArguments = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$commonScript = Join-Path (Split-Path -Parent $PSCommandPath) 'FFBInterceptor.Common.ps1'
if (-not (Test-Path -LiteralPath $commonScript -PathType Leaf)) { throw "Package file is missing: $commonScript" }
. $commonScript
[void](Assert-FFBPackageManifest -BundleRoot (Split-Path -Parent $PSCommandPath))

function Resolve-GameExecutable {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = 'Select the offline game executable'
        $dialog.Filter = 'Executable files (*.exe)|*.exe'
        $dialog.CheckFileExists = $true
        $dialog.Multiselect = $false
        try {
            if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { throw 'No game executable was selected.' }
            $Path = $dialog.FileName
        }
        finally { $dialog.Dispose() }
    }
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    if ([IO.Path]::GetExtension($resolved) -ine '.exe') { throw 'The selected file must be an .exe.' }
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
        if ($peOffset -lt 0x40 -or $peOffset -gt ($stream.Length - 6)) { throw 'The PE header offset is invalid.' }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw 'The selected file is not a PE executable.' }
        switch ($reader.ReadUInt16()) {
            0x014c { return 'x86' }
            0x8664 { return 'x64' }
            default { throw 'Only x86 and x64 games are supported.' }
        }
    }
    finally { $reader.Dispose(); $stream.Dispose() }
}

function Wait-FFBSimHubPipe {
    $typeName = 'FFBInterceptor.LauncherNativeMethods'
    if (-not ($typeName -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace FFBInterceptor {
    public static class LauncherNativeMethods {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool WaitNamedPipe(string name, uint timeoutMilliseconds);
    }
}
'@
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        if ([FFBInterceptor.LauncherNativeMethods]::WaitNamedPipe(
            '\\.\pipe\ffb-interceptor-simhub-v1', 1000)) { return $true }
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($code -eq 121 -or $code -eq 231) { return $true }
        if ($code -ne 2) { throw "Unable to check the SimHub pipe (Windows error $code)." }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Open-FFBManager {
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $managerPath = Join-Path $BundleRoot 'FFBInterceptor.Manager.exe'
    if (-not (Test-Path -LiteralPath $managerPath -PathType Leaf)) {
        throw "Package file is missing: $managerPath"
    }
    $manager = Get-Item -LiteralPath $managerPath -Force
    if ($manager.PSIsContainer -or
        ($manager.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "The package Manager is not a regular file: $managerPath"
    }
    Write-Host $Message
    Start-Process -FilePath $manager.FullName | Out-Null
}

try {
    if (-not $ValidateOnly -and (Test-FFBAdministrator)) {
        throw 'For safety, start the game from a normal non-administrator account.'
    }

    $bundleRoot = Split-Path -Parent $PSCommandPath
    if (-not $ValidateOnly -and -not $SkipSimHubCheck) {
        $statePath = Get-FFBStatePath
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
            Open-FFBManager -BundleRoot $bundleRoot -Message `
                'SimHub plug-in setup is handled by FFBInterceptor Manager. Complete setup in the Manager window.'
            exit 0
        }

        # Start never installs or elevates.  -NoElevation is used only after a
        # protected state file already exists, so the installer can take its
        # idempotent verification path. Any repair remains a Manager action.
        $installerArguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
            (Join-Path $bundleRoot 'Install-SimHubPlugin.ps1'),
            '-NoElevation', '-NoDashboardImport', '-NoPause'
        )
        if ($SimHubInstallPath) { $installerArguments += @('-SimHubInstallPath', $SimHubInstallPath) }
        & powershell.exe @installerArguments
        if ($LASTEXITCODE -ne 0) {
            Open-FFBManager -BundleRoot $bundleRoot -Message `
                'The managed SimHub plug-in needs repair or an update. Continue in the FFBInterceptor Manager window.'
            exit 0
        }

        $state = Read-FFBPluginState -RequireSimHubExecutable
        $simHubExe = Get-FFBSimHubExecutablePath -Path ([string]$state.InstallPath)
        if (-not (Get-Process -Name 'SimHub', 'SimHubWPF' -ErrorAction SilentlyContinue) -and
            (Test-Path -LiteralPath $simHubExe -PathType Leaf)) {
            Start-Process -FilePath $simHubExe | Out-Null
        }
        if (-not (Wait-FFBSimHubPipe)) {
            throw 'The SimHub plug-in pipe did not become ready. Enable FFB Interceptor in SimHub, then try again.'
        }
    }

    $gamePath = Resolve-GameExecutable -Path $GameExecutable
    $architecture = Get-PortableArchitecture -Path $gamePath
    $launcherDirectory = Join-Path $bundleRoot (Join-Path 'launcher' $architecture)
    $launcher = Join-Path $launcherDirectory 'FFBInterceptor.Launcher.exe'
    $hook = Join-Path $launcherDirectory 'FFBInterceptor.Hook.dll'
    foreach ($required in @($launcher, $hook)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Package file is missing: $required" }
        if ((Get-PortableArchitecture -Path $required) -ne $architecture) { throw "Package architecture mismatch: $required" }
    }

    if ($ValidateOnly) {
        Write-Host "Validated $architecture launcher files for: $gamePath"
        exit 0
    }

    $arguments = @('--offline-only', '--game', $gamePath, '--') + @($GameArguments)
    & $launcher @arguments
    if ($LASTEXITCODE -ne 0) { throw "The offline launcher failed with exit code $LASTEXITCODE." }
}
catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    if (-not $NoPause) { [void](Read-Host 'Press Enter to close') }
    exit 1
}
