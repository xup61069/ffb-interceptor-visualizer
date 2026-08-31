# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [string]$Repository = $env:GITHUB_REPOSITORY,
    [string]$Tag = $env:RELEASE_TAG,
    [string[]]$ExpectedAssetNames
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z') {
    throw "Invalid repository: $Repository"
}
if ($Tag -notmatch '^v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\z') {
    throw "Invalid release tag: $Tag"
}

if (-not $ExpectedAssetNames) {
    $version = $Tag.Substring(1)
    $ExpectedAssetNames = @(
        'ffb-proxy-x64.zip',
        'ffb-proxy-x86.zip',
        'ffb-viewer-x64.zip',
        "ffb-interceptor-visualizer-$Tag-source.zip",
        'sbom.cdx.json',
        'sbom.spdx.json',
        'python-environment.cdx.json',
        'python-environment.spdx.json',
        'SHA256SUMS',
        "FFBInterceptor-SimHub-$version.zip",
        "FFBInterceptor-Launcher-$version.zip"
    )
}
$expectedSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($name in $ExpectedAssetNames) {
    if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\z' -or -not $expectedSet.Add($name)) {
        throw "Invalid or duplicate expected Full release asset name: $name"
    }
}

function Invoke-GitHubApiProbe {
    param(
        [Parameter(Mandatory = $true)][string]$Endpoint,
        [Parameter(Mandatory = $true)][string]$Jq
    )

    $arguments = @(
        'api', '--include', '--jq', $Jq,
        '-H', 'Accept: application/vnd.github+json',
        '-H', 'X-GitHub-Api-Version: 2022-11-28',
        $Endpoint
    )
    $response = @(& gh @arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    $statusCodes = [Collections.Generic.List[int]]::new()
    foreach ($line in $response) {
        if ($line -match '^HTTP/\S+\s+(?<status>\d{3})(?:\s|$)') {
            $statusCodes.Add([int]$Matches.status)
        }
    }
    if ($statusCodes.Count -eq 0) {
        throw "GitHub API request returned no HTTP status for $Endpoint."
    }

    $nonEmpty = @($response | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $payload = if ($nonEmpty.Count -gt 0) { [string]$nonEmpty[-1] } else { '' }
    return [pscustomobject]@{
        ExitCode = [int]$exitCode
        Status = [int]$statusCodes[$statusCodes.Count - 1]
        Payload = $payload
    }
}

$releaseEndpoint = "repos/$Repository/releases/tags/$Tag"
$releaseProbe = Invoke-GitHubApiProbe -Endpoint $releaseEndpoint `
    -Jq '{draft: .draft, assets: [.assets[] | {name: .name}]}'
if ($releaseProbe.Status -eq 404) {
    # GitHub also uses 404 for permission failures. A successful request to the
    # Releases collection proves this token can see that API surface before the
    # tag-specific 404 is treated as an empty publication slot.
    $collectionProbe = Invoke-GitHubApiProbe `
        -Endpoint "repos/$Repository/releases?per_page=1" -Jq 'length'
    if ($collectionProbe.ExitCode -ne 0 -or $collectionProbe.Status -ne 200 -or
        $collectionProbe.Payload -notmatch '^\d+$') {
        throw "Release lookup returned 404, but Releases API access could not be confirmed for $Repository."
    }
    Write-Host "No GitHub Release exists for $Tag; Full publication may create a draft."
    return
}
if ($releaseProbe.ExitCode -ne 0 -or $releaseProbe.Status -ne 200) {
    throw "GitHub Release lookup failed with HTTP $($releaseProbe.Status) for $Tag."
}
try { $release = $releaseProbe.Payload | ConvertFrom-Json -ErrorAction Stop }
catch { throw "GitHub Release lookup returned malformed JSON for $Tag." }
$draftProperty = $release.PSObject.Properties['draft']
$assetsProperty = $release.PSObject.Properties['assets']
if (-not $draftProperty -or $draftProperty.Value -isnot [bool] -or -not $assetsProperty) {
    throw "GitHub Release lookup returned an invalid draft document for $Tag."
}
if (-not [bool]$draftProperty.Value) {
    throw "Release $Tag is already published; Full release recovery only accepts a private draft."
}

$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($asset in @($assetsProperty.Value)) {
    $nameProperty = $asset.PSObject.Properties['name']
    $name = if ($nameProperty) { [string]$nameProperty.Value } else { '' }
    if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\z') {
        throw "Release $Tag draft contains an invalid asset name."
    }
    if (-not $seen.Add($name)) {
        throw "Release $Tag draft contains a duplicate asset name: $name"
    }
    if (-not $expectedSet.Contains($name)) {
        throw "Release $Tag draft contains an unexpected Full release asset: $name"
    }
}

Write-Host "Release $Tag is a private draft with $($seen.Count) expected partial asset(s); recovery may continue."
