# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CommandPath,
    [string[]]$CommandArguments = @(),
    [Parameter(Mandatory = $true)]
    [string[]]$IncludeFiles,
    [Parameter(Mandatory = $true)]
    [string]$Output
)

$ErrorActionPreference = 'Stop'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { throw 'vswhere.exe was not found' }
$visualStudio = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($visualStudio)) {
    throw 'A Visual Studio installation with C++ tools was not found'
}
$candidates = @(
    (Join-Path $visualStudio 'Common7\IDE\Extensions\Microsoft\CodeCoverage.Console\Microsoft.CodeCoverage.Console.exe'),
    (Join-Path $visualStudio 'Common7\IDE\CommonExtensions\Microsoft\TestWindow\Microsoft.CodeCoverage.Console.exe')
)
$coverage = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $coverage) { throw 'Microsoft.CodeCoverage.Console.exe was not found in Visual Studio' }

$resolvedCommand = (Resolve-Path -LiteralPath $CommandPath).Path
$outputPath = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Output))
if (Test-Path -LiteralPath $outputPath) { Remove-Item -LiteralPath $outputPath -Force }
$arguments = @('collect', $resolvedCommand) + $CommandArguments + @(
    '--output', $outputPath,
    '--output-format', 'cobertura',
    '--include-files', ($IncludeFiles -join ';'),
    '--nologo'
)
& $coverage @arguments
if ($LASTEXITCODE -ne 0) { throw "Code coverage collection failed with exit code $LASTEXITCODE" }
if (-not (Test-Path -LiteralPath $outputPath)) { throw 'Code coverage report was not created' }
Write-Host "Wrote Cobertura coverage report: $outputPath"
