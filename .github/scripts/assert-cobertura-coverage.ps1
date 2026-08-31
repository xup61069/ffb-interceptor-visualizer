# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Report,
    [Parameter(Mandatory = $true)]
    [string[]]$PathContains,
    [ValidateRange(0, 100)]
    [double]$MinimumPercent,
    [ValidateRange(1, 1000000)]
    [int]$MinimumTrackedLines = 20,
    [switch]$RequireEachPath
)

$ErrorActionPreference = 'Stop'
[xml]$document = Get-Content -Raw -LiteralPath $Report
$records = @{}
$matchedPaths = @{}
$PathContains | ForEach-Object { $matchedPaths[$_] = $false }
$classes = @($document.coverage.packages.package.classes.class)
foreach ($class in $classes) {
    $file = ([string]$class.filename).Replace('\', '/')
    $matchingPaths = @($PathContains | Where-Object {
        $file.IndexOf($_.Replace('\', '/'), [StringComparison]::OrdinalIgnoreCase) -ge 0
    })
    $selected = $matchingPaths.Count -gt 0
    if (-not $selected) { continue }
    $matchingPaths | ForEach-Object { $matchedPaths[$_] = $true }
    foreach ($line in @($class.lines.line)) {
        $number = [int]$line.number
        $key = "$file`:$number"
        $hits = [int]$line.hits
        if (-not $records.ContainsKey($key) -or $hits -gt $records[$key]) {
            $records[$key] = $hits
        }
    }
}

if ($RequireEachPath) {
    $missingPaths = @($matchedPaths.Keys | Where-Object { -not $matchedPaths[$_] })
    if ($missingPaths.Count -gt 0) {
        throw "Coverage report has no source entries matching: $($missingPaths -join ', ')"
    }
}
if ($records.Count -lt $MinimumTrackedLines) {
    throw "Coverage report tracked only $($records.Count) matching lines; expected at least $MinimumTrackedLines"
}
$covered = @($records.Values | Where-Object { $_ -gt 0 }).Count
$percent = 100.0 * $covered / $records.Count
Write-Host ('Matched coverage: {0:N2}% ({1}/{2} lines)' -f $percent, $covered, $records.Count)
if ($percent + 0.000001 -lt $MinimumPercent) {
    throw ('Coverage {0:N2}% is below required {1:N2}%' -f $percent, $MinimumPercent)
}
