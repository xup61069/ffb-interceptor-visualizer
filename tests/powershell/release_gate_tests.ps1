# SPDX-License-Identifier: GPL-3.0-only
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$script = Join-Path $root '.github\scripts\wait-required-checks.ps1'
$sha = '0123456789abcdef0123456789abcdef01234567'

& $script -CommitSha $sha -RequiredChecks @('proxy-x64', 'codeql-cpp') `
    -CheckRunsFile (Join-Path $root 'tests\fixtures\check-runs-success.json')

$failed = $false
try {
    & $script -CommitSha $sha -RequiredChecks @('proxy-x64') `
        -CheckRunsFile (Join-Path $root 'tests\fixtures\check-runs-failure.json')
}
catch {
    $failed = $_.Exception.Message -match "concluded 'failure'"
}
if (-not $failed) { throw 'failure fixture was not rejected' }

$coverageScript = Join-Path $root '.github\scripts\assert-cobertura-coverage.ps1'
$coverageFixture = Join-Path $root 'tests\fixtures\cobertura-sample.xml'
& $coverageScript -Report $coverageFixture -PathContains '/src/' `
    -MinimumPercent 75 -MinimumTrackedLines 4
$coverageFailed = $false
try {
    & $coverageScript -Report $coverageFixture -PathContains '/src/' `
        -MinimumPercent 76 -MinimumTrackedLines 4
}
catch {
    $coverageFailed = $_.Exception.Message -match 'below required'
}
if (-not $coverageFailed) { throw 'coverage threshold failure was not enforced' }
$missingPathFailed = $false
try {
    & $coverageScript -Report $coverageFixture -PathContains @('/src/', '/launcher/') `
        -MinimumPercent 1 -MinimumTrackedLines 4 -RequireEachPath
}
catch {
    $missingPathFailed = $_.Exception.Message -match 'no source entries'
}
if (-not $missingPathFailed) { throw 'missing coverage path was not rejected' }

$signScript = Join-Path $root '.github\scripts\sign-windows-artifacts.ps1'
$unsignedFixture = Join-Path $root 'tests\fixtures\check-runs-success.json'
& $signScript -Paths @($unsignedFixture) -CertificateThumbprint ''
$signingRequiredFailed = $false
try { & $signScript -Paths @($unsignedFixture) -CertificateThumbprint '' -RequireSigning }
catch { $signingRequiredFailed = $_.Exception.Message -match 'signing is required' }
if (-not $signingRequiredFailed) { throw 'required signing did not fail closed' }

$importScript = Join-Path $root '.github\scripts\import-signing-certificate.ps1'
$missingPfxFailed = $false
try { & $importScript -PfxBase64 '' -PfxPassword '' -RequireSigning }
catch { $missingPfxFailed = $_.Exception.Message -match 'requires the PFX' }
if (-not $missingPfxFailed) { throw 'stable certificate import did not fail closed' }
$missingPfxPasswordFailed = $false
try {
    & $importScript -PfxBase64 'QQ==' -PfxPassword '' `
        -ExpectedSignerSha256 ('A' * 64) -RequireSigning
}
catch { $missingPfxPasswordFailed = $_.Exception.Message -match 'PFX password secret' }
if (-not $missingPfxPasswordFailed) { throw 'stable certificate import accepted an empty PFX password' }
$missingPinFailed = $false
try {
    & $importScript -PfxBase64 'QQ==' -PfxPassword 'fixture-password' `
        -ExpectedSignerSha256 '' -RequireSigning
}
catch { $missingPinFailed = $_.Exception.Message -match 'uppercase signer SHA-256 pin' }
if (-not $missingPinFailed) { throw 'stable certificate import accepted a missing signer pin' }
$lowercasePinFailed = $false
try {
    & $importScript -PfxBase64 'QQ==' -PfxPassword 'fixture-password' `
        -ExpectedSignerSha256 ('a' * 64) -RequireSigning
}
catch { $lowercasePinFailed = $_.Exception.Message -match 'uppercase signer SHA-256 pin' }
if (-not $lowercasePinFailed) { throw 'stable certificate import accepted a non-canonical signer pin' }
$importSource = Get-Content -Raw -LiteralPath $importScript
if ($importSource -notmatch 'X509Certificate2Collection' -or
    $importSource -notmatch 'EphemeralKeySet' -or
    $importSource -notmatch '\$privateKeyIdentities\.Count\s+-ne\s+1' -or
    $importSource -notmatch 'foreach\s*\(\$certificate\s+in\s+\$pfxCertificates\)' -or
    $importSource -notmatch '\$trackedThumbprints\.Add\(\$thumbprint\)' -or
    $importSource -notmatch 'Refusing to reuse a certificate already present' -or
    $importSource -notmatch 'FFB_SIGNING_CERT_THUMBPRINTS' -or
    $importSource -notmatch 'Remove-Item[^\r\n]+-DeleteKey') {
    throw 'Stable PFX import is missing ephemeral all-certificate validation or cleanup'
}
$invalidPfxFailed = $false
try { & $importScript -PfxBase64 'not-base64' -PfxPassword '' }
catch { $invalidPfxFailed = $_.Exception.Message -match 'not valid base64' }
if (-not $invalidPfxFailed) { throw 'invalid signing PFX was not rejected' }

