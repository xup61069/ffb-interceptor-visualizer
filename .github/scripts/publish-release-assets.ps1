# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AssetsDirectory,
    [Parameter(Mandatory = $true)][string]$Tag,
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$Title,
    [Parameter(Mandatory = $true)][string]$NotesPath,
    [string]$ChannelNotice = 'UNSIGNED EXPERIMENTAL — command telemetry only; not motor torque.',
    [switch]$Prerelease
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($Tag -notmatch '^v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\z') { throw "Invalid release tag: $Tag" }
if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z') { throw "Invalid repository: $Repository" }
$assetsRoot = (Resolve-Path -LiteralPath $AssetsDirectory -ErrorAction Stop).Path
$notesTemplate = Get-Content -Raw -LiteralPath $NotesPath -Encoding UTF8
$assets = @(Get-ChildItem -LiteralPath $assetsRoot -File | Sort-Object Name)
if ($assets.Count -eq 0 -or $assets.Count -gt 64) { throw 'Release must contain between 1 and 64 assets.' }
foreach ($asset in $assets) {
    if ($asset.Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\z' -or $asset.Length -le 0) {
        throw "Unsafe or empty release asset: $($asset.Name)"
    }
}

function Get-ReleaseDocument {
    $endpoint = "repos/$Repository/releases/tags/$Tag"
    $arguments = @(
        'api', '--include', '--jq', '.',
        '-H', 'Accept: application/vnd.github+json',
        '-H', 'X-GitHub-Api-Version: 2022-11-28',
        $endpoint
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
        throw "GitHub release query returned no HTTP status for $Tag."
    }
    $status = [int]$statusCodes[$statusCodes.Count - 1]
    if ($status -eq 404) { return $null }
    if ($exitCode -ne 0 -or $status -ne 200) {
        throw "GitHub release query failed with HTTP $status for $Tag."
    }
    $nonEmpty = @($response | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($nonEmpty.Count -eq 0) {
        throw "GitHub release query returned an empty response for $Tag."
    }
    try {
        return ([string]$nonEmpty[-1] | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        throw "GitHub release query returned malformed JSON for $Tag."
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

$release = Get-ReleaseDocument
$version = $Tag.Substring(1)
$generated = $notesTemplate.Replace('{{TAG}}', $Tag).Replace('{{VERSION}}', $version)
$generated = $generated.Replace('{{CHANNEL_NOTICE}}', $ChannelNotice).Trim()
$startMarker = '<!-- ffb-generated:start -->'
$endMarker = '<!-- ffb-generated:end -->'
$generatedBlock = "$startMarker`n$generated`n$endMarker"
$existingBody = if ($release) { [string]$release.body } else { '' }
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
    if (-not $release) {
        # A new release stays private while its immutable asset set is uploaded
        # and verified. Stable/prerelease metadata is finalized only afterward.
        $arguments = @('release', 'create', $Tag, '--repo', $Repository, '--verify-tag',
            '--draft', '--title', $Title, '--notes-file', $notesFile)
        & gh @arguments
        if ($LASTEXITCODE -ne 0) { throw "Unable to create draft release $Tag." }
        $release = Get-ReleaseDocument
        if (-not $release) { throw "Created draft release $Tag could not be read back." }
    }

    # Verify every already-present asset before mutating release metadata.
    $upload = @(Get-MissingReleaseAssetPaths -ReleaseDocument $release)
    if ($upload.Count -gt 0) {
        gh release upload $Tag $upload --repo $Repository
        if ($LASTEXITCODE -ne 0) { throw "Unable to upload new immutable assets for $Tag." }
    }

    # Do not trust a successful upload exit code alone. Read the release back
    # and verify that its final expected asset set has the exact local content.
    $release = Get-ReleaseDocument
    if (-not $release) { throw "Release $Tag could not be read back after asset upload." }
    $stillMissing = @(Get-MissingReleaseAssetPaths -ReleaseDocument $release)
    if ($stillMissing.Count -ne 0) {
        throw "Release $Tag is still missing $($stillMissing.Count) immutable asset(s) after upload."
    }

    # This is the only metadata-finalization point. For a newly-created draft,
    # --draft=false publishes it only after all immutable assets are verified.
    $prereleaseValue = if ($Prerelease) { 'true' } else { 'false' }
    gh release edit $Tag --repo $Repository --title $Title --notes-file $notesFile `
        "--prerelease=$prereleaseValue" '--draft=false'
    if ($LASTEXITCODE -ne 0) { throw "Unable to finalize release metadata for $Tag." }

    Write-Host "Published $($assets.Count) immutable release asset(s) for $Tag."
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}
