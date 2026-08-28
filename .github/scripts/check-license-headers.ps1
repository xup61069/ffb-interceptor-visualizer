# SPDX-License-Identifier: GPL-3.0-only
$ErrorActionPreference = 'Stop'

<#
  Check the SPDX marker on every tracked implementation/build file with a
  comment-compatible format that is distributed in source or binary archives.
  The wrapper files derived from
  walmis/dcs-force-feedback-fix remain MIT; all project-authored files are GPL.
#>

$mitFiles = @(
    'src/proxy.cpp',
    'src/proxy.h',
    'src/wrapper_device8.cpp',
    'src/wrapper_device8.h',
    'src/wrapper_dinput8.cpp',
    'src/wrapper_dinput8.h',
    'src/wrapper_effect.cpp',
    'src/wrapper_effect.h'
)

$tracked = @(git ls-files)
$targets = @(
    $tracked | Where-Object {
        $_ -match '^(src|tests/cpp|viewer/src|viewer/tests|\.github/scripts)/.*\.(cpp|h|py|ps1)$' -or
        $_ -match '^viewer/[^/]+\.py$'
    }
    $tracked | Where-Object { $_ -in @('CMakeLists.txt', 'dinput8.def', 'viewer/pyproject.toml') }
)

$marker = [regex]'(?m)^\s*(?://|#|;)\s*SPDX-License-Identifier:\s*(MIT|GPL-3\.0-only)\s*$'
$failures = @()
foreach ($path in ($targets | Sort-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $failures += "$path (tracked file is missing from the workspace)"
        continue
    }
    $head = (Get-Content -LiteralPath $path -TotalCount 16) -join "`n"
    $match = $marker.Match($head)
    $expected = if ($path -in $mitFiles) { 'MIT' } else { 'GPL-3.0-only' }
    if (-not $match.Success) {
        $failures += "$path (missing SPDX-License-Identifier; expected $expected)"
    }
    elseif ($match.Groups[1].Value -ne $expected) {
        $failures += "$path (found $($match.Groups[1].Value); expected $expected)"
    }
}

if ($failures.Count -gt 0) {
    Write-Error ('SPDX license header audit failed:`n - ' + ($failures -join "`n - "))
    exit 1
}

Write-Output ("SPDX license header audit passed for {0} tracked files." -f $targets.Count)
