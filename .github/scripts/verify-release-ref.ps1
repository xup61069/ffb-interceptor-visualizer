# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [string]$ExpectedCommitSha = '',
    [switch]$RefreshRemote,
    [switch]$RequireMasterHead,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$tag = $env:RELEASE_TAG
if (-not $tag -or $tag -notmatch '^v(?<version>0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\z') {
    throw "RELEASE_TAG must be an existing stable SemVer tag such as v0.1.1; got '$tag'"
}
if ($ExpectedCommitSha -and $ExpectedCommitSha -notmatch '^[0-9a-fA-F]{40}\z') {
    throw "ExpectedCommitSha must be a complete Git SHA; got '$ExpectedCommitSha'"
}

if ($RefreshRemote) {
    git fetch --force --no-tags origin `
        '+refs/heads/master:refs/remotes/origin/master'
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to refresh origin/master before binding the release ref'
    }
    git fetch --force --no-tags origin "+refs/tags/${tag}:refs/tags/${tag}"
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to refresh release tag '$tag' from origin"
    }
}

git show-ref --verify --quiet "refs/tags/$tag"
if ($LASTEXITCODE -ne 0) {
    throw "Release tag '$tag' does not exist in the checkout"
}

$tagCommit = (git rev-list -n 1 $tag).Trim()
$headCommit = (git rev-parse HEAD).Trim()
if ($tagCommit -ne $headCommit) {
    throw "Release checkout mismatch: $tag resolves to $tagCommit, but HEAD is $headCommit"
}

git rev-parse --verify --quiet refs/remotes/origin/master | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'origin/master is unavailable; fetch the complete remote history before releasing'
}
$masterCommit = (git rev-parse refs/remotes/origin/master).Trim()
if ($RequireMasterHead) {
    if ($tagCommit -cne $masterCommit) {
        throw "Release tag '$tag' resolves to $tagCommit, not current origin/master HEAD $masterCommit"
    }
}
else {
    git merge-base --is-ancestor $tagCommit refs/remotes/origin/master
    if ($LASTEXITCODE -ne 0) {
        throw "Release tag '$tag' is not contained in origin/master"
    }
}
if ($ExpectedCommitSha) {
    $expected = $ExpectedCommitSha.ToLowerInvariant()
    if ($tagCommit.ToLowerInvariant() -cne $expected -or
        $headCommit.ToLowerInvariant() -cne $expected -or
        ($RequireMasterHead -and $masterCommit.ToLowerInvariant() -cne $expected)) {
        throw "Release ref moved: expected $expected, tag=$tagCommit, HEAD=$headCommit, master=$masterCommit"
    }
}

$expectedVersion = $tag.Substring(1)
$cmake = Get-Content -Raw -LiteralPath 'CMakeLists.txt'
$pyproject = Get-Content -Raw -LiteralPath 'viewer/pyproject.toml'
$packageInit = Get-Content -Raw -LiteralPath 'viewer/src/ffb_visualizer/__init__.py'
if ($cmake -notmatch "project\(ffb_interceptor VERSION $([regex]::Escape($expectedVersion)) LANGUAGES CXX\)") {
    throw "CMake project version does not match $tag"
}
$viewerVersionPattern = '(?m)^\s*version\s*=\s*"' +
    [regex]::Escape($expectedVersion) + '"\s*\r?$'
if ($pyproject -notmatch $viewerVersionPattern) {
    throw "Viewer package version does not match $tag"
}
$viewerModulePattern = '(?m)^__version__\s*=\s*"' +
    [regex]::Escape($expectedVersion) + '"\s*$'
if ($packageInit -notmatch $viewerModulePattern) {
    throw "Viewer runtime __version__ does not match $tag"
}

$versionedProjects = @(Get-ChildItem -LiteralPath 'simhub' -Filter '*.csproj' -Recurse |
    Where-Object { (Get-Content -Raw -LiteralPath $_.FullName) -match '<Version>[^<]+</Version>' })
if ($versionedProjects.Count -eq 0) {
    throw 'No versioned SimHub C# projects were found'
}
foreach ($project in $versionedProjects) {
    [xml]$projectXml = Get-Content -Raw -LiteralPath $project.FullName
    $versions = @($projectXml.Project.PropertyGroup.Version | Where-Object { $_ })
    if ($versions.Count -ne 1 -or [string]$versions[0] -ne $expectedVersion) {
        throw "C# project version does not match ${tag}: $($project.FullName)"
    }
}

Write-Host "Verified $tag -> $headCommit on origin/master with matching C++, viewer, and C# versions"
if ($PassThru) { Write-Output $tagCommit.ToLowerInvariant() }
