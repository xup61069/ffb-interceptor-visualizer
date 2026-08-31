# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [string]$SimHubInstallPath = 'C:\Program Files (x86)\SimHub',
    [string]$FingerprintPath = (Join-Path $PSScriptRoot '..\sdk-compatibility.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$sdkRoot = [IO.Path]::GetFullPath($SimHubInstallPath)
$manifestPath = (Resolve-Path -LiteralPath $FingerprintPath -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath $sdkRoot -PathType Container)) {
    throw "找不到 SimHub SDK 目錄：$sdkRoot"
}
$manifest = Get-Content -Raw -LiteralPath $manifestPath -Encoding UTF8 | ConvertFrom-Json
if ($manifest.schemaVersion -ne 1 -or @($manifest.profiles).Count -eq 0) {
    throw 'SimHub SDK fingerprint manifest schema is invalid.'
}

$observed = @{}
$requiredNames = @($manifest.profiles | ForEach-Object { $_.files } |
    ForEach-Object { [string]$_.name } | Sort-Object -Unique)
foreach ($name in $requiredNames) {
    if ($name -notmatch '^[A-Za-z0-9._-]+\.dll$') { throw "Unsafe SDK file name: $name" }
    $path = Join-Path $sdkRoot $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "缺少 SimHub SDK 檔案：$name" }
    $item = Get-Item -LiteralPath $path
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "SimHub SDK 檔案不可為 reparse point：$name"
    }
    $observed[$name] = [pscustomobject]@{
        length = [long]$item.Length
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
}

foreach ($profile in @($manifest.profiles)) {
    $matches = $true
    foreach ($expected in @($profile.files)) {
        $actual = $observed[[string]$expected.name]
        if ($null -eq $actual -or $actual.length -ne [long]$expected.length -or
            $actual.sha256 -cne ([string]$expected.sha256).ToUpperInvariant()) {
            $matches = $false
            break
        }
    }
    if ($matches -and @($profile.files).Count -eq $requiredNames.Count) {
        Write-Output ([string]$profile.simHubVersion)
        return
    }
}

$summary = @($requiredNames | ForEach-Object {
    "$_=$($observed[$_].sha256)/$($observed[$_].length)"
}) -join '; '
throw "SimHub SDK fingerprint 未列入相容矩陣，拒絕產生可發布外掛。Observed: $summary"