$baseWorkflow = Get-Content -Raw -LiteralPath (Join-Path $root '.github\workflows\release.yml')
$fullWorkflow = Get-Content -Raw -LiteralPath (Join-Path $root '.github\workflows\simhub-sdk-release.yml')
if ($baseWorkflow -notmatch 'types:\s*\[ffb-experimental-base-release\]' -or
    $fullWorkflow -notmatch 'types:\s*\[ffb-full-release\]' -or
    $baseWorkflow -match 'workflow_dispatch' -or $fullWorkflow -match 'workflow_dispatch') {
    throw 'release workflows are not exclusively repository_dispatch entrypoints'
}
foreach ($workflowSource in @($baseWorkflow, $fullWorkflow)) {
    if ($workflowSource -notmatch "github\.event_name == 'repository_dispatch'\s+&&\s+github\.ref == 'refs/heads/master'" -or
        $workflowSource -notmatch 'ref:\s+refs/heads/master' -or
        $workflowSource -notmatch 'github\.event\.client_payload\.tag' -or
        $workflowSource -notmatch 'FFB_CLIENT_PAYLOAD_JSON' -or
        $workflowSource -notmatch 'ConvertFrom-Json\s+-ErrorAction\s+Stop' -or
        $workflowSource -notmatch 'steps\.bind-release\.outputs\.commit_sha' -or
        $workflowSource -notmatch '-RefreshRemote\s+-RequireMasterHead' -or
        $workflowSource -notmatch '-ExpectedCommitSha\s+\$env:FFB_RELEASE_COMMIT') {
        throw 'release workflow is missing its repository-dispatch payload or exact-SHA binding contract'
    }
}
if ($fullWorkflow -notmatch 'github\.event\.client_payload\.channel' -or
    $fullWorkflow -notmatch 'github\.event\.client_payload\.simhub_path' -or
    $fullWorkflow -notmatch '\$channel\s+-cnotin\s+@\(''experimental'',\s*''stable''\)' -or
    $fullWorkflow -notmatch '\$names\.Count\s+-ne\s+\$expectedNames\.Count') {
    throw 'Full release workflow does not fail closed on its complete client payload contract'
}
if ($fullWorkflow -notmatch 'environment:\s+stable-signing' -or
    $fullWorkflow -notmatch 'runs-on:\s*\[[^\]]*ephemeral[^\]]*\]') {
    throw 'Full release workflow is missing its protected environment or ephemeral runner contract'
}
$stableStepMatch = [regex]::Match($fullWorkflow,
    '(?ms)^\s*- name: Load Stable release signing identity and policy\s*$.*?(?=^\s*- name:)')
