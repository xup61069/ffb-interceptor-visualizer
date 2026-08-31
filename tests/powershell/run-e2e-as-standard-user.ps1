# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$E2ETest,
    [Parameter(Mandatory = $true)][string]$LauncherPath,
    [Parameter(Mandatory = $true)][string]$ProbePath,
    [int]$TimeoutMilliseconds = 45000
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Resolve-FFBRegularFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $item = Get-Item -LiteralPath $resolved -Force
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        $item.Length -le 0) {
        throw "E2E input is not a non-empty regular file: $resolved"
    }
    return $resolved
}

function Test-FFBAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        return ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    finally { $identity.Dispose() }
}

function Invoke-FFBE2E {
    param(
        [Parameter(Mandatory = $true)][string]$Test,
        [Parameter(Mandatory = $true)][string]$Launcher,
        [Parameter(Mandatory = $true)][string]$Probe
    )
    & $Test $Launcher $Probe
    if ($LASTEXITCODE -ne 0) {
        throw "Launcher E2E failed with exit code $LASTEXITCODE"
    }
}

$test = Resolve-FFBRegularFile -Path $E2ETest
$launcher = Resolve-FFBRegularFile -Path $LauncherPath
$probe = Resolve-FFBRegularFile -Path $ProbePath
$hook = Resolve-FFBRegularFile -Path (
    Join-Path (Split-Path -Parent $launcher) 'FFBInterceptor.Hook.dll')
$core = Resolve-FFBRegularFile -Path (
    Join-Path (Split-Path -Parent $test) 'FFBInterceptor.Core.dll')
$configuration = Resolve-FFBRegularFile -Path ($test + '.config')

if (-not (Test-FFBAdministrator)) {
    Invoke-FFBE2E -Test $test -Launcher $launcher -Probe $probe
    return
}
if ($env:GITHUB_ACTIONS -cne 'true') {
    throw 'Elevated E2E requires an ephemeral GitHub-hosted runner; refusing to create a local test account.'
}
if ($TimeoutMilliseconds -lt 1000 -or $TimeoutMilliseconds -gt 120000) {
    throw 'TimeoutMilliseconds must be between 1000 and 120000.'
}

$runnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP)
$staging = [IO.Path]::GetFullPath((Join-Path $runnerTemp (
    'ffb-e2e-standard-user-' + [Guid]::NewGuid().ToString('N'))))
$runnerPrefix = $runnerTemp.TrimEnd([IO.Path]::DirectorySeparatorChar) +
    [IO.Path]::DirectorySeparatorChar
