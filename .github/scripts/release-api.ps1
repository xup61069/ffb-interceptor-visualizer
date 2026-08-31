# SPDX-License-Identifier: GPL-3.0-only
Set-StrictMode -Version Latest

function Get-FFBUniqueReleaseByTag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$Tag,
        [long]$ExpectedId = 0
    )

    if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z') {
        throw "Invalid repository: $Repository"
    }
    if ($Tag -cnotmatch '^v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\z') {
        throw "Invalid release tag: $Tag"
    }
    if ($ExpectedId -lt 0) { throw 'Expected release ID cannot be negative.' }

    $arguments = @(
        'api', '--paginate', '--slurp',
        '-H', 'Accept: application/vnd.github+json',
        '-H', 'X-GitHub-Api-Version: 2026-03-10',
        "repos/$Repository/releases?per_page=100"
    )
    $response = @(& gh @arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "GitHub releases list query failed for $Tag (exit $exitCode)."
    }
    if ($response.Count -eq 0) {
        throw "GitHub releases list query returned an empty response for $Tag."
    }

    $json = [string]::Join("`n", $response)
    # Wrapping the slurped pages in an object prevents Windows PowerShell 5.1
    # and PowerShell 7 from unrolling nested arrays differently at the pipeline
    # boundary.  The response must be an outer array containing page arrays.
    try { $parsed = ('{"pages":' + $json + '}') | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "GitHub releases list query returned malformed JSON for $Tag." }
    $pagesProperty = $parsed.PSObject.Properties['pages']
    if (-not $pagesProperty -or $pagesProperty.Value -isnot [System.Array]) {
        throw 'GitHub releases list query did not return an outer page array.'
    }

    $documents = [Collections.Generic.List[object]]::new()
    foreach ($page in $pagesProperty.Value) {
        if ($page -isnot [System.Array]) {
            throw 'GitHub releases list query contained a non-array page.'
        }
        foreach ($document in $page) { $documents.Add($document) }
    }

    $matches = [Collections.Generic.List[object]]::new()
    foreach ($document in $documents) {
        if ($null -eq $document) {
            throw 'GitHub releases list contained a null release document.'
        }
        $tagProperty = $document.PSObject.Properties['tag_name']
        if (-not $tagProperty -or $tagProperty.Value -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$tagProperty.Value)) {
            throw 'GitHub releases list contained a release without a valid tag_name.'
        }
        if ([string]$tagProperty.Value -ceq $Tag) { $matches.Add($document) }
    }

    if ($matches.Count -gt 1) {
        throw "GitHub releases list contains multiple releases for exact tag $Tag."
    }
    if ($matches.Count -eq 0) {
        if ($ExpectedId -gt 0) {
            throw "Pinned release $ExpectedId for $Tag disappeared from the GitHub releases list."
        }
        return $null
    }

    $release = $matches[0]
    $idProperty = $release.PSObject.Properties['id']
    $releaseId = [long]0
    if (-not $idProperty -or
        -not [long]::TryParse([string]$idProperty.Value, [ref]$releaseId) -or
        $releaseId -le 0) {
        throw "GitHub release $Tag has an invalid release ID."
    }
    foreach ($booleanName in @('draft', 'prerelease', 'immutable')) {
        $property = $release.PSObject.Properties[$booleanName]
        if (-not $property -or $property.Value -isnot [bool]) {
            throw "GitHub release $Tag has an invalid $booleanName field."
        }
    }
    if (-not $release.PSObject.Properties['assets'] -or
        $release.PSObject.Properties['assets'].Value -isnot [System.Array]) {
        throw "GitHub release $Tag has an invalid assets field."
    }
    if ([bool]$release.draft -and [bool]$release.immutable) {
        throw "GitHub release $Tag is both draft and immutable; refusing an inconsistent state."
    }
    if ($ExpectedId -gt 0 -and $releaseId -ne $ExpectedId) {
        throw "Pinned release ID changed for ${Tag}: expected $ExpectedId, got $releaseId."
    }

    return $release
}

function Assert-FFBMutableReleaseDraft {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$ReleaseDocument,
        [Parameter(Mandatory = $true)][string]$Tag
    )

    if (-not [bool]$ReleaseDocument.draft) {
        throw "Release $Tag is already published; refusing to mutate public release state."
    }
    if ([bool]$ReleaseDocument.immutable) {
        throw "Release $Tag is immutable; refusing to mutate release state."
    }
}