if (-not $stableStepMatch.Success -or
    $stableStepMatch.Value -notmatch "if:\s*\$\{\{\s*env\.RELEASE_CHANNEL == 'stable'\s*\}\}" -or
    ([regex]::Matches($stableStepMatch.Value, '\$\{\{\s*secrets\.').Count -ne 3)) {
    throw 'Stable signing secrets are not isolated to the Stable-only step'
}
$withoutStableStep = $fullWorkflow.Remove($stableStepMatch.Index, $stableStepMatch.Length)
if ($withoutStableStep -match '\$\{\{\s*secrets\.' -or
    $fullWorkflow -notmatch 'Full experimental release is explicitly UNSIGNED' -or
    $fullWorkflow -notmatch 'FFB_SIGNING_CERT_THUMBPRINTS' -or
    $fullWorkflow -notmatch "FFB_SIGNING_CERT_THUMBPRINTS\s+-split\s+','" -or
    $fullWorkflow -notmatch 'foreach\s*\(\$thumbprint\s+in\s+\$thumbprints\)' -or
    $fullWorkflow -notmatch 'Remove-Item[^\r\n]+-DeleteKey') {
    throw 'Experimental Full release can reference signing state or cleanup is incomplete'
}

# Exercise exact remote tag/master binding in an isolated repository. The
# second invocation force-moves both refs and must still reject the originally
# recorded SHA, proving a long release build cannot silently change identity.
$refFixtureRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) (
    'ffb-release-ref-' + [Guid]::NewGuid().ToString('N'))))
$refFixturePrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not $refFixtureRoot.StartsWith($refFixturePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Unsafe release-ref fixture directory.'
}
$refWork = Join-Path $refFixtureRoot 'work'
$refOrigin = Join-Path $refFixtureRoot 'origin.git'
[IO.Directory]::CreateDirectory((Join-Path $refWork '.github\scripts')) | Out-Null
[IO.Directory]::CreateDirectory((Join-Path $refWork 'viewer\src\ffb_visualizer')) | Out-Null
[IO.Directory]::CreateDirectory((Join-Path $refWork 'simhub\Fixture')) | Out-Null
Copy-Item -LiteralPath (Join-Path $root '.github\scripts\verify-release-ref.ps1') `
    -Destination (Join-Path $refWork '.github\scripts\verify-release-ref.ps1')
[IO.File]::WriteAllText((Join-Path $refWork 'CMakeLists.txt'),
    'project(ffb_interceptor VERSION 0.3.0 LANGUAGES CXX)', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $refWork 'viewer\pyproject.toml'),
    "[project]`nversion = `"0.3.0`"`n", [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $refWork 'viewer\src\ffb_visualizer\__init__.py'),
    "__version__ = `"0.3.0`"`n", [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $refWork 'simhub\Fixture\Fixture.csproj'),
    '<Project><PropertyGroup><Version>0.3.0</Version></PropertyGroup></Project>',
    [Text.UTF8Encoding]::new($false))
$oldReleaseTag = $env:RELEASE_TAG
try {
    git init --initial-branch=master $refWork | Out-Null
    git -C $refWork config user.email 'release-fixture@example.invalid'
    git -C $refWork config user.name 'Release Fixture'
    git -C $refWork add .
    git -C $refWork commit -m initial | Out-Null
    git -C $refWork tag v0.3.0
    git init --bare $refOrigin | Out-Null
    git -C $refWork remote add origin $refOrigin
    git -C $refWork push origin master --tags | Out-Null
    $env:RELEASE_TAG = 'v0.3.0'
    Push-Location $refWork
    try {
        $boundSha = & '.github\scripts\verify-release-ref.ps1' `
            -RefreshRemote -RequireMasterHead -PassThru
        if ($boundSha -notmatch '^[0-9a-f]{40}$') { throw 'fixture did not bind a complete SHA' }
    }
    finally { Pop-Location }

    [IO.File]::AppendAllText((Join-Path $refWork 'CMakeLists.txt'), "`n# moved`n",
        [Text.UTF8Encoding]::new($false))
    git -C $refWork add CMakeLists.txt
    git -C $refWork commit -m moved | Out-Null
    $advancedSha = (git -C $refWork rev-parse HEAD).Trim()
    git -C $refWork push origin master | Out-Null
    git -C $refWork checkout --detach $boundSha | Out-Null
    Push-Location $refWork
    try {
        & '.github\scripts\verify-release-ref.ps1' -RefreshRemote `
            -ExpectedCommitSha $boundSha
    }
    finally { Pop-Location }

    git -C $refWork tag --force v0.3.0 $advancedSha | Out-Null
    git -C $refWork push --force origin refs/tags/v0.3.0 | Out-Null
    $movedRefFailure = $null
    Push-Location $refWork
    try {
        & '.github\scripts\verify-release-ref.ps1' -RefreshRemote `
            -ExpectedCommitSha $boundSha
    }
    catch { $movedRefFailure = $_.Exception.Message }
    finally { Pop-Location }
    if ($movedRefFailure -notmatch 'Release (?:ref moved|checkout mismatch)') {
        throw 'release ref fixture did not reject a remotely moved tag binding'
    }
}
finally {
    $env:RELEASE_TAG = $oldReleaseTag
    if ($refFixtureRoot.StartsWith($refFixturePrefix, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $refFixtureRoot)) {
        Remove-Item -LiteralPath $refFixtureRoot -Recurse -Force
    }
}