if (-not $staging.StartsWith($runnerPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe E2E staging path: $staging"
}

$accountName = 'ffbe2e' + [Guid]::NewGuid().ToString('N').Substring(0, 10)
$qualifiedAccount = "$env:COMPUTERNAME\$accountName"
$password = [Guid]::NewGuid().ToString('N') + '!aA9'
$accountCreated = $false
$child = $null
$securePassword = $null
$credential = $null
$primaryError = $null
$cleanupErrors = [Collections.Generic.List[string]]::new()
try {
    [IO.Directory]::CreateDirectory($staging) | Out-Null
    $probeDirectory = Join-Path $staging 'e2e'
    [IO.Directory]::CreateDirectory($probeDirectory) | Out-Null

    $stagedTest = Join-Path $staging 'FFBInterceptor.E2E.Tests.exe'
    $stagedLauncher = Join-Path $staging 'FFBInterceptor.Launcher.exe'
    $stagedProbe = Join-Path $probeDirectory 'FFBInterceptor.E2E.Probe.exe'
    Copy-Item -LiteralPath $test -Destination $stagedTest
    Copy-Item -LiteralPath $configuration -Destination ($stagedTest + '.config')
    Copy-Item -LiteralPath $core -Destination (Join-Path $staging 'FFBInterceptor.Core.dll')
    Copy-Item -LiteralPath $launcher -Destination $stagedLauncher
    Copy-Item -LiteralPath $hook -Destination (Join-Path $staging 'FFBInterceptor.Hook.dll')
    Copy-Item -LiteralPath $probe -Destination $stagedProbe

    $net = Join-Path ([Environment]::SystemDirectory) 'net.exe'
    & $net user $accountName $password /add /active:yes /expires:never `
        /passwordchg:no /passwordreq:yes /Y | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not create the ephemeral standard-user account (exit $LASTEXITCODE)."
    }
    $accountCreated = $true

    $icacls = Join-Path ([Environment]::SystemDirectory) 'icacls.exe'
    & $icacls $staging /grant:r "${qualifiedAccount}:(OI)(CI)(RX)" /q | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not grant the ephemeral account read access (exit $LASTEXITCODE)."
    }

    $securePassword = ConvertTo-SecureString -String $password -AsPlainText -Force
    $credential = [Management.Automation.PSCredential]::new(
        $qualifiedAccount, $securePassword)
    $standardOutput = Join-Path $staging 'stdout.txt'
    $standardError = Join-Path $staging 'stderr.txt'
    $arguments = @(
        '"' + $stagedLauncher + '"',
        '"' + $stagedProbe + '"'
    )
    $child = Start-Process -FilePath $stagedTest -ArgumentList $arguments `
        -Credential $credential -LoadUserProfile -WorkingDirectory $staging `
        -WindowStyle Hidden -RedirectStandardOutput $standardOutput `
        -RedirectStandardError $standardError -PassThru
    if (-not $child.WaitForExit($TimeoutMilliseconds)) {
        $taskkill = Join-Path ([Environment]::SystemDirectory) 'taskkill.exe'
        & $taskkill /PID $child.Id /T /F | Out-Null
        $taskkillExit = $LASTEXITCODE
        $stopped = $child.WaitForExit(5000)
        if (-not $stopped) {
            throw "Standard-user Launcher E2E timed out and its process tree could not be stopped (taskkill exit $taskkillExit)."
        }
        throw "Standard-user Launcher E2E timed out after $TimeoutMilliseconds ms."
    }

    $stdout = if (Test-Path -LiteralPath $standardOutput) {
        Get-Content -LiteralPath $standardOutput -Raw -Encoding UTF8
    }
    else { '' }
    $stderr = if (Test-Path -LiteralPath $standardError) {
        Get-Content -LiteralPath $standardError -Raw -Encoding UTF8
    }
    else { '' }
    if (-not [string]::IsNullOrWhiteSpace($stdout)) { Write-Host $stdout.TrimEnd() }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) { Write-Error ($stderr.TrimEnd()) }
    if ($child.ExitCode -ne 0) {
        throw "Standard-user Launcher E2E failed with exit code $($child.ExitCode)."
    }
    Write-Host "PASS E2E used ephemeral standard account $accountName"
}
catch {
    $primaryError = $_
}
finally {
    if ($null -ne $child) {
        try {
            if (-not $child.HasExited) {
                $taskkill = Join-Path ([Environment]::SystemDirectory) 'taskkill.exe'
                & $taskkill /PID $child.Id /T /F | Out-Null
                $cleanupKillExit = $LASTEXITCODE
                if (-not $child.WaitForExit(5000)) {
                    $cleanupErrors.Add(
                        "Could not stop the E2E process tree (taskkill exit $cleanupKillExit).")
                }
            }
        }
        catch {
            $cleanupErrors.Add("Could not verify E2E process exit: $($_.Exception.Message)")
        }
        try { $child.Dispose() }
        catch {
            $cleanupErrors.Add("Could not dispose the E2E process handle: $($_.Exception.Message)")
        }
    }
    $password = $null
    $securePassword = $null
    $credential = $null
    if ($accountCreated) {
        try {
            $net = Join-Path ([Environment]::SystemDirectory) 'net.exe'
            & $net user $accountName /delete | Out-Null
            if ($LASTEXITCODE -ne 0) {
                $cleanupErrors.Add(
                    "Could not delete ephemeral account $accountName (exit $LASTEXITCODE).")
            }
        }
        catch {
            $cleanupErrors.Add(
                "Could not delete ephemeral account $accountName : $($_.Exception.Message)")
        }
    }
    if (Test-Path -LiteralPath $staging) {
        $verifiedStaging = $null
        try {
            $verifiedStaging = [IO.Path]::GetFullPath((
                Resolve-Path -LiteralPath $staging).Path)
            if (-not $verifiedStaging.StartsWith(
                    $runnerPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Unsafe cleanup path: $verifiedStaging"
            }
        }
        catch {
            $cleanupErrors.Add("Could not remove E2E staging: $($_.Exception.Message)")
            $verifiedStaging = $null
        }
        if ($null -ne $verifiedStaging) {
            $removeError = $null
            for ($attempt = 1; $attempt -le 15; $attempt++) {
                try {
                    Remove-Item -LiteralPath $verifiedStaging -Recurse -Force
                    $removeError = $null
                    break
                }
                catch {
                    $removeError = $_
                    if ($attempt -lt 15) { Start-Sleep -Milliseconds 500 }
                }
            }
            if ($null -ne $removeError) {
                $cleanupErrors.Add(
                    "Could not remove E2E staging: $($removeError.Exception.Message)")
            }
        }
    }
}
if ($null -ne $primaryError) {
    if ($cleanupErrors.Count -gt 0) {
        Write-Warning ("Cleanup after the E2E failure was incomplete: " +
            ($cleanupErrors -join ' '))
    }
    throw $primaryError
}
if ($cleanupErrors.Count -gt 0) {
    throw ($cleanupErrors -join ' ')
}
