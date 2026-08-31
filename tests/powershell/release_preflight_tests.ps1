# SPDX-License-Identifier: GPL-3.0-only
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$preflightScript = Join-Path $root '.github\scripts\assert-release-assets-empty.ps1'
$global:FFBReleasePreflightMockScenario = ''
$global:FFBReleasePreflightMockCalls = @()

function New-MockRelease {
    param(
        [long]$Id,
        [string]$Tag = 'v0.3.0',
        [bool]$Draft = $true,
        [bool]$Immutable = $false,
        [string[]]$AssetNames = @()
    )
    return [pscustomobject]@{
        id = $Id
        tag_name = $Tag
        name = "$Tag fixture"
        body = 'fixture body'
        draft = $Draft
        prerelease = $true
        immutable = $Immutable
        assets = @($AssetNames | ForEach-Object { [pscustomobject]@{ name = $_ } })
    }
}

function ConvertTo-MockSlurpedPages {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Pages
    )
    $pageList = [Collections.Generic.List[object]]::new()
    foreach ($page in $Pages) { $pageList.Add($page) }
    return (ConvertTo-Json -InputObject $pageList -Depth 8 -Compress)
}

function gh {
    $ghArgs = @($args)
    $global:FFBReleasePreflightMockCalls =
        @($global:FFBReleasePreflightMockCalls) + ,@($ghArgs)
    if ($ghArgs.Count -lt 2 -or $ghArgs[0] -cne 'api' -or
        $ghArgs[-1] -cne 'repos/owner/repository/releases?per_page=100' -or
        $ghArgs -cnotcontains '--paginate' -or
        $ghArgs -cnotcontains '--slurp' -or
        $ghArgs -ccontains '--jq') {
        Set-Variable -Name LASTEXITCODE -Scope 1 -Value 2
        Write-Output 'invalid paginated releases-list contract'
        return
    }

    # Keep each page as one list element.  PowerShell otherwise recursively
    # unrolls @([object[]]@()) into an empty outer collection and flattens
    # multiple page arrays at the pipeline/parameter boundary.
    $pages = [Collections.Generic.List[object]]::new()
    switch ($global:FFBReleasePreflightMockScenario) {
        'absent' {
            $pages.Add([object[]]@())
        }
        'draft-page2' {
            $firstPage = [Collections.Generic.List[object]]::new()
            for ($index = 0; $index -lt 100; $index++) {
                $firstPage.Add((New-MockRelease -Id (1000 + $index) `
                    -Tag "v1.0.$index" -Draft $false -Immutable $true))
            }
            # A differently-cased tag must not shadow the exact page-two tag.
            $firstPage[0] = New-MockRelease -Id 999 -Tag 'V0.3.0' `
                -Draft $false -Immutable $true
            $pages.Add([object[]]$firstPage)
            $pages.Add([object[]]@((New-MockRelease -Id 379831902 -AssetNames @(
                'ffb-proxy-x64.zip',
                'FFBInterceptor-Launcher-0.3.0.zip'))))
        }
        'duplicate' {
            $pages.Add([object[]]@((New-MockRelease -Id 379831902)))
            $pages.Add([object[]]@((New-MockRelease -Id 379831903)))
        }
        'published' {
            $pages.Add([object[]]@((New-MockRelease -Id 379831902 `
                -Draft $false -Immutable $true)))
        }
        'immutable-draft' {
            $pages.Add([object[]]@((New-MockRelease -Id 379831902 `
                -Draft $true -Immutable $true)))
        }
        'unexpected' {
            $pages.Add([object[]]@((New-MockRelease -Id 379831902 `
                -AssetNames @('stale-build.zip'))))
        }
        'duplicate-asset' {
            $pages.Add([object[]]@((New-MockRelease -Id 379831902 `
                -AssetNames @('ffb-proxy-x64.zip', 'ffb-proxy-x64.zip'))))
        }
        'invalid-document' {
            $pages.Add([object[]]@([pscustomobject]@{
                id = 0
                tag_name = 'v0.3.0'
                draft = $true
                prerelease = $true
                immutable = $false
                assets = @()
            }))
        }
        'invalid-assets' {
            $pages.Add([object[]]@([pscustomobject]@{
                id = 379831902
                tag_name = 'v0.3.0'
                draft = $true
                prerelease = $true
                immutable = $false
                assets = [pscustomobject]@{ name = 'ffb-proxy-x64.zip' }
            }))
        }
        'non-array-outer' {
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 0
            Write-Output '{}'
            return
        }
        'non-array-page' {
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 0
            Write-Output '[{}]'
            return
        }
        'malformed' {
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 0
            Write-Output '{'
            return
        }
        'api-failure' {
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 1
            Write-Output 'GitHub API unavailable'
            return
        }
        default {
            throw "Unknown mock scenario: $global:FFBReleasePreflightMockScenario"
        }
    }

    Set-Variable -Name LASTEXITCODE -Scope 1 -Value 0
    Write-Output (ConvertTo-MockSlurpedPages -Pages $pages)
}

function Invoke-PreflightScenario {
    param([Parameter(Mandatory = $true)][string]$Scenario)
    $global:FFBReleasePreflightMockScenario = $Scenario
    $global:FFBReleasePreflightMockCalls = @()
    return (& $preflightScript -Repository 'owner/repository' -Tag 'v0.3.0' `
        -ExpectedAssetNames @(
            'ffb-proxy-x64.zip',
            'FFBInterceptor-Launcher-0.3.0.zip') -PassThru)
}

function Assert-ScenarioFails {
    param([string]$Scenario, [string]$Pattern)
    $failure = $null
    try { Invoke-PreflightScenario -Scenario $Scenario | Out-Null }
    catch { $failure = $_.Exception.Message }
    if ($failure -notmatch $Pattern) {
        throw "$Scenario did not fail with expected pattern '$Pattern': $failure"
    }
}

$absent = Invoke-PreflightScenario -Scenario 'absent'
if ([long]$absent.ReleaseId -ne 0 -or [bool]$absent.RecoveryDraft) {
    throw 'absent preflight did not return the empty publication slot contract'
}

$draft = Invoke-PreflightScenario -Scenario 'draft-page2'
if ([long]$draft.ReleaseId -ne 379831902 -or -not [bool]$draft.RecoveryDraft) {
    throw 'page-two draft was not returned as the pinned recovery release'
}
$lookup = @($global:FFBReleasePreflightMockCalls)[0]
if ($lookup -cnotcontains '--paginate' -or $lookup -cnotcontains '--slurp' -or
    $lookup -ccontains '--jq' -or
    $lookup[-1] -cne 'repos/owner/repository/releases?per_page=100') {
    throw 'preflight did not use the gh 2.96-compatible paginated list contract'
}

Assert-ScenarioFails -Scenario 'duplicate' -Pattern 'multiple releases for exact tag'
Assert-ScenarioFails -Scenario 'published' -Pattern 'already published'
Assert-ScenarioFails -Scenario 'immutable-draft' -Pattern 'both draft and immutable'
Assert-ScenarioFails -Scenario 'unexpected' -Pattern 'unexpected Full release asset'
Assert-ScenarioFails -Scenario 'duplicate-asset' -Pattern 'duplicate asset name'
Assert-ScenarioFails -Scenario 'invalid-document' -Pattern 'invalid release ID'
Assert-ScenarioFails -Scenario 'invalid-assets' -Pattern 'invalid assets field'
Assert-ScenarioFails -Scenario 'non-array-outer' -Pattern 'outer page array'
Assert-ScenarioFails -Scenario 'non-array-page' -Pattern 'non-array page'
Assert-ScenarioFails -Scenario 'malformed' -Pattern 'malformed JSON'
Assert-ScenarioFails -Scenario 'api-failure' -Pattern 'list query failed'

$uppercaseTagFailure = $null
try {
    & $preflightScript -Repository 'owner/repository' -Tag 'V0.3.0' `
        -ExpectedAssetNames @('ffb-proxy-x64.zip') | Out-Null
}
catch { $uppercaseTagFailure = $_.Exception.Message }
if ($uppercaseTagFailure -notmatch 'Invalid release tag') {
    throw 'non-canonical uppercase release tag was accepted'
}

Write-Host 'PASS Full release paginated draft-recovery preflight fixtures'
Remove-Variable -Name FFBReleasePreflightMockScenario -Scope Global -ErrorAction SilentlyContinue
Remove-Variable -Name FFBReleasePreflightMockCalls -Scope Global -ErrorAction SilentlyContinue
