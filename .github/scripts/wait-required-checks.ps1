# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [string]$Repository = $env:GITHUB_REPOSITORY,
    [string]$CommitSha = $env:GITHUB_SHA,
    [string[]]$RequiredChecks = @(
        'proxy-x64',
        'proxy-x86',
        'simhub-core-net48',
        'coverage-windows',
        'viewer-py3.12',
        'viewer-py3.13',
        'codeql-cpp',
        'codeql-csharp',
        'codeql-python',
        'dependency-audit',
        'history-and-workflow-audit'
    ),
    [ValidateRange(1, 3600)]
    [int]$TimeoutSeconds = 1200,
    [ValidateRange(1, 60)]
    [int]$PollSeconds = 15,
    [string]$CheckRunsFile
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($CommitSha)) {
    $CommitSha = (git rev-parse HEAD).Trim()
}
if ($CommitSha -notmatch '^[0-9a-fA-F]{40}$') {
    throw "CommitSha must be a complete Git SHA; got '$CommitSha'"
}
if (-not $CheckRunsFile -and [string]::IsNullOrWhiteSpace($Repository)) {
    throw 'Repository is required when querying GitHub checks'
}

function Read-CheckRuns {
    if ($CheckRunsFile) {
        return Get-Content -Raw -LiteralPath $CheckRunsFile | ConvertFrom-Json
    }
    $response = gh api --method GET `
        -H 'Accept: application/vnd.github+json' `
        -H 'X-GitHub-Api-Version: 2022-11-28' `
        "repos/$Repository/commits/$CommitSha/check-runs?filter=latest&per_page=100"
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to query required checks for $CommitSha"
    }
    return $response | ConvertFrom-Json
}

$deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
do {
    $document = Read-CheckRuns
    $waiting = @()
    foreach ($name in $RequiredChecks) {
        $latest = @($document.check_runs | Where-Object { $_.name -eq $name } |
            Sort-Object -Property @{ Expression = { [DateTimeOffset]($_.started_at) }; Descending = $true } |
            Select-Object -First 1)
        if ($latest.Count -eq 0 -or $latest[0].status -ne 'completed') {
            $waiting += $name
            continue
        }
        if ($latest[0].conclusion -ne 'success') {
            throw "Required check '$name' concluded '$($latest[0].conclusion)' for $CommitSha"
        }
    }
    if ($waiting.Count -eq 0) {
        Write-Host "Verified $($RequiredChecks.Count) required checks for exact commit $CommitSha"
        return
    }
    if ($CheckRunsFile) {
        throw "Fixture is missing successful required checks: $($waiting -join ', ')"
    }
    if ([DateTimeOffset]::UtcNow -ge $deadline) {
        throw "Timed out waiting for exact-commit checks: $($waiting -join ', ')"
    }
    Write-Host "Waiting for exact-commit checks: $($waiting -join ', ')"
    Start-Sleep -Seconds $PollSeconds
} while ($true)
