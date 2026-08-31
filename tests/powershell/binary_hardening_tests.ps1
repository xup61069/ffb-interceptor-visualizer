# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$BinaryPaths,
    [string]$DumpbinPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($DumpbinPath)) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $vsRoot = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or -not $vsRoot) {
        throw 'Visual Studio C++ tools were not found.'
    }
    $DumpbinPath = Get-ChildItem -LiteralPath (Join-Path $vsRoot 'VC\Tools\MSVC') `
        -Filter 'dumpbin.exe' -Recurse -File |
        Where-Object FullName -match '\\Hostx64\\x64\\dumpbin\.exe$' |
        Sort-Object FullName -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
$dumpbin = (Resolve-Path -LiteralPath $DumpbinPath -ErrorAction Stop).Path
$forbiddenRuntime = '(?im)^\s*(?:MSVCP[A-Za-z0-9_]*|MSVCR[A-Za-z0-9_]*|VCRUNTIME[A-Za-z0-9_]*|CONCRT[A-Za-z0-9_]*|ucrtbase|api-ms-win-crt-[A-Za-z0-9-]+)\.dll\s*$'
$system32OnlyFlag = '(?im)^\s*0*800\s+Dependent Load Flag\s*$'

foreach ($path in $BinaryPaths) {
    $binary = (Resolve-Path -LiteralPath $path -ErrorAction Stop).Path
    $info = Get-Item -LiteralPath $binary -Force
    if ($info.PSIsContainer -or ($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        $info.Length -le 0) {
        throw "Binary hardening candidate is not a non-empty regular file: $binary"
    }

    $dependencies = (& $dumpbin /nologo /dependents $binary 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "dumpbin /dependents failed for $binary" }
    if ($dependencies -match $forbiddenRuntime) {
        throw "Binary uses an app-local Microsoft runtime instead of the static CRT: $binary"
    }

    $loadConfig = (& $dumpbin /nologo /loadconfig $binary 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "dumpbin /loadconfig failed for $binary" }
    if ($loadConfig -notmatch $system32OnlyFlag) {
        throw "Binary does not set DependentLoadFlags=LOAD_LIBRARY_SEARCH_SYSTEM32: $binary"
    }
}

Write-Host "PASS static CRT and System32-only import policy for $($BinaryPaths.Count) binaries"
