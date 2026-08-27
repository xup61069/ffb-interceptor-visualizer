# SPDX-License-Identifier: GPL-3.0-only
$ErrorActionPreference = 'Stop'

$tag = $env:RELEASE_TAG
if (-not $tag -or $tag -notmatch '^v(?<version>0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') {
    throw "RELEASE_TAG must be an existing stable SemVer tag such as v0.1.1; got '$tag'"
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

$expectedVersion = $tag.Substring(1)
$cmake = Get-Content -Raw -LiteralPath 'CMakeLists.txt'
$pyproject = Get-Content -Raw -LiteralPath 'viewer/pyproject.toml'
if ($cmake -notmatch "project\(ffb_interceptor VERSION $([regex]::Escape($expectedVersion)) LANGUAGES CXX\)") {
    throw "CMake project version does not match $tag"
}
if ($pyproject -notmatch "(?m)^version = `"$([regex]::Escape($expectedVersion))`"$") {
    throw "Viewer package version does not match $tag"
}

Write-Host "Verified $tag -> $headCommit with matching C++ and viewer versions"
