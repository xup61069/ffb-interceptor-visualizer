# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$simHubRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$pluginPath = Join-Path $simHubRoot 'FFBInterceptor.SimHub\FFBInterceptorPlugin.cs'
$modelsPath = Join-Path $simHubRoot 'FFBInterceptor.Core\Models.cs'
$pluginSource = Get-Content -LiteralPath $pluginPath -Raw
$modelsSource = Get-Content -LiteralPath $modelsPath -Raw

$legacyProperties = @(
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

$newProperties = @(
    'SelectionModeText',
    'CombinedCommandLevel', 'CombinedCommandPercent',
    'UnclampedCombinedCommandLevel', 'UnclampedCombinedCommandPercent',
    'CombinedEffectiveCommandLevel', 'CombinedEffectiveCommandPercent',
    'PeakCombinedCommandLevel', 'PeakCombinedCommandPercent',
    'PeakUnclampedCombinedCommandLevel', 'PeakUnclampedCombinedCommandPercent',
    'DetectionLevel', 'DetectionPercent', 'UnobservedTriggerEffectCount',
    'SourceStateDrops', 'DeviceStateDrops', 'EffectStateDrops', 'StateCapacityDrops',
    'ModelLimited', 'ReliabilityIssues', 'ReliabilityIssueMask', 'ReliabilityReason',
    'ReliabilityText', 'TriggerStateUnavailable', 'StateCapacityExceeded',
    'AggregationModel', 'AggregationText'
)

$publishedPropertyMatches = [regex]::Matches(
    $pluginSource,
    'AttachDelegate\("([A-Za-z0-9]+)"')
$publishedProperties = @($publishedPropertyMatches | ForEach-Object { $_.Groups[1].Value })
$duplicateProperties = @($publishedProperties | Group-Object | Where-Object { $_.Count -gt 1 })
if ($duplicateProperties.Count -ne 0) {
    throw "Duplicate SimHub properties: $($duplicateProperties.Name -join ', ')."
}
foreach ($requiredProperty in @($legacyProperties + $newProperties)) {
    if ($requiredProperty -notin $publishedProperties) {
        throw "FFBInterceptorPlugin.cs: required SimHub property $requiredProperty is missing."
    }
}

$snapshotFields = @(
    'CombinedCommandLevel', 'UnclampedCombinedCommandLevel',
    'CombinedEffectiveCommandLevel', 'PeakCombinedCommandLevel',
    'PeakUnclampedCombinedCommandLevel', 'DetectionLevel',
    'UnobservedTriggerEffectCount', 'SourceStateDrops', 'DeviceStateDrops',
    'EffectStateDrops', 'StateCapacityDrops', 'ModelLimited',
    'ReliabilityIssues', 'ReliabilityReason', 'AggregationModel'
)
foreach ($snapshotField in $snapshotFields) {
    $fieldPattern = 'public\s+[A-Za-z0-9_.<>]+\s+' +
        [regex]::Escape($snapshotField) + '\s*\{\s*get;\s*internal\s+set;'
    if ($modelsSource -notmatch $fieldPattern) {
        throw "Models.cs: snapshot field $snapshotField is missing."
    }
    $publishPattern = 'AttachDelegate\("' + [regex]::Escape($snapshotField) +
        '",\s*\(\)\s*=>[^;]*CurrentSnapshot\.' + [regex]::Escape($snapshotField) +
        '\b[^;]*\);'
    if ($pluginSource -notmatch $publishPattern) {
        throw "FFBInterceptorPlugin.cs: snapshot field $snapshotField is not published under the same name."
    }
}

$percentBindings = @{
    # These v0.2 properties intentionally retain their single-effect meaning.
    'CommandPercent' = 'CommandLevel'
    'PeakCommandPercent' = 'PeakCommandLevel'
    'EffectiveCommandPercent' = 'EffectiveCommandLevel'
    'CombinedCommandPercent' = 'CombinedCommandLevel'
    'UnclampedCombinedCommandPercent' = 'UnclampedCombinedCommandLevel'
    'CombinedEffectiveCommandPercent' = 'CombinedEffectiveCommandLevel'
    'PeakCombinedCommandPercent' = 'PeakCombinedCommandLevel'
    'PeakUnclampedCombinedCommandPercent' = 'PeakUnclampedCombinedCommandLevel'
    'DetectionPercent' = 'DetectionLevel'
}
foreach ($binding in $percentBindings.GetEnumerator()) {
    $bindingPattern = 'AttachDelegate\("' + [regex]::Escape($binding.Key) +
        '",\s*\(\)\s*=>\s*CurrentSnapshot\.' + [regex]::Escape($binding.Value) +
        '\s*\*\s*100\.0\)'
    if ($pluginSource -notmatch $bindingPattern) {
        throw "FFBInterceptorPlugin.cs: $($binding.Key) must publish $($binding.Value) as percent."
    }
}
Write-Host "PASS SimHub adapter source contract ($($publishedProperties.Count) properties; SDK not required)"

$knownProperties = $publishedProperties
$dashboardDirectory = Join-Path $simHubRoot 'Dashboards'
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
    foreach ($requiredProperty in @(
        'Connected', 'DataReliable', 'EntryThresholdPercent', 'ClipPercent',
        'ClipWindowText', 'CombinedCommandPercent',
        'UnclampedCombinedCommandPercent', 'ReliabilityText')) {
        if ($raw -notmatch [regex]::Escape("[FFBInterceptor.$requiredProperty]")) {
            throw "$($definition.Name): required dynamic binding $requiredProperty is missing."
        }
    }
    if ($raw -match [regex]::Escape('[FFBInterceptor.CommandPercent]')) {
        throw "$($definition.Name): primary display must use the conservative combined command property."
    }
    if (-not $dashboard.IsOverlay) {
        foreach ($requiredProperty in @(
            'ThresholdText', 'PeakUnclampedCombinedCommandPercent',
            'CombinedEffectiveCommandPercent', 'UnobservedTriggerEffectCount',
            'StateCapacityDrops', 'AggregationText')) {
            if ($raw -notmatch [regex]::Escape("[FFBInterceptor.$requiredProperty]")) {
                throw "$($definition.Name): full dashboard binding $requiredProperty is missing."
            }
        }
    }
    foreach ($requiredLabel in @('同裝置', '保守', '削峰', '非實際馬達扭力')) {
        if ($raw -notmatch [regex]::Escape($requiredLabel)) {
            throw "$($definition.Name): Taiwan Chinese label '$requiredLabel' is missing."
        }
    }
    if ($raw -match 'HEADROOM|DATA GAP|HYSTERESIS|NOT (PHYSICAL )?MOTOR TORQUE') {
        throw "$($definition.Name): legacy English state/definition label remains."
    }

    $metadataPath = $definition.FullName + '.metadata'
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    if ($metadata.Width -ne $dashboard.BaseWidth -or $metadata.Height -ne $dashboard.BaseHeight -or
        $metadata.IsOverlay -ne $dashboard.IsOverlay) {
        throw "$($definition.Name): metadata dimensions/type do not match."
    }
    if ($metadata.Title -ne $dashboard.Metadata.Title -or
        $metadata.Category -ne $dashboard.Metadata.Category -or
        $metadata.Description -ne $dashboard.Metadata.Description -or
        $metadata.DashboardVersion -ne $dashboard.Metadata.DashboardVersion) {
        throw "$($definition.Name): external and embedded metadata do not match."
    }
    if ($metadata.Category -ne '力回饋' -or
        $metadata.Description -notmatch '同裝置.*保守合併' -or
        $metadata.DashboardVersion -ne '1.1.0') {
        throw "$($definition.Name): Taiwan Chinese release metadata is incomplete."
    }
    Write-Host "PASS $($definition.Name) ($($dashboard.BaseWidth)x$($dashboard.BaseHeight), $($references.Count) bindings)"
}