$publishScript = Join-Path $root '.github\scripts\publish-release-assets.ps1'
$publishTokens = $null
$publishErrors = $null
$publishAst = [Management.Automation.Language.Parser]::ParseFile(
    $publishScript, [ref]$publishTokens, [ref]$publishErrors)
if ($publishErrors.Count -gt 0) {
    throw "publish-release-assets.ps1 has a parser error: $($publishErrors[0].Message)"
}
$publishSource = $publishAst.Extent.Text
$draftCreateIndex = $publishSource.IndexOf("'--draft', '--title'", [StringComparison]::Ordinal)
$initialVerificationIndex = $publishSource.IndexOf(
    '$upload = @(Get-MissingReleaseAssetPaths -ReleaseDocument $release)', [StringComparison]::Ordinal)
$uploadIndex = $publishSource.IndexOf('gh release upload', [StringComparison]::Ordinal)
$finalVerificationIndex = $publishSource.IndexOf(
    '$stillMissing = @(Get-MissingReleaseAssetPaths -ReleaseDocument $release)', [StringComparison]::Ordinal)
$finalizeIndex = $publishSource.IndexOf('gh release edit', [StringComparison]::Ordinal)
if ($draftCreateIndex -lt 0) { throw 'new releases are not created as drafts' }
if ($initialVerificationIndex -lt 0 -or $uploadIndex -le $initialVerificationIndex -or
    $finalVerificationIndex -le $uploadIndex -or $finalizeIndex -le $finalVerificationIndex) {
    throw 'release publication does not verify, upload, re-verify, then finalize metadata in order'
}
if ($publishSource.IndexOf("'--draft=false'", [StringComparison]::Ordinal) -le $finalizeIndex) {
    throw 'release finalization does not publish the fully verified draft'
}
if ([regex]::Matches($publishSource, 'gh release edit').Count -ne 1) {
    throw 'release metadata has more than one mutation point'
}

