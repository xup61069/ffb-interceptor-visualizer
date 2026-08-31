# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BuildDirectory
)

$ErrorActionPreference = 'Stop'
$build = (Resolve-Path -LiteralPath $BuildDirectory).Path

& ctest.exe --test-dir $build --output-on-failure
if ($LASTEXITCODE -ne 0) { throw "CTest failed with exit code $LASTEXITCODE" }
