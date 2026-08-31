# SPDX-License-Identifier: GPL-3.0-only
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$preflightScript = Join-Path $root '.github\scripts\assert-release-assets-empty.ps1'
$global:FFBReleasePreflightMockScenario = ''
$global:FFBReleasePreflightMockCalls = @()

function New-MockReleaseJson {
    param([bool]$Draft, [string[]]$AssetNames)
    return ([pscustomobject]@{
        draft = $Draft
        assets = @($AssetNames | ForEach-Object { [pscustomobject]@{ name = $_ } })
    } | ConvertTo-Json -Depth 4 -Compress)
}

function gh {
    $ghArgs = @($args)
    $global:FFBReleasePreflightMockCalls = @($global:FFBReleasePreflightMockCalls) + ,@($ghArgs)
    $endpoint = [string]$ghArgs[-1]

    if ($endpoint -eq 'repos/owner/repository/releases?per_page=1') {
        if ($global:FFBReleasePreflightMockScenario -eq 'inaccessible') {
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 1
            Write-Output 'HTTP/2.0 404 Not Found'
            Write-Output '{"status":"404"}'
            return
        }
        Set-Variable -Name LASTEXITCODE -Scope 1 -Value 0
        Write-Output 'HTTP/2.0 200 OK'
        Write-Output '0'
        return
    }

    if ($endpoint -ne 'repos/owner/repository/releases/tags/v0.3.0') {
        Set-Variable -Name LASTEXITCODE -Scope 1 -Value 1
        Write-Output 'HTTP/2.0 400 Bad Request'
        return
    }

    switch ($global:FFBReleasePreflightMockScenario) {
        'absent' {
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 1
            Write-Output 'HTTP/2.0 404 Not Found'
            Write-Output '{"status":"404"}'
        }
        'draft-empty' {
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 0
            Write-Output 'HTTP/2.0 200 OK'
            Write-Output (New-MockReleaseJson -Draft $true -AssetNames @())
        }
        'draft-partial' {
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 0
            Write-Output 'HTTP/2.0 200 OK'
            Write-Output (New-MockReleaseJson -Draft $true -AssetNames @(
                'ffb-proxy-x64.zip', 'FFBInterceptor-Launcher-0.3.0.zip'))
        }
        'published-empty' {
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 0
            Write-Output 'HTTP/2.0 200 OK'
            Write-Output (New-MockReleaseJson -Draft $false -AssetNames @())
        }
        'published-partial' {
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 0
            Write-Output 'HTTP/2.0 200 OK'
            Write-Output (New-MockReleaseJson -Draft $false -AssetNames @('ffb-proxy-x64.zip'))
        }
        'unexpected' {
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 0
            Write-Output 'HTTP/2.0 200 OK'
            Write-Output (New-MockReleaseJson -Draft $true -AssetNames @('stale-build.zip'))
        }
        'duplicate' {
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 0
            Write-Output 'HTTP/2.0 200 OK'
            Write-Output (New-MockReleaseJson -Draft $true -AssetNames @(
                'ffb-proxy-x64.zip', 'ffb-proxy-x64.zip'))
        }
        'server-error' {
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 1
            Write-Output 'HTTP/2.0 500 Internal Server Error'
            Write-Output '{"status":"500"}'
        }
        'inaccessible' {
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 1
            Write-Output 'HTTP/2.0 404 Not Found'
            Write-Output '{"status":"404"}'
        }
        'malformed' {
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 0
            Write-Output 'HTTP/2.0 200 OK'
            Write-Output 'not-json'
        }
        'invalid-document' {
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 0
            Write-Output 'HTTP/2.0 200 OK'
            Write-Output '{"draft":"true","assets":[]}'
        }
        'transport-error' {
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 1
            Write-Output 'network unavailable'
        }
        default { throw "Unknown mock scenario: $global:FFBReleasePreflightMockScenario" }
    }
}

function Invoke-PreflightScenario {
    param([Parameter(Mandatory = $true)][string]$Scenario)
    $global:FFBReleasePreflightMockScenario = $Scenario
    $global:FFBReleasePreflightMockCalls = @()
    & $preflightScript -Repository 'owner/repository' -Tag 'v0.3.0'
}

Invoke-PreflightScenario -Scenario 'absent'
if ($global:FFBReleasePreflightMockCalls.Count -ne 2) {
    throw 'release 404 did not require a Releases-API access confirmation request'
}

Invoke-PreflightScenario -Scenario 'draft-empty'
Invoke-PreflightScenario -Scenario 'draft-partial'

foreach ($scenario in @('published-empty', 'published-partial')) {
    $publishedFailure = $null
    try { Invoke-PreflightScenario -Scenario $scenario }
    catch { $publishedFailure = $_.Exception.Message }
    if ($publishedFailure -notmatch 'already published') {
        throw "$scenario release was not rejected before Full recovery"
    }
}

$unexpectedFailure = $null
try { Invoke-PreflightScenario -Scenario 'unexpected' } catch { $unexpectedFailure = $_.Exception.Message }
if ($unexpectedFailure -notmatch 'unexpected Full release asset') {
    throw 'draft with an unexpected asset was not rejected'
}

$duplicateFailure = $null
try { Invoke-PreflightScenario -Scenario 'duplicate' } catch { $duplicateFailure = $_.Exception.Message }
if ($duplicateFailure -notmatch 'duplicate asset name') {
    throw 'draft with duplicate asset names was not rejected'
}

$serverFailure = $null
try { Invoke-PreflightScenario -Scenario 'server-error' } catch { $serverFailure = $_.Exception.Message }
if ($serverFailure -notmatch 'HTTP 500') { throw 'non-404 GitHub API failure was not rejected' }

$accessFailure = $null
try { Invoke-PreflightScenario -Scenario 'inaccessible' } catch { $accessFailure = $_.Exception.Message }
if ($accessFailure -notmatch 'Releases API access could not be confirmed') {
    throw 'ambiguous 404 was incorrectly treated as an absent release'
}

$malformedFailure = $null
try { Invoke-PreflightScenario -Scenario 'malformed' } catch { $malformedFailure = $_.Exception.Message }
if ($malformedFailure -notmatch 'malformed JSON') { throw 'malformed release JSON was not rejected' }

$invalidDocumentFailure = $null
try { Invoke-PreflightScenario -Scenario 'invalid-document' }
catch { $invalidDocumentFailure = $_.Exception.Message }
if ($invalidDocumentFailure -notmatch 'invalid draft document') {
    throw 'release with a non-boolean draft field was not rejected'
}

$transportFailure = $null
try { Invoke-PreflightScenario -Scenario 'transport-error' } catch { $transportFailure = $_.Exception.Message }
if ($transportFailure -notmatch 'no HTTP status') { throw 'transport failure was not rejected' }

Write-Host 'PASS Full release draft-recovery preflight fixtures'
Remove-Variable -Name FFBReleasePreflightMockScenario -Scope Global -ErrorAction SilentlyContinue
Remove-Variable -Name FFBReleasePreflightMockCalls -Scope Global -ErrorAction SilentlyContinue
