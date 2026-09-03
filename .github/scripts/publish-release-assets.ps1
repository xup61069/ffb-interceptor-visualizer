# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AssetsDirectory,
    [Parameter(Mandatory = $true)][string]$Tag,
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string[]]$ExpectedAssetNames,
    [Parameter(Mandatory = $true)][string]$Title,
    [Parameter(Mandatory = $true)][string]$NotesPath,
    [string]$ChannelNotice = 'UNSIGNED EXPERIMENTAL - command telemetry only; not motor torque.',
    [long]$ExpectedReleaseId = 0,
    [switch]$Prerelease
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$releaseExpectationBound = $PSBoundParameters.ContainsKey('ExpectedReleaseId')
if ($Tag -cnotmatch '^v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\z') { throw "Invalid release tag: $Tag" }
if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z') { throw "Invalid repository: $Repository" }
if ($ExpectedReleaseId -lt 0) { throw 'ExpectedReleaseId cannot be negative.' }
. (Join-Path $PSScriptRoot 'release-api.ps1')
$assetsRoot = (Resolve-Path -LiteralPath $AssetsDirectory -ErrorAction Stop).Path
$notesTemplate = Get-Content -Raw -LiteralPath $NotesPath -Encoding UTF8
$assets = @(Get-ChildItem -LiteralPath $assetsRoot -Force | Sort-Object Name)
if ($assets.Count -eq 0 -or $assets.Count -gt 64) { throw 'Release must contain between 1 and 64 assets.' }
foreach ($asset in $assets) {
    if ($asset.PSIsContainer -or $asset -isnot [IO.FileInfo] -or
        ($asset.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $asset.Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\z' -or $asset.Length -le 0) {
        throw "Unsafe or empty release asset: $($asset.Name)"
    }
}
$expectedAssetSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($expectedAssetName in $ExpectedAssetNames) {
    if ($expectedAssetName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\z' -or
        -not $expectedAssetSet.Add($expectedAssetName)) {
        throw "Invalid or duplicate expected release asset name: $expectedAssetName"
    }
}
if ($expectedAssetSet.Count -ne $assets.Count) {
    throw "Local release asset count does not match the expected set ($($assets.Count) != $($expectedAssetSet.Count))."
}
foreach ($asset in $assets) {
    if (-not $expectedAssetSet.Contains($asset.Name)) {
        throw "Local release contains an unexpected asset: $($asset.Name)"
    }
}

function Get-MissingReleaseAssetPaths {
    param([Parameter(Mandatory = $true)]$ReleaseDocument)

    $remoteAssets = @($ReleaseDocument.assets)
    $duplicateNames = @($remoteAssets | Group-Object -Property name | Where-Object { $_.Count -ne 1 })
    if ($duplicateNames.Count -gt 0) { throw 'Release contains duplicate asset names.' }
    $expectedNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($asset in $assets) { [void]$expectedNames.Add($asset.Name) }
    $unexpected = @($remoteAssets | Where-Object { -not $expectedNames.Contains([string]$_.name) })
    if ($unexpected.Count -gt 0) {
        throw "Release contains an unexpected immutable asset: $($unexpected[0].name)"
    }

    $missing = [Collections.Generic.List[string]]::new()
    foreach ($asset in $assets) {
        $remote = @($remoteAssets | Where-Object { $_.name -ceq $asset.Name })
        if ($remote.Count -eq 0) {
            $missing.Add($asset.FullName)
            continue
        }
        if ([long]$remote[0].size -ne $asset.Length) {
            throw "Immutable release asset differs in size: $($asset.Name)"
        }
        $localHash = (Get-FileHash -LiteralPath $asset.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $digestProperty = $remote[0].PSObject.Properties['digest']
        $remoteDigest = if ($digestProperty) { [string]$digestProperty.Value } else { '' }
        if ($remoteDigest -match '^sha256:([a-fA-F0-9]{64})$') {
            if ($localHash -cne $Matches[1].ToLowerInvariant()) {
                throw "Immutable release asset differs in digest: $($asset.Name)"
            }
            continue
        }
        $downloadRoot = Join-Path $temporaryRoot ('asset-' + [Guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($downloadRoot) | Out-Null
        gh release download $Tag --repo $Repository --pattern $asset.Name --dir $downloadRoot | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Unable to verify existing release asset: $($asset.Name)" }
        $downloaded = Join-Path $downloadRoot $asset.Name
        if (-not (Test-Path -LiteralPath $downloaded -PathType Leaf) -or
            (Get-FileHash -LiteralPath $downloaded -Algorithm SHA256).Hash.ToLowerInvariant() -cne $localHash) {
            throw "Immutable release asset differs in content: $($asset.Name)"
        }
    }
    return @($missing)
}

$release = if ($releaseExpectationBound -and $ExpectedReleaseId -gt 0) {
    Get-FFBUniqueReleaseByTag -Repository $Repository -Tag $Tag `
        -ExpectedId $ExpectedReleaseId
}
else {
    Get-FFBUniqueReleaseByTag -Repository $Repository -Tag $Tag
}
if ($releaseExpectationBound -and $ExpectedReleaseId -gt 0) {
    # A positive expectation can only originate from preflight recovery of a
    # mutable private draft.  Do not silently turn a concurrently-published
    # release into an idempotent success merely because its ID stayed stable.
    Assert-FFBMutableReleaseDraft -ReleaseDocument $release -Tag $Tag
}
if ($releaseExpectationBound -and $ExpectedReleaseId -eq 0 -and $release) {
    throw "Release $Tag appeared after preflight reported an empty publication slot."
}
$releaseId = if ($release) { [long]$release.id } else { [long]0 }
$version = $Tag.Substring(1)
$generated = $notesTemplate.Replace('{{TAG}}', $Tag).Replace('{{VERSION}}', $version)
$generated = $generated.Replace('{{CHANNEL_NOTICE}}', $ChannelNotice).Trim()
$startMarker = '<!-- ffb-generated:start -->'
$endMarker = '<!-- ffb-generated:end -->'
$generatedBlock = "$startMarker`n$generated`n$endMarker"
$existingBody = if ($release) { [string]$release.body } else { '' }
$desiredPrerelease = [bool]$Prerelease
$markerPattern = [regex]::Escape($startMarker) + '(?s:.*?)' + [regex]::Escape($endMarker)
$markerRegex = [regex]::new($markerPattern)
$markerMatches = @($markerRegex.Matches($existingBody))
if ($markerMatches.Count -gt 1) { throw 'Existing release body has duplicate generated-note markers.' }
if ($markerMatches.Count -eq 1) {
    $releaseBody = $markerRegex.Replace($existingBody,
        [Text.RegularExpressions.MatchEvaluator]{ param($match) $generatedBlock }, 1)
} elseif ([string]::IsNullOrWhiteSpace($existingBody)) {
    $releaseBody = $generatedBlock
} else {
    $releaseBody = $existingBody.TrimEnd() + "`n`n" + $generatedBlock
}

$temporarySource = $env:RUNNER_TEMP
if ([string]::IsNullOrWhiteSpace($temporarySource)) { $temporarySource = [IO.Path]::GetTempPath() }
$temporaryRoot = [IO.Path]::GetFullPath((Join-Path $temporarySource ('ffb-release-' + [Guid]::NewGuid().ToString('N'))))
$temporaryParent = [IO.Path]::GetFullPath($temporarySource).TrimEnd('\') + '\'
if (-not $temporaryRoot.StartsWith($temporaryParent, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Unsafe release temporary directory.'
}
[IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
try {
    $notesFile = Join-Path $temporaryRoot 'notes.md'
    [IO.File]::WriteAllText($notesFile, $releaseBody, [Text.UTF8Encoding]::new($false))
    if ($release -and -not [bool]$release.draft) {
        if (-not [bool]$release.immutable) {
            throw "Published release $Tag is not immutable; refusing to trust or mutate it."
        }
        $alreadyMissing = @(Get-MissingReleaseAssetPaths -ReleaseDocument $release)
        if ($alreadyMissing.Count -ne 0 -or
            [string]$release.name -cne $Title -or
            [string]$release.body -cne $releaseBody -or
            [bool]$release.prerelease -ne $desiredPrerelease) {
            throw "Published immutable release $Tag does not exactly match the requested release."
        }
        Write-Host "Release $Tag is already published with the exact immutable state."
        return
    }
    if (-not $release) {
        # A new release stays private while its immutable asset set is uploaded
        # and verified. Stable/prerelease metadata is finalized only afterward.
        $arguments = @('release', 'create', $Tag, '--repo', $Repository, '--verify-tag',
            '--draft', '--title', $Title, '--notes-file', $notesFile)
        & gh @arguments
        if ($LASTEXITCODE -ne 0) { throw "Unable to create draft release $Tag." }
        $release = Get-FFBUniqueReleaseByTag -Repository $Repository -Tag $Tag
        if (-not $release) { throw "Created draft release $Tag could not be read back." }
        $releaseId = [long]$release.id
    }

    $release = Get-FFBUniqueReleaseByTag -Repository $Repository -Tag $Tag `
        -ExpectedId $releaseId
    Assert-FFBMutableReleaseDraft -ReleaseDocument $release -Tag $Tag

    # Verify every already-present asset before mutating release metadata.
    $upload = @(Get-MissingReleaseAssetPaths -ReleaseDocument $release)
    if ($upload.Count -gt 0) {
        if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
            throw 'GH_TOKEN is required for numeric-ID release asset upload.'
        }
        foreach ($uploadPath in $upload) {
            $uploadAsset = Get-Item -LiteralPath $uploadPath -ErrorAction Stop
            $escapedName = [Uri]::EscapeDataString($uploadAsset.Name)
            $uploadUri = "https://uploads.github.com/repos/$Repository/releases/$releaseId/assets?name=$escapedName"
            $uploadArguments = @(
                'api', '--method', 'POST',
                '-H', 'Accept: application/vnd.github+json',
                '-H', 'X-GitHub-Api-Version: 2026-03-10',
                '-H', 'Content-Type: application/octet-stream',
                '--input', $uploadAsset.FullName,
                '--silent', $uploadUri
            )
            & gh @uploadArguments
            if ($LASTEXITCODE -ne 0) {
                throw "Unable to upload new immutable asset $($uploadAsset.Name) for $Tag."
            }
        }
    }

    # Do not trust a successful upload exit code alone. Read the release back
    # and verify that its final expected asset set has the exact local content.
    $release = Get-FFBUniqueReleaseByTag -Repository $Repository -Tag $Tag `
        -ExpectedId $releaseId
    Assert-FFBMutableReleaseDraft -ReleaseDocument $release -Tag $Tag
    $stillMissing = @(Get-MissingReleaseAssetPaths -ReleaseDocument $release)
    if ($stillMissing.Count -ne 0) {
        throw "Release $Tag is still missing $($stillMissing.Count) immutable asset(s) after upload."
    }

    # This is the only metadata-finalization point. Address the release by its
    # pinned numeric ID so a delete/recreate race on the tag cannot publish a
    # different release. The request body stays in the guarded temp directory.
    $finalizeRequestPath = Join-Path $temporaryRoot 'finalize-release.json'
    $finalizeRequest = [ordered]@{
        tag_name = $Tag
        name = $Title
        body = $releaseBody
        draft = $false
        prerelease = $desiredPrerelease
    }
    [IO.File]::WriteAllText($finalizeRequestPath,
        ($finalizeRequest | ConvertTo-Json -Compress),
        [Text.UTF8Encoding]::new($false))
    $finalizeArguments = @(
        'api', '--method', 'PATCH',
        '-H', 'Accept: application/vnd.github+json',
        '-H', 'X-GitHub-Api-Version: 2026-03-10',
        '--input', $finalizeRequestPath,
        "repos/$Repository/releases/$releaseId"
    )
    & gh @finalizeArguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to finalize release metadata for $Tag." }

    # GitHub does not promise that the immutable flag is visible in the first
    # read after publication.  Retry only the readback; never mutate a public
    # release again.  Any other state mismatch fails immediately.
    $release = $null
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        $release = Get-FFBUniqueReleaseByTag -Repository $Repository -Tag $Tag `
            -ExpectedId $releaseId
        if ([bool]$release.draft -or
            [bool]$release.prerelease -ne $desiredPrerelease -or
            [string]$release.name -cne $Title -or [string]$release.body -cne $releaseBody) {
            throw "Final release state for $Tag did not match the verified publication request."
        }
        if ([bool]$release.immutable) { break }
        if ($attempt -lt 6) { Start-Sleep -Seconds 2 }
    }
    if (-not [bool]$release.immutable) {
        throw "Final release state for $Tag did not become immutable after publication."
    }
    $finalMissing = @(Get-MissingReleaseAssetPaths -ReleaseDocument $release)
    if ($finalMissing.Count -ne 0) {
        throw "Final release state for $Tag is missing $($finalMissing.Count) immutable asset(s)."
    }

    Write-Host "Published $($assets.Count) immutable release asset(s) for $Tag."
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}
