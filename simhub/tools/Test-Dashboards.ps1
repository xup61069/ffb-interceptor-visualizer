# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$knownProperties = @(
    'Connected', 'SourceCount', 'ManualSourceAvailable', 'SelectionMode',
    'SelectedProcessName', 'SelectedProcessId', 'SelectedSessionId',
    'ProxyBuildVersion', 'ProducerBitness', 'CommandLevel', 'CommandPercent',
    'PeakCommandPercent', 'EffectiveCommandPercent', 'EffectGainPercent',
    'DeviceGainPercent', 'AtLimit', 'IsClipping', 'AnyClipping', 'DataReliable', 'ClipRatio1s',
    'ClipPercent1s', 'ClipRatio', 'ClipPercent', 'RatioWindowMilliseconds', 'ClipWindowText',
    'ActiveEffectCount', 'UnsupportedEffectCount',
    'LastEffectKind', 'DroppedFrames', 'ProtocolErrors', 'StatusText',
    'EntryThresholdPercent', 'ExitThresholdPercent', 'ThresholdText', 'Definition'
)

$dashboardDirectory = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Dashboards'))
$definitions = @(Get-ChildItem -LiteralPath $dashboardDirectory -Filter '*.djson' -File)
if ($definitions.Count -ne 2) { throw "Expected exactly two dashboard definitions, found $($definitions.Count)." }

foreach ($definition in $definitions) {
    $raw = Get-Content -LiteralPath $definition.FullName -Raw
    $dashboard = $raw | ConvertFrom-Json
    if ($dashboard.Version -ne 2 -or $dashboard.Screens.Count -ne 1) {
        throw "$($definition.Name): unsupported dashboard structure."
    }
    if ($dashboard.BaseWidth -le 0 -or $dashboard.BaseHeight -le 0) {
        throw "$($definition.Name): invalid dimensions."
    }
    if ($dashboard.IsOverlay -and ($dashboard.BaseWidth * $dashboard.BaseHeight) -gt 480000) {
        throw "$($definition.Name): overlay exceeds SimHub's 800x600 pixel budget."
    }
    if (-not $dashboard.UseStrictJSIsolation) {
        throw "$($definition.Name): strict JS isolation must remain enabled."
    }

    foreach ($item in $dashboard.Screens[0].Items) {
        if ($item.Left -lt 0 -or $item.Top -lt 0 -or $item.Width -le 0 -or $item.Height -le 0 -or
            ($item.Left + $item.Width) -gt ($dashboard.BaseWidth + 0.01) -or
            ($item.Top + $item.Height) -gt ($dashboard.BaseHeight + 0.01)) {
            throw "$($definition.Name): item '$($item.Name)' is outside the canvas."
        }
        if ($item.'$type' -notmatch '^SimHub\.Plugins\.OutputPlugins\.GraphicalDash\.Models\.(RectangleItem|TextItem|LinearGaugeItem), SimHub\.Plugins$') {
            throw "$($definition.Name): item '$($item.Name)' uses an unexpected type."
        }
        if ($item.'$type' -match '\.TextItem,' -and $item.FontSize -lt 11) {
            throw "$($definition.Name): item '$($item.Name)' uses text smaller than 11 px."
        }
    }

    $references = [regex]::Matches($raw, '\[FFBInterceptor\.([A-Za-z0-9]+)\]')
    foreach ($reference in $references) {
        $property = $reference.Groups[1].Value
        if ($property -notin $knownProperties) {
            throw "$($definition.Name): unknown SimHub property FFBInterceptor.$property."
        }
    }
    if ($references.Count -eq 0) { throw "$($definition.Name): no FFB Interceptor bindings found." }
    foreach ($requiredProperty in @('Connected', 'DataReliable', 'EntryThresholdPercent', 'ClipPercent', 'ClipWindowText')) {
        if ($raw -notmatch [regex]::Escape("[FFBInterceptor.$requiredProperty]")) {
            throw "$($definition.Name): required dynamic binding $requiredProperty is missing."
        }
    }
    if (-not $dashboard.IsOverlay -and $raw -notmatch [regex]::Escape('[FFBInterceptor.ThresholdText]')) {
        throw "$($definition.Name): configured enter/exit threshold label is missing."
    }
    if ($raw -notmatch 'HEADROOM' -or $raw -notmatch 'CLIP' -or $raw -notmatch 'NOT (PHYSICAL )?MOTOR TORQUE') {
        throw "$($definition.Name): state text or torque disclaimer is missing."
    }

    $metadataPath = $definition.FullName + '.metadata'
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    if ($metadata.Width -ne $dashboard.BaseWidth -or $metadata.Height -ne $dashboard.BaseHeight -or
        $metadata.IsOverlay -ne $dashboard.IsOverlay) {
        throw "$($definition.Name): metadata dimensions/type do not match."
    }
    Write-Host "PASS $($definition.Name) ($($dashboard.BaseWidth)x$($dashboard.BaseHeight), $($references.Count) bindings)"
}
