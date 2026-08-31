# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [string]$Repository = $env:GITHUB_REPOSITORY,
    [string]$Tag = $env:RELEASE_TAG,
    [string[]]$ExpectedAssetNames,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'release-api.ps1')

if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z') {
    throw "Invalid repository: $Repository"
}
if ($Tag -cnotmatch '^v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\z') {
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

$release = Get-FFBUniqueReleaseByTag -Repository $Repository -Tag $Tag
if (-not $release) {
    Write-Host "No GitHub Release exists for $Tag; Full publication may create a draft."
    if ($PassThru) {
        Write-Output ([pscustomobject]@{
            ReleaseId = [long]0
            RecoveryDraft = $false
        })
    }
    return
}
if (-not [bool]$release.draft) {
    throw "Release $Tag is already published; Full release recovery only accepts a private draft."
}
if ([bool]$release.immutable) {
    throw "Release $Tag is immutable; Full release recovery only accepts a mutable private draft."
}

$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($asset in @($release.assets)) {
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

Write-Host "Release $Tag is mutable private draft $([long]$release.id) with $($seen.Count) expected partial asset(s); recovery may continue."
if ($PassThru) {
    Write-Output ([pscustomobject]@{
        ReleaseId = [long]$release.id
        RecoveryDraft = $true
    })
}