# Parse the publisher and this contract test with both supported PowerShell
# engines when they are installed. Executing this test already covers the
# current engine; the explicit parse catches Windows PowerShell 5.1 regressions
# when CI is running PowerShell 7 (and vice versa).
$parseCommand = @'
$parseTokens = $null
$parseErrors = $null
[Management.Automation.Language.Parser]::ParseFile(
    $env:FFB_RELEASE_PARSE_TARGET, [ref]$parseTokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count -gt 0) {
    Write-Error $parseErrors[0].Message
    exit 1
}
'@
$originalParseTarget = $env:FFB_RELEASE_PARSE_TARGET
try {
    $shellPaths = @(Get-Command -Name 'powershell.exe', 'pwsh.exe' -CommandType Application `
        -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -Unique)
    foreach ($shellPath in $shellPaths) {
        foreach ($parseTarget in @($publishScript, $PSCommandPath)) {
            $env:FFB_RELEASE_PARSE_TARGET = $parseTarget
            & $shellPath -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
                -Command $parseCommand
            if ($LASTEXITCODE -ne 0) {
                throw "$parseTarget is not compatible with $shellPath"
            }
        }
    }
}
finally {
    $env:FFB_RELEASE_PARSE_TARGET = $originalParseTarget
}

# Exercise the actual publisher against an offline gh contract double. The
# double persists release state between invocations, so these checks prove that
# failed asset verification/upload cannot accidentally mutate public metadata.
$systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$contractRoot = [IO.Path]::GetFullPath((Join-Path $systemTemp (
    'ffb-release-contract-' + [Guid]::NewGuid().ToString('N'))))
$systemTempPrefix = $systemTemp.TrimEnd([IO.Path]::DirectorySeparatorChar) +
    [IO.Path]::DirectorySeparatorChar
if (-not $contractRoot.StartsWith($systemTempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Unsafe release contract-test directory.'
}
[IO.Directory]::CreateDirectory($contractRoot) | Out-Null

$mockStatePath = Join-Path $contractRoot 'state.json'
$assetsDirectory = Join-Path $contractRoot 'assets'
$notesPath = Join-Path $contractRoot 'notes.md'
[IO.Directory]::CreateDirectory($assetsDirectory) | Out-Null
$assetPath = Join-Path $assetsDirectory 'FFB-v0.3.0.zip'
[IO.File]::WriteAllText($assetPath, 'immutable-release-content', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($notesPath,
    "Release {{TAG}}`nVersion {{VERSION}}`n{{CHANNEL_NOTICE}}", [Text.UTF8Encoding]::new($false))
$assetInfo = Get-Item -LiteralPath $assetPath
$assetDigest = 'sha256:' + (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()

function Save-GhMockState {
    param([Parameter(Mandatory = $true)]$State)
    [IO.File]::WriteAllText($mockStatePath, ($State | ConvertTo-Json -Depth 6),
        [Text.UTF8Encoding]::new($false))
}

function Get-GhMockOptionValue {
    param(
        [Parameter(Mandatory = $true)][string[]]$Values,
        [Parameter(Mandatory = $true)][string]$Name
    )
    for ($index = 0; $index -lt $Values.Count; $index++) {
        if ($Values[$index] -ceq $Name -and $index + 1 -lt $Values.Count) {
            return [string]$Values[$index + 1]
        }
        $prefix = $Name + '='
        if ([string]$Values[$index] -like ($prefix + '*')) {
            return ([string]$Values[$index]).Substring($prefix.Length)
        }
    }
    return $null
}

# PowerShell resolves functions before applications, so the publisher invokes
# this in-process gh contract double without network access. Each invocation
# persists state exactly like a separate GitHub CLI process would.
function gh {
    $ghArgs = @($args)
    $state = Get-Content -Raw -LiteralPath $mockStatePath -Encoding UTF8 | ConvertFrom-Json
    $state.calls = @($state.calls) + @([pscustomobject]@{ arguments = @($ghArgs) })

    if ($ghArgs.Count -ge 1 -and $ghArgs[0] -ceq 'api') {
        Save-GhMockState -State $state
        if ($state.PSObject.Properties['apiMode'] -and
            [string]$state.apiMode -ceq 'server-error') {
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 1
            Write-Output 'HTTP/2.0 500 Internal Server Error'
            Write-Output '{"status":"500"}'
            return
        }
        if (-not [bool]$state.releaseExists) {
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 1
            Write-Output 'HTTP/2.0 404 Not Found'
            Write-Output '{"status":"404"}'
            return
        }
        Set-Variable -Name LASTEXITCODE -Scope 1 -Value 0
        Write-Output 'HTTP/2.0 200 OK'
        return ($state.release | ConvertTo-Json -Depth 6 -Compress)
    }

    if ($ghArgs.Count -ge 3 -and $ghArgs[0] -ceq 'release' -and
        $ghArgs[1] -ceq 'create') {
        if ([bool]$state.releaseExists -or -not ($ghArgs -ccontains '--draft')) {
            Save-GhMockState -State $state
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 2
            return
        }
        $notesFile = Get-GhMockOptionValue -Values $ghArgs -Name '--notes-file'
        $releaseTitle = Get-GhMockOptionValue -Values $ghArgs -Name '--title'
        $releaseBody = Get-Content -Raw -LiteralPath $notesFile -Encoding UTF8
        $state.releaseExists = $true
        $state.release = [pscustomobject]@{
            tag_name = [string]$ghArgs[2]
            name = $releaseTitle
            body = $releaseBody
            draft = $true
            prerelease = $false
            assets = @()
        }
        Save-GhMockState -State $state
        Set-Variable -Name LASTEXITCODE -Scope 1 -Value 0
        return
    }

    if ($ghArgs.Count -ge 3 -and $ghArgs[0] -ceq 'release' -and
        $ghArgs[1] -ceq 'upload') {
        if ([string]$state.uploadMode -ceq 'fail') {
            Save-GhMockState -State $state
            [Console]::Error.WriteLine('mock upload failed')
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 4
            return
        }
        if ([string]$state.uploadMode -ceq 'drop') {
            Save-GhMockState -State $state
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 0
            return
        }
        $repoIndex = -1
        for ($index = 3; $index -lt $ghArgs.Count; $index++) {
            if ($ghArgs[$index] -ceq '--repo') { $repoIndex = $index; break }
        }
        if ($repoIndex -le 3) {
            Save-GhMockState -State $state
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 5
            return
        }
        $remoteAssets = [Collections.ArrayList]::new()
        foreach ($remoteAsset in @($state.release.assets)) { [void]$remoteAssets.Add($remoteAsset) }
        foreach ($path in @($ghArgs[3..($repoIndex - 1)])) {
            $file = Get-Item -LiteralPath $path
            [void]$remoteAssets.Add([pscustomobject]@{
                name = $file.Name
                size = [long]$file.Length
                digest = 'sha256:' +
                    (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            })
        }
        $state.release.assets = @($remoteAssets)
        Save-GhMockState -State $state
        Set-Variable -Name LASTEXITCODE -Scope 1 -Value 0
        return
    }

    if ($ghArgs.Count -ge 3 -and $ghArgs[0] -ceq 'release' -and
        $ghArgs[1] -ceq 'edit') {
        $notesFile = Get-GhMockOptionValue -Values $ghArgs -Name '--notes-file'
        $state.release.name = Get-GhMockOptionValue -Values $ghArgs -Name '--title'
        $state.release.body = Get-Content -Raw -LiteralPath $notesFile -Encoding UTF8
        $state.release.prerelease =
            (Get-GhMockOptionValue -Values $ghArgs -Name '--prerelease') -ceq 'true'
        $state.release.draft =
            (Get-GhMockOptionValue -Values $ghArgs -Name '--draft') -ne 'false'
        Save-GhMockState -State $state
        Set-Variable -Name LASTEXITCODE -Scope 1 -Value 0
        return
    }

    Save-GhMockState -State $state
    Set-Variable -Name LASTEXITCODE -Scope 1 -Value 9
}

function Write-MockState {
    param(
        [Parameter(Mandatory = $true)][bool]$ReleaseExists,
        [AllowNull()]$Release,
        [Parameter(Mandatory = $true)][ValidateSet('success', 'fail', 'drop')][string]$UploadMode,
        [ValidateSet('success', 'server-error')][string]$ApiMode = 'success'
    )
    $document = [pscustomobject]@{
        releaseExists = $ReleaseExists
        release = $Release
        uploadMode = $UploadMode
        apiMode = $ApiMode
        calls = @()
    }
    [IO.File]::WriteAllText($mockStatePath, ($document | ConvertTo-Json -Depth 6),
        [Text.UTF8Encoding]::new($false))
}

function Read-MockState {
    return (Get-Content -Raw -LiteralPath $mockStatePath -Encoding UTF8 | ConvertFrom-Json)
}

function New-ExistingExperimentalRelease {
    param([object[]]$Assets = @())
    return [pscustomobject]@{
        tag_name = 'v0.3.0'
        name = 'v0.3.0 Experimental'
        body = 'operator-authored experimental notes'
        draft = $false
        prerelease = $true
        assets = @($Assets)
    }
}

function Invoke-TestPublisher {
    & $publishScript -AssetsDirectory $assetsDirectory -Tag 'v0.3.0' `
        -Repository 'owner/repository' -Title 'FFB Interceptor v0.3.0 Stable' `
        -NotesPath $notesPath
}

function Test-MockCall {
    param($Call, [string]$First, [string]$Second)
    $callArguments = @($Call.arguments)
    return $callArguments.Count -ge 2 -and $callArguments[0] -ceq $First -and
        $callArguments[1] -ceq $Second
}

function Assert-NoMetadataEdit {
    param([Parameter(Mandatory = $true)]$State)
    $edits = @($State.calls | Where-Object { Test-MockCall -Call $_ -First 'release' -Second 'edit' })
    if ($edits.Count -ne 0) { throw 'release metadata was edited before asset publication succeeded' }
}

function Assert-ExperimentalMetadataUnchanged {
    param([Parameter(Mandatory = $true)]$State)
    if ([string]$State.release.name -cne 'v0.3.0 Experimental' -or
        [string]$State.release.body -cne 'operator-authored experimental notes' -or
        -not [bool]$State.release.prerelease -or [bool]$State.release.draft) {
        throw 'existing Experimental release metadata changed during a failed asset operation'
    }
}

$oldRunnerTemp = $env:RUNNER_TEMP
try {
    $env:RUNNER_TEMP = $contractRoot
    $resolvedGh = Get-Command -Name gh -CommandType Function -ErrorAction Stop
    if ($resolvedGh.Name -cne 'gh') {
        throw 'offline gh contract double was not available to the publisher'
    }

    # A non-404 API failure is not an absent release and must fail before any
    # create/upload/edit mutation is attempted.
    Write-MockState -ReleaseExists $false -Release $null -UploadMode success `
        -ApiMode server-error
    $apiFailure = $null
    try { Invoke-TestPublisher } catch { $apiFailure = $_.Exception.Message }
    if ($apiFailure -notmatch 'HTTP 500') {
        throw 'non-404 publisher API failure was not rejected'
    }
    $state = Read-MockState
    $apiMutations = @($state.calls | Where-Object {
        (Test-MockCall -Call $_ -First 'release' -Second 'create') -or
            (Test-MockCall -Call $_ -First 'release' -Second 'upload') -or
            (Test-MockCall -Call $_ -First 'release' -Second 'edit')
    })
    if ($apiMutations.Count -ne 0) {
        throw 'publisher mutated a release after a non-404 API failure'
    }

    # Same name/size but different digest must fail before any metadata edit.
    $differentAsset = [pscustomobject]@{
        name = $assetInfo.Name
        size = [long]$assetInfo.Length
        digest = 'sha256:' + ('0' * 64)
    }
    Write-MockState -ReleaseExists $true `
        -Release (New-ExistingExperimentalRelease -Assets @($differentAsset)) -UploadMode success
    $digestFailure = $null
    try { Invoke-TestPublisher } catch { $digestFailure = $_.Exception.Message }
    if ($digestFailure -notmatch 'differs in digest') {
        throw 'same-name immutable asset mismatch was not rejected'
    }
    $state = Read-MockState
    Assert-NoMetadataEdit -State $state
    Assert-ExperimentalMetadataUnchanged -State $state

    # An unrecognized remote asset is part of the immutable public surface and
    # must not be silently carried into the finalized release.
    $unexpectedAsset = [pscustomobject]@{
        name = 'stale-build.zip'
        size = 1
        digest = 'sha256:' + ('1' * 64)
    }
    Write-MockState -ReleaseExists $true `
        -Release (New-ExistingExperimentalRelease -Assets @($unexpectedAsset)) -UploadMode success
    $unexpectedFailure = $null
    try { Invoke-TestPublisher } catch { $unexpectedFailure = $_.Exception.Message }
    if ($unexpectedFailure -notmatch 'unexpected immutable asset') {
        throw 'unexpected immutable release asset was not rejected'
    }
    $state = Read-MockState
    Assert-NoMetadataEdit -State $state
    Assert-ExperimentalMetadataUnchanged -State $state

    # A failed upload must leave an existing public Experimental release intact.
    Write-MockState -ReleaseExists $true `
        -Release (New-ExistingExperimentalRelease) -UploadMode fail
    $uploadFailure = $null
    try { Invoke-TestPublisher } catch { $uploadFailure = $_.Exception.Message }
    if ($uploadFailure -notmatch 'Unable to upload') { throw 'failed upload was not rejected' }
    $state = Read-MockState
    Assert-NoMetadataEdit -State $state
    Assert-ExperimentalMetadataUnchanged -State $state

    # A successful upload exit code without the asset appearing on read-back is
    # also a failure and cannot finalize metadata.
    Write-MockState -ReleaseExists $true `
        -Release (New-ExistingExperimentalRelease) -UploadMode drop
    $verificationFailure = $null
    try { Invoke-TestPublisher } catch { $verificationFailure = $_.Exception.Message }
    if ($verificationFailure -notmatch 'still missing') {
        throw 'post-upload missing-asset verification was not enforced'
    }
    $state = Read-MockState
    Assert-NoMetadataEdit -State $state
    Assert-ExperimentalMetadataUnchanged -State $state

    # Once upload and exact-content read-back both succeed, an existing public
    # Experimental release may be finalized exactly once as Stable.
    Write-MockState -ReleaseExists $true `
        -Release (New-ExistingExperimentalRelease) -UploadMode success
    Invoke-TestPublisher
    $state = Read-MockState
    $existingMutations = @($state.calls | Where-Object {
        (Test-MockCall -Call $_ -First 'release' -Second 'upload') -or
            (Test-MockCall -Call $_ -First 'release' -Second 'edit')
    })
    if ($existingMutations.Count -ne 2 -or
        -not (Test-MockCall -Call $existingMutations[0] -First 'release' -Second 'upload') -or
        -not (Test-MockCall -Call $existingMutations[1] -First 'release' -Second 'edit') -or
        [bool]$state.release.draft -or [bool]$state.release.prerelease -or
        [string]$state.release.name -cne 'FFB Interceptor v0.3.0 Stable' -or
        [string]$state.release.assets[0].digest -cne $assetDigest -or
        [string]$state.release.body -notmatch 'operator-authored experimental notes' -or
        [string]$state.release.body -notmatch '<!-- ffb-generated:start -->' -or
        [string]$state.release.body -notmatch 'Version 0\.3\.0' -or
        [string]$state.release.body -match '\{\{(?:TAG|VERSION|CHANNEL_NOTICE)\}\}') {
        throw 'existing Experimental release was not finalized only after asset verification'
    }

    # A newly-created release may carry provisional metadata only while it is a
    # private draft. Failed upload must never publish it.
    Write-MockState -ReleaseExists $false -Release $null -UploadMode fail
    $newUploadFailure = $null
    try { Invoke-TestPublisher } catch { $newUploadFailure = $_.Exception.Message }
    if ($newUploadFailure -notmatch 'Unable to upload') {
        throw 'new-release upload failure was not rejected'
    }
    $state = Read-MockState
    if (-not [bool]$state.releaseExists -or -not [bool]$state.release.draft) {
        throw 'failed new release was exposed instead of remaining a draft'
    }
    Assert-NoMetadataEdit -State $state

    # On success the only metadata edit occurs after upload and read-back, and
    # it publishes the verified draft with the requested stable metadata.
    Write-MockState -ReleaseExists $false -Release $null -UploadMode success
    Invoke-TestPublisher
    $state = Read-MockState
    $mutations = @($state.calls | Where-Object {
        (Test-MockCall -Call $_ -First 'release' -Second 'create') -or
            (Test-MockCall -Call $_ -First 'release' -Second 'upload') -or
            (Test-MockCall -Call $_ -First 'release' -Second 'edit')
    })
    if ($mutations.Count -ne 3 -or
        -not (Test-MockCall -Call $mutations[0] -First 'release' -Second 'create') -or
        -not (Test-MockCall -Call $mutations[1] -First 'release' -Second 'upload') -or
        -not (Test-MockCall -Call $mutations[2] -First 'release' -Second 'edit')) {
        throw 'release mutations did not occur in draft-create, asset-upload, metadata-finalize order'
    }
    if ([bool]$state.release.draft -or [bool]$state.release.prerelease -or
        [string]$state.release.name -cne 'FFB Interceptor v0.3.0 Stable' -or
        @($state.release.assets).Count -ne 1 -or
        [string]$state.release.assets[0].digest -cne $assetDigest) {
        throw 'verified draft was not finalized with the expected stable release state'
    }
}
finally {
    $env:RUNNER_TEMP = $oldRunnerTemp
    if ($contractRoot.StartsWith($systemTempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $contractRoot)) {
        Remove-Item -LiteralPath $contractRoot -Recurse -Force
    }
}

Write-Host 'PASS release and coverage gate fixtures'
