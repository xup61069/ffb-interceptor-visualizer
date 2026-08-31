# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BuildDirectory,
    [Parameter(Mandatory = $true)]
    [string]$E2ETest
)

$ErrorActionPreference = 'Stop'
$build = (Resolve-Path -LiteralPath $BuildDirectory).Path
$e2e = (Resolve-Path -LiteralPath $E2ETest).Path

& ctest.exe --test-dir $build --output-on-failure
if ($LASTEXITCODE -ne 0) { throw "CTest failed with exit code $LASTEXITCODE" }

& $e2e `
    (Join-Path $build 'FFBInterceptor.Launcher.exe') `
    (Join-Path $build 'e2e\FFBInterceptor.E2E.Probe.exe')
if ($LASTEXITCODE -ne 0) { throw "Launcher E2E failed with exit code $LASTEXITCODE" }
