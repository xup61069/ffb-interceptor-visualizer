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
$runnerPreflightWorkflow = Get-Content -Raw -LiteralPath (
    Join-Path $root '.github\workflows\simhub-runner-preflight.yml')
$packageRelease = Get-Content -Raw -LiteralPath (Join-Path $root '.github\scripts\package-release.ps1')
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
        $workflowSource -notmatch 'ConvertFrom-Json\s+-ErrorAction\s+Stop') {
        throw 'release workflow is missing its repository-dispatch payload or exact-SHA binding contract'
    }

    # A colon immediately after $env:RELEASE_TAG is parsed by PowerShell as
    # part of the environment-variable drive-qualified name. Build the
    # refspec with the format operator so both source and destination retain
    # the validated tag exactly.
    $tagRefIndex = $workflowSource.IndexOf(
        '$tagRef = ''refs/tags/{0}'' -f $env:RELEASE_TAG',
        [StringComparison]::Ordinal)
    $tagRefspecIndex = $workflowSource.IndexOf(
        '$tagRefspec = ''+{0}:{0}'' -f $tagRef',
        [StringComparison]::Ordinal)
    $tagFetchIndex = $workflowSource.IndexOf(
        'git fetch --force --no-tags origin $tagRefspec',
        [StringComparison]::Ordinal)
    if ($tagRefIndex -lt 0 -or $tagRefspecIndex -le $tagRefIndex -or
        $tagFetchIndex -le $tagRefspecIndex -or
        [regex]::IsMatch($workflowSource, '\$env:[A-Za-z_][A-Za-z0-9_]*:')) {
        throw 'release workflow does not construct its tag refspec without ambiguous environment-variable interpolation'
    }

    foreach ($requiredFragment in @(
        'id: trusted-controls',
        'id: release-preflight',
        'id: bind-release',
        'FFB_TRUSTED_RELEASE_API: ${{ steps.trusted-controls.outputs.release_api }}',
        'FFB_TRUSTED_RELEASE_API_SHA256: ${{ steps.trusted-controls.outputs.release_api_sha256 }}',
        'FFB_TRUSTED_RELEASE_PREFLIGHT: ${{ steps.trusted-controls.outputs.release_preflight }}',
        'FFB_TRUSTED_RELEASE_PREFLIGHT_SHA256: ${{ steps.trusted-controls.outputs.release_preflight_sha256 }}',
        'FFB_TRUSTED_PUBLISHER: ${{ steps.trusted-controls.outputs.publisher }}',
        'FFB_TRUSTED_PUBLISHER_SHA256: ${{ steps.trusted-controls.outputs.publisher_sha256 }}',
        'FFB_TRUSTED_VERIFY_RELEASE_REF: ${{ steps.trusted-controls.outputs.verify_release_ref }}',
        'FFB_TRUSTED_VERIFY_RELEASE_REF_SHA256: ${{ steps.trusted-controls.outputs.verify_release_ref_sha256 }}',
        'FFB_TRUSTED_WAIT_REQUIRED_CHECKS_SHA256: ${{ steps.trusted-controls.outputs.wait_required_checks_sha256 }}',
        'FFB_RELEASE_STATE: ${{ steps.release-preflight.outputs.release_state }}',
        'FFB_EXPECTED_RELEASE_ID: ${{ steps.release-preflight.outputs.release_id }}',
        'FFB_RELEASE_COMMIT: ${{ steps.bind-release.outputs.commit_sha }}',
        'ref: ${{ steps.bind-release.outputs.commit_sha }}',
        'Get-FFBUniqueReleaseByTag',
        'Assert-FFBMutableReleaseDraft',
        'git merge-base --is-ancestor',
        'elseif ($tagCommit -cne $masterCommit)',
        '$verifyArguments.RequireMasterHead = $true',
        '& $env:FFB_TRUSTED_VERIFY_RELEASE_REF @verifyArguments',
        '$publisherArguments.ExpectedReleaseId = [long]$env:FFB_EXPECTED_RELEASE_ID'
    )) {
        if ($workflowSource.IndexOf($requiredFragment, [StringComparison]::Ordinal) -lt 0) {
            throw "release workflow is missing trusted recovery contract fragment: $requiredFragment"
        }
    }

    if ([regex]::Matches($workflowSource,
            '\$verifyArguments\.RequireMasterHead\s*=\s*\$true').Count -lt 2 -or
        [regex]::Matches($workflowSource,
            '(?m)Get-FFBUniqueReleaseByTag[^\r\n]*(?:\r?\n[^\r\n]*){0,2}-ExpectedId').Count -lt 1 -or
        [regex]::Matches($workflowSource,
            'Assert-FFBMutableReleaseDraft').Count -lt 2 -or
        [regex]::Matches($workflowSource,
            '&\s+\$env:FFB_TRUSTED_VERIFY_RELEASE_REF\s+@verifyArguments').Count -lt 2 -or
        $workflowSource -notmatch '(?ms)"release_state=\$state",\s*"release_id=\$releaseId"\s*\)\s*\|\s*Out-File[^\r\n]+\$env:GITHUB_OUTPUT' -or
        $workflowSource -notmatch '(?m)"commit_sha=\$tagCommit"\s*\|\s*Out-File[^\r\n]+\$env:GITHUB_OUTPUT' -or
        [regex]::Matches($workflowSource,
            'if\s*\(\$env:FFB_RELEASE_STATE\s+-ne\s+''draft-recovery''\)').Count -lt 2 -or
        $workflowSource -notmatch 'elseif\s*\(\$env:FFB_RELEASE_STATE\s+-eq\s+''published''\)' -or
        $workflowSource -notmatch 'already has a published release' -or
        [regex]::Matches($workflowSource,
            'Get-FileHash[^\r\n]+-Algorithm\s+SHA256').Count -lt 5) {
        throw 'release workflow does not preserve pinned outputs, recovery state, or normal master-head policy'
    }

    $boundCheckoutIndex = $workflowSource.IndexOf(
        'ref: ${{ steps.bind-release.outputs.commit_sha }}', [StringComparison]::Ordinal)
    $revalidationIndex = $workflowSource.IndexOf(
        '- name: Revalidate release state before using tagged source', [StringComparison]::Ordinal)
    $taggedUseIndex = $workflowSource.IndexOf(
        '- name: Reverify bound release source', [StringComparison]::Ordinal)
    if ($taggedUseIndex -lt 0) {
        $taggedUseIndex = $workflowSource.IndexOf(
            '- name: Verify bound release ref and exact-commit checks', [StringComparison]::Ordinal)
    }
    if ($boundCheckoutIndex -lt 0 -or $revalidationIndex -le $boundCheckoutIndex -or
        $taggedUseIndex -le $revalidationIndex) {
        throw 'release state is not revalidated immediately after the bound tag checkout'
    }

    $revalidationBlock = $workflowSource.Substring(
        $revalidationIndex, $taggedUseIndex - $revalidationIndex)
    if ($revalidationBlock -notmatch 'steps\.release-preflight\.outputs\.release_state' -or
        $revalidationBlock -notmatch 'steps\.release-preflight\.outputs\.release_id' -or
        $revalidationBlock -notmatch 'Get-FFBUniqueReleaseByTag|FFB_TRUSTED_RELEASE_PREFLIGHT' -or
        $revalidationBlock -notmatch 'draft-recovery' -or
        $revalidationBlock -notmatch 'published') {
        throw 'post-checkout release revalidation is not bound to the original state and numeric ID'
    }
}
if ($fullWorkflow -notmatch 'github\.event\.client_payload\.channel' -or
    $fullWorkflow -notmatch 'id:\s+validated-payload' -or
    $fullWorkflow -notmatch '"simhub_install_path=\$normalisedSimHubPath"' -or
    [regex]::Matches($fullWorkflow,
        [regex]::Escape('SIMHUB_INSTALL_PATH: ${{ steps.validated-payload.outputs.simhub_install_path }}')).Count -lt 2 -or
    $fullWorkflow.IndexOf(
        'SIMHUB_INSTALL_PATH: ${{ github.event.client_payload.simhub_path }}',
        [StringComparison]::Ordinal) -ge 0 -or
    $fullWorkflow -notmatch '\$channel\s+-cnotin\s+@\(''experimental'',\s*''stable''\)' -or
    $fullWorkflow -notmatch '\$names\.Count\s+-ne\s+\$expectedNames\.Count' -or
    $fullWorkflow -notmatch 'Compare-Object[^\r\n]+-CaseSensitive') {
    throw 'Full release workflow does not fail closed on its complete client payload contract'
}
if ($fullWorkflow -notmatch 'if\s*\(\$env:RELEASE_CHANNEL\s+-eq\s+''stable''\)' -or
    $fullWorkflow -notmatch 'Stable channel cannot resume an existing draft' -or
    [regex]::Matches($fullWorkflow, 'function\s+Restore-FFBTrustedSigner').Count -lt 2 -or
    [regex]::Matches($fullWorkflow, 'if\s*\(\$stable\)\s*\{\s*Restore-FFBTrustedSigner\s*\}').Count -lt 4) {
    throw 'Full release workflow permits Stable ancestor-draft recovery or does not rebind its trusted signer'
}
if ($fullWorkflow -notmatch 'environment:\s+stable-signing' -or
    $fullWorkflow -notmatch 'runs-on:\s*\[[^\]]*ephemeral[^\]]*\]') {
    throw 'Full release workflow is missing its protected environment or ephemeral runner contract'
}
foreach ($requiredFullOperationFragment in @(
    'run-name: Full release ${{ github.event.client_payload.tag }} (${{ github.event.client_payload.channel }})',
    'timeout-minutes: 120',
    'id: build-toolchain',
    "python-version: '3.13'",
    '- name: Install isolated uv-managed Python',
    'UV_PYTHON_INSTALL_DIR',
    'uv python install 3.13',
    '-products Microsoft.VisualStudio.Product.BuildTools',
    '-version ''[17.0,18.0)''',
    '"visual_studio_install_path=$vsroot"',
    'FFB_VISUAL_STUDIO_INSTALL_PATH: ${{ steps.build-toolchain.outputs.visual_studio_install_path }}',
    '-VisualStudioInstallPath $env:FFB_VISUAL_STUDIO_INSTALL_PATH'
)) {
    if ($fullWorkflow.IndexOf($requiredFullOperationFragment,
            [StringComparison]::Ordinal) -lt 0) {
        throw "Full release workflow is missing bounded runner/toolchain contract fragment: $requiredFullOperationFragment"
    }
}
if ($fullWorkflow -match 'actions/setup-python@') {
    throw 'Full release workflow must not require administrator-only setup-python on its isolated self-hosted runner'
}
foreach ($requiredRunnerPreflightFragment in @(
    'types: [ffb-full-runner-preflight]',
    'run-name: Full runner preflight ${{ github.event.client_payload.commit }}',
    'timeout-minutes: 120',
    'runs-on: [self-hosted, Windows, X64, simhub-sdk, ephemeral]',
    'permissions:',
    'contents: read',
    'ref: refs/heads/master',
    'persist-credentials: false',
    'Runner preflight client_payload must contain exactly: commit, simhub_path.',
    '$head -cne $commit -or $master -cne $commit',
    "python-version: '3.13'",
    '-products Microsoft.VisualStudio.Product.BuildTools',
    '-version ''[17.0,18.0)''',
    '.github/scripts/package-release.ps1',
    'simhub/tools/Test-SimHubPackage.ps1',
    'simhub/tools/Test-LauncherPackage.ps1'
)) {
    if ($runnerPreflightWorkflow.IndexOf($requiredRunnerPreflightFragment,
            [StringComparison]::Ordinal) -lt 0) {
        throw "Runner preflight workflow is missing fail-closed fragment: $requiredRunnerPreflightFragment"
    }
}
if ($runnerPreflightWorkflow -match 'environment:\s+stable-signing|contents:\s+write|secrets\.') {
    throw 'Runner preflight workflow must not receive the release environment, write permission, or secrets'
}
foreach ($requiredPackageToolchainFragment in @(
    '[string]$VisualStudioInstallPath = ''''',
    '-products *',
    '-version ''[17.0,18.0)''',
    'Resolve-Path -LiteralPath $VisualStudioInstallPath -ErrorAction Stop'
)) {
    if ($packageRelease.IndexOf($requiredPackageToolchainFragment,
            [StringComparison]::Ordinal) -lt 0) {
        throw "Base/Full package script is missing its Visual Studio 2022 selection contract: $requiredPackageToolchainFragment"
    }
}
if ($packageRelease.IndexOf(
        'uv run --project viewer python .github/scripts/generate-component-sbom.py',
        [StringComparison]::Ordinal) -lt 0) {
    throw 'Release component SBOM must use the locked uv-managed Python environment'
}
$stableStepMatch = [regex]::Match($fullWorkflow,
    '(?ms)^\s*- name: Load Stable release signing identity and policy\s*$.*?(?=^\s*- name:)')
if (-not $stableStepMatch.Success -or
    $stableStepMatch.Value -notmatch "if:\s*\$\{\{\s*github\.event\.client_payload\.channel == 'stable'\s*\}\}" -or
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
    $fixtureTagRef = 'refs/tags/{0}' -f $env:RELEASE_TAG
    $fixtureTagRefspec = '+{0}:{0}' -f $fixtureTagRef
    if ($fixtureTagRefspec -cne '+refs/tags/v0.3.0:refs/tags/v0.3.0') {
        throw 'release tag refspec formatter did not preserve the exact tag on both sides'
    }
    $expectedFixtureTagCommit = (git -C $refWork rev-list -n 1 $env:RELEASE_TAG).Trim()
    git -C $refWork tag --delete $env:RELEASE_TAG | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'fixture could not remove its local release tag before fetch' }
    git -C $refWork fetch --force --no-tags origin $fixtureTagRefspec
    if ($LASTEXITCODE -ne 0) { throw 'formatted release tag refspec was rejected by git fetch' }
    $fetchedFixtureTagCommit = (git -C $refWork rev-list -n 1 $env:RELEASE_TAG).Trim()
    if ($fetchedFixtureTagCommit -cne $expectedFixtureTagCommit) {
        throw 'formatted release tag refspec did not restore the exact destination tag commit'
    }
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
$releaseApiScript = Join-Path $root '.github\scripts\release-api.ps1'
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
$uploadIndex = $publishSource.IndexOf(
    'https://uploads.github.com/repos/$Repository/releases/$releaseId/assets?name=$escapedName',
    [StringComparison]::Ordinal)
$finalVerificationIndex = $publishSource.IndexOf(
    '$stillMissing = @(Get-MissingReleaseAssetPaths -ReleaseDocument $release)', [StringComparison]::Ordinal)
$finalizeIndex = $publishSource.IndexOf(
    "'api', '--method', 'PATCH'", [StringComparison]::Ordinal)
if ($draftCreateIndex -lt 0) { throw 'new releases are not created as drafts' }
if ($initialVerificationIndex -lt 0 -or $uploadIndex -le $initialVerificationIndex -or
    $finalVerificationIndex -le $uploadIndex -or $finalizeIndex -le $finalVerificationIndex) {
    throw 'release publication does not verify, upload, re-verify, then finalize metadata in order'
}
if ($publishSource.IndexOf('"repos/$Repository/releases/$releaseId"',
        [StringComparison]::Ordinal) -le $finalizeIndex -or
    $publishSource.IndexOf('draft = $false', [StringComparison]::Ordinal) -lt 0) {
    throw 'release finalization does not publish the pinned numeric-ID draft'
}
if ([regex]::Matches($publishSource, 'gh release edit').Count -ne 0 -or
    [regex]::Matches($publishSource, 'gh release upload').Count -ne 0 -or
    [regex]::Matches($publishSource, "'api', '--method', 'POST'").Count -ne 1 -or
    [regex]::Matches($publishSource, "'api', '--method', 'PATCH'").Count -ne 1) {
    throw 'release metadata is not finalized exactly once through numeric-ID REST PATCH'
}
if ($publishSource -notmatch '\[Parameter\(Mandatory\s*=\s*\$true\)\]\[string\[\]\]\$ExpectedAssetNames' -or
    $publishSource.IndexOf(
        'UNSIGNED EXPERIMENTAL - command telemetry only; not motor torque.',
        [StringComparison]::Ordinal) -lt 0) {
    throw 'publisher does not require an exact local asset set or an engine-stable ASCII default notice'
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
        foreach ($parseTarget in @($releaseApiScript, $publishScript, $PSCommandPath)) {
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

function ConvertTo-GhMockReleaseSnapshot {
    param([AllowNull()]$Release)
    if ($null -eq $Release) { return $null }

    $assets = [Collections.Generic.List[object]]::new()
    foreach ($asset in @($Release.assets)) {
        $digestProperty = $asset.PSObject.Properties['digest']
        $assets.Add([pscustomobject][ordered]@{
            name = [string]$asset.name
            size = [long]$asset.size
            digest = if ($digestProperty) { [string]$digestProperty.Value } else { $null }
        })
    }
    return [pscustomobject][ordered]@{
        id = [long]$Release.id
        tag_name = [string]$Release.tag_name
        name = [string]$Release.name
        body = [string]$Release.body
        draft = [bool]$Release.draft
        prerelease = [bool]$Release.prerelease
        immutable = [bool]$Release.immutable
        assets = [object[]]$assets
    }
}

function Save-GhMockState {
    param([Parameter(Mandatory = $true)]$State)

    # Windows PowerShell 5.1 can retain hidden PSObject adapter graphs when a
    # ConvertFrom-Json object is mutated in a dynamically scoped mock function.
    # Rebuild a scalar-only snapshot before serialising so the contract double
    # behaves consistently in both supported engines instead of recursing over
    # engine metadata.
    $otherReleases = [Collections.Generic.List[object]]::new()
    foreach ($otherRelease in @($State.otherReleases)) {
        $otherReleases.Add((ConvertTo-GhMockReleaseSnapshot -Release $otherRelease))
    }
    $calls = [Collections.Generic.List[object]]::new()
    foreach ($call in @($State.calls)) {
        $arguments = [Collections.Generic.List[string]]::new()
        foreach ($argument in @($call.arguments)) { $arguments.Add([string]$argument) }
        $calls.Add([pscustomobject][ordered]@{ arguments = [string[]]$arguments })
    }
    $snapshot = [pscustomobject][ordered]@{
        releaseExists = [bool]$State.releaseExists
        release = (ConvertTo-GhMockReleaseSnapshot -Release $State.release)
        uploadMode = [string]$State.uploadMode
        downloadMode = [string]$State.downloadMode
        apiMode = [string]$State.apiMode
        otherReleases = [object[]]$otherReleases
        duplicateRelease = (ConvertTo-GhMockReleaseSnapshot -Release $State.duplicateRelease)
        pageSize = [int]$State.pageSize
        changeIdAfterUpload = [bool]$State.changeIdAfterUpload
        replaceBeforeUpload = [bool]$State.replaceBeforeUpload
        replaceBeforeFinalize = [bool]$State.replaceBeforeFinalize
        finalImmutable = [bool]$State.finalImmutable
        immutableAfterReads = [int]$State.immutableAfterReads
        postFinalizeReadCount = [int]$State.postFinalizeReadCount
        calls = [object[]]$calls
    }
    [IO.File]::WriteAllText($mockStatePath,
        (ConvertTo-Json -InputObject $snapshot -Depth 10),
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

function Test-GhMockHeader {
    param(
        [Parameter(Mandatory = $true)][string[]]$Values,
        [Parameter(Mandatory = $true)][string]$Header
    )
    for ($index = 0; $index + 1 -lt $Values.Count; $index++) {
        if ($Values[$index] -ceq '-H' -and $Values[$index + 1] -ceq $Header) {
            return $true
        }
    }
    return $false
}

# PowerShell resolves functions before applications, so the publisher invokes
# this in-process gh contract double without network access. Each invocation
# persists state exactly like a separate GitHub CLI process would.
function gh {
    $ghArgs = @($args)
    $state = Get-Content -Raw -LiteralPath $mockStatePath -Encoding UTF8 | ConvertFrom-Json
    $state.calls = @($state.calls) + @([pscustomobject]@{ arguments = @($ghArgs) })

    if ($ghArgs.Count -ge 1 -and $ghArgs[0] -ceq 'api' -and
        $ghArgs -ccontains '--method') {
        $method = Get-GhMockOptionValue -Values $ghArgs -Name '--method'
        $inputPath = Get-GhMockOptionValue -Values $ghArgs -Name '--input'
        if ($method -ceq 'POST') {
            $uploadReleaseId = if ([bool]$state.releaseExists) { [long]$state.release.id } else { [long]0 }
            $inputFile = if (Test-Path -LiteralPath $inputPath -PathType Leaf) {
                Get-Item -LiteralPath $inputPath
            }
            else { $null }
            $expectedUploadUri = if ($inputFile) {
                "https://uploads.github.com/repos/owner/repository/releases/$uploadReleaseId/assets?name=$([Uri]::EscapeDataString($inputFile.Name))"
            }
            else { '' }
            $replacedBeforeUpload = [bool]$state.replaceBeforeUpload
            if ($replacedBeforeUpload) {
                $state.release.id = [long]$state.release.id + 1
                $state.replaceBeforeUpload = $false
            }
            if ($replacedBeforeUpload -or -not [bool]$state.releaseExists -or
                -not [bool]$state.release.draft -or -not $inputFile -or
                $ghArgs[-1] -cne $expectedUploadUri -or
                $ghArgs -cnotcontains '--silent' -or
                -not (Test-GhMockHeader -Values $ghArgs -Header 'Accept: application/vnd.github+json') -or
                -not (Test-GhMockHeader -Values $ghArgs -Header 'X-GitHub-Api-Version: 2026-03-10') -or
                -not (Test-GhMockHeader -Values $ghArgs -Header 'Content-Type: application/octet-stream')) {
                Save-GhMockState -State $state
                Set-Variable -Name LASTEXITCODE -Scope 1 -Value 6
                return
            }
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
            $remoteAssets = [Collections.ArrayList]::new()
            foreach ($remoteAsset in @($state.release.assets)) { [void]$remoteAssets.Add($remoteAsset) }
            [void]$remoteAssets.Add([pscustomobject]@{
                name = $inputFile.Name
                size = [long]$inputFile.Length
                digest = 'sha256:' +
                    (Get-FileHash -LiteralPath $inputFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            })
            $state.release.assets = @($remoteAssets)
            if ([bool]$state.changeIdAfterUpload) {
                $state.release.id = [long]$state.release.id + 1
            }
            Save-GhMockState -State $state
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 0
            return
        }

        $expectedEndpoint = if ([bool]$state.releaseExists) {
            "repos/owner/repository/releases/$([long]$state.release.id)"
        }
        else { '' }
        $replacedBeforeFinalize = [bool]$state.replaceBeforeFinalize
        if ($replacedBeforeFinalize) {
            $state.release.id = [long]$state.release.id + 1
            $state.replaceBeforeFinalize = $false
        }
        if ($replacedBeforeFinalize -or $method -cne 'PATCH' -or
            $ghArgs[-1] -cne $expectedEndpoint -or
            -not (Test-GhMockHeader -Values $ghArgs -Header 'Accept: application/vnd.github+json') -or
            -not (Test-GhMockHeader -Values $ghArgs -Header 'X-GitHub-Api-Version: 2026-03-10') -or
            -not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
            Save-GhMockState -State $state
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 6
            Write-Output '{"message":"Not Found"}'
            return
        }
        try {
            $request = Get-Content -Raw -LiteralPath $inputPath -Encoding UTF8 |
                ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            Save-GhMockState -State $state
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 7
            return
        }
        if (@($request.PSObject.Properties).Count -ne 5 -or
            [string]$request.tag_name -cne 'v0.3.0' -or
            -not $request.PSObject.Properties['name'] -or
            -not $request.PSObject.Properties['body'] -or
            $request.PSObject.Properties['draft'].Value -isnot [bool] -or
            $request.PSObject.Properties['prerelease'].Value -isnot [bool] -or
            [bool]$request.draft) {
            Save-GhMockState -State $state
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 8
            return
        }
        $state.release.name = [string]$request.name
        $state.release.body = [string]$request.body
        $state.release.prerelease = [bool]$request.prerelease
        $state.release.draft = $false
        $state.release.immutable = [bool]$state.finalImmutable
        Save-GhMockState -State $state
        Set-Variable -Name LASTEXITCODE -Scope 1 -Value 0
        Write-Output ($state.release | ConvertTo-Json -Depth 6 -Compress)
        return
    }

    if ($ghArgs.Count -ge 1 -and $ghArgs[0] -ceq 'api') {
        if ($ghArgs[-1] -cne 'repos/owner/repository/releases?per_page=100' -or
            $ghArgs -cnotcontains '--paginate' -or
            $ghArgs -cnotcontains '--slurp' -or
            $ghArgs -ccontains '--jq' -or
            -not (Test-GhMockHeader -Values $ghArgs -Header 'Accept: application/vnd.github+json') -or
            -not (Test-GhMockHeader -Values $ghArgs -Header 'X-GitHub-Api-Version: 2026-03-10')) {
            Save-GhMockState -State $state
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 2
            Write-Output 'invalid paginated releases-list contract'
            return
        }
        if ($state.PSObject.Properties['apiMode'] -and
            [string]$state.apiMode -ceq 'server-error') {
            Save-GhMockState -State $state
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 1
            Write-Output 'HTTP/2.0 500 Internal Server Error'
            Write-Output '{"status":"500"}'
            return
        }

        if ([bool]$state.releaseExists -and -not [bool]$state.release.draft -and
            -not [bool]$state.release.immutable -and [int]$state.immutableAfterReads -gt 0) {
            $state.postFinalizeReadCount = [int]$state.postFinalizeReadCount + 1
            if ([int]$state.postFinalizeReadCount -ge [int]$state.immutableAfterReads) {
                $state.release.immutable = $true
            }
        }

        $releaseDocuments = [Collections.Generic.List[object]]::new()
        foreach ($otherRelease in @($state.otherReleases)) {
            $releaseDocuments.Add($otherRelease)
        }
        if ([bool]$state.releaseExists) { $releaseDocuments.Add($state.release) }
        if ($state.PSObject.Properties['duplicateRelease'] -and
            $null -ne $state.duplicateRelease) {
            $releaseDocuments.Add($state.duplicateRelease)
        }

        $pageSize = [int]$state.pageSize
        $pages = [Collections.Generic.List[object]]::new()
        if ($releaseDocuments.Count -eq 0) {
            $pages.Add([object[]]@())
        }
        else {
            for ($offset = 0; $offset -lt $releaseDocuments.Count; $offset += $pageSize) {
                $page = [Collections.Generic.List[object]]::new()
                $limit = [Math]::Min($offset + $pageSize, $releaseDocuments.Count)
                for ($index = $offset; $index -lt $limit; $index++) {
                    $page.Add($releaseDocuments[$index])
                }
                $pages.Add([object[]]$page)
            }
        }
        Save-GhMockState -State $state
        Set-Variable -Name LASTEXITCODE -Scope 1 -Value 0
        Write-Output (ConvertTo-Json -InputObject $pages -Depth 10 -Compress)
        return
    }

    if ($ghArgs.Count -ge 3 -and $ghArgs[0] -ceq 'release' -and
        $ghArgs[1] -ceq 'download') {
        $downloadTag = [string]$ghArgs[2]
        $downloadRepository = Get-GhMockOptionValue -Values $ghArgs -Name '--repo'
        $downloadPattern = Get-GhMockOptionValue -Values $ghArgs -Name '--pattern'
        $downloadDirectory = Get-GhMockOptionValue -Values $ghArgs -Name '--dir'
        if ($downloadTag -cne 'v0.3.0' -or $downloadRepository -cne 'owner/repository' -or
            $downloadPattern -cne $assetInfo.Name -or
            -not (Test-Path -LiteralPath $downloadDirectory -PathType Container)) {
            Save-GhMockState -State $state
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 10
            return
        }
        if ([string]$state.downloadMode -ceq 'fail') {
            Save-GhMockState -State $state
            Set-Variable -Name LASTEXITCODE -Scope 1 -Value 11
            return
        }
        $downloadPath = Join-Path $downloadDirectory $assetInfo.Name
        if ([string]$state.downloadMode -ceq 'mismatch') {
            [IO.File]::WriteAllText($downloadPath, 'different-remote-content',
                [Text.UTF8Encoding]::new($false))
        }
        else {
            [IO.File]::WriteAllBytes($downloadPath, [IO.File]::ReadAllBytes($assetPath))
        }
        Save-GhMockState -State $state
        Set-Variable -Name LASTEXITCODE -Scope 1 -Value 0
        return
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
            id = [long]379831902
            tag_name = [string]$ghArgs[2]
            name = $releaseTitle
            body = $releaseBody
            draft = $true
            prerelease = $false
            immutable = $false
            assets = @()
        }
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
        [ValidateSet('match', 'mismatch', 'fail')][string]$DownloadMode = 'match',
        [ValidateSet('success', 'server-error')][string]$ApiMode = 'success',
        [object[]]$OtherReleases = @(),
        [AllowNull()]$DuplicateRelease = $null,
        [ValidateRange(1, 100)][int]$PageSize = 100,
        [bool]$ChangeIdAfterUpload = $false,
        [bool]$ReplaceBeforeUpload = $false,
        [bool]$ReplaceBeforeFinalize = $false,
        [bool]$FinalImmutable = $true,
        [ValidateRange(0, 6)][int]$ImmutableAfterReads = 0
    )
    $document = [pscustomobject]@{
        releaseExists = $ReleaseExists
        release = $Release
        uploadMode = $UploadMode
        downloadMode = $DownloadMode
        apiMode = $ApiMode
        otherReleases = @($OtherReleases)
        duplicateRelease = $DuplicateRelease
        pageSize = $PageSize
        changeIdAfterUpload = $ChangeIdAfterUpload
        replaceBeforeUpload = $ReplaceBeforeUpload
        replaceBeforeFinalize = $ReplaceBeforeFinalize
        finalImmutable = $FinalImmutable
        immutableAfterReads = $ImmutableAfterReads
        postFinalizeReadCount = 0
        calls = @()
    }
    [IO.File]::WriteAllText($mockStatePath, ($document | ConvertTo-Json -Depth 10),
        [Text.UTF8Encoding]::new($false))
}

function Read-MockState {
    return (Get-Content -Raw -LiteralPath $mockStatePath -Encoding UTF8 | ConvertFrom-Json)
}

function New-ExistingExperimentalRelease {
    param([object[]]$Assets = @())
    return [pscustomobject]@{
        id = [long]379831902
        tag_name = 'v0.3.0'
        name = 'v0.3.0 Experimental'
        body = 'operator-authored experimental notes'
        draft = $false
        prerelease = $true
        immutable = $true
        assets = @($Assets)
    }
}

function New-ExistingDraftRelease {
    param([object[]]$Assets = @(), [bool]$Immutable = $false)
    return [pscustomobject]@{
        id = [long]379831902
        tag_name = 'v0.3.0'
        name = 'v0.3.0 recovery draft'
        body = ''
        draft = $true
        prerelease = $false
        immutable = $Immutable
        assets = @($Assets)
    }
}

function New-UnrelatedRelease {
    param([Parameter(Mandatory = $true)][int]$Index)
    return [pscustomobject]@{
        id = [long](1000 + $Index)
        tag_name = "v1.0.$Index"
        name = "unrelated $Index"
        body = 'unrelated fixture'
        draft = $false
        prerelease = $false
        immutable = $true
        assets = @()
    }
}

function Invoke-TestPublisher {
    param(
        [long]$ExpectedReleaseId = -1,
        [string[]]$ExpectedAssetNames = @($assetInfo.Name)
    )
    $parameters = @{
        AssetsDirectory = $assetsDirectory
        Tag = 'v0.3.0'
        Repository = 'owner/repository'
        ExpectedAssetNames = $ExpectedAssetNames
        Title = 'FFB Interceptor v0.3.0 Stable'
        NotesPath = $notesPath
    }
    if ($ExpectedReleaseId -ge 0) {
        $parameters.ExpectedReleaseId = $ExpectedReleaseId
    }
    & $publishScript @parameters
}

function Test-MockCall {
    param($Call, [string]$First, [string]$Second)
    $callArguments = @($Call.arguments)
    return $callArguments.Count -ge 2 -and $callArguments[0] -ceq $First -and
        $callArguments[1] -ceq $Second
}

function Test-MockFinalizeCall {
    param($Call)
    $callArguments = @($Call.arguments)
    return $callArguments.Count -ge 5 -and $callArguments[0] -ceq 'api' -and
        (Get-GhMockOptionValue -Values $callArguments -Name '--method') -ceq 'PATCH' -and
        $callArguments[-1] -match '^repos/owner/repository/releases/[1-9]\d*\z'
}

function Test-MockUploadCall {
    param($Call)
    $callArguments = @($Call.arguments)
    return $callArguments.Count -ge 5 -and $callArguments[0] -ceq 'api' -and
        (Get-GhMockOptionValue -Values $callArguments -Name '--method') -ceq 'POST' -and
        $callArguments[-1] -match '^https://uploads\.github\.com/repos/owner/repository/releases/[1-9]\d*/assets\?name=[A-Za-z0-9._-]+\z'
}

function Assert-NoMetadataEdit {
    param([Parameter(Mandatory = $true)]$State)
    $edits = @($State.calls | Where-Object { Test-MockFinalizeCall -Call $_ })
    if ($edits.Count -ne 0) { throw 'release metadata was edited before asset publication succeeded' }
}

function Assert-NoReleaseMutation {
    param([Parameter(Mandatory = $true)]$State)
    $mutations = @($State.calls | Where-Object {
        (Test-MockCall -Call $_ -First 'release' -Second 'create') -or
            (Test-MockUploadCall -Call $_) -or
            (Test-MockFinalizeCall -Call $_)
    })
    if ($mutations.Count -ne 0) { throw 'publisher mutated release state after a failed gate' }
}

function Assert-ExperimentalMetadataUnchanged {
    param([Parameter(Mandatory = $true)]$State)
    if ([string]$State.release.name -cne 'v0.3.0 Experimental' -or
        [string]$State.release.body -cne 'operator-authored experimental notes' -or
        -not [bool]$State.release.prerelease -or [bool]$State.release.draft) {
        throw 'existing Experimental release metadata changed during a failed asset operation'
    }
}

# Keep bounded immutable-readback fixtures fast while still proving the exact
# retry count. The publisher resolves this test-scope function before cmdlets.
$global:FFBReleaseSleepCalls = 0
function Start-Sleep {
    param([Parameter(Mandatory = $true)][int]$Seconds)
    if ($Seconds -ne 2) { throw "Unexpected publisher retry delay: $Seconds" }
    $global:FFBReleaseSleepCalls++
}

$oldRunnerTemp = $env:RUNNER_TEMP
$oldGhToken = $env:GH_TOKEN
try {
    $env:RUNNER_TEMP = $contractRoot
    $env:GH_TOKEN = 'offline-release-contract-token'
    $resolvedGh = Get-Command -Name gh -CommandType Function -ErrorAction Stop
    if ($resolvedGh.Name -cne 'gh') {
        throw 'offline gh contract double was not available to the publisher'
    }

    # The trusted workflow contract must provide the exact local asset set;
    # an older tag build cannot silently publish an extra or missing file.
    Write-MockState -ReleaseExists $false -Release $null -UploadMode success
    $localSetFailure = $null
    try {
        Invoke-TestPublisher -ExpectedReleaseId 0 -ExpectedAssetNames @('different-asset.zip')
    }
    catch { $localSetFailure = $_.Exception.Message }
    if ($localSetFailure -notmatch 'unexpected asset') {
        throw "publisher local expected-asset mismatch was not rejected: $localSetFailure"
    }
    Assert-NoReleaseMutation -State (Read-MockState)

    # A releases-list API failure must fail before any mutation.
    Write-MockState -ReleaseExists $false -Release $null -UploadMode success `
        -ApiMode server-error
    $apiFailure = $null
    try { Invoke-TestPublisher } catch { $apiFailure = $_.Exception.Message }
    if ($apiFailure -notmatch 'list query failed') {
        throw "publisher API failure was not rejected: $apiFailure"
    }
    Assert-NoReleaseMutation -State (Read-MockState)

    # Exact tag matches must be unique across every slurped page.
    $otherReleases = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt 99; $index++) {
        $otherReleases.Add((New-UnrelatedRelease -Index $index))
    }
    $duplicateRelease = New-ExistingDraftRelease
    $duplicateRelease.id = [long]379831903
    Write-MockState -ReleaseExists $true -Release (New-ExistingDraftRelease) `
        -UploadMode success -OtherReleases @($otherReleases) `
        -DuplicateRelease $duplicateRelease
    $duplicateFailure = $null
    try { Invoke-TestPublisher -ExpectedReleaseId 379831902 }
    catch { $duplicateFailure = $_.Exception.Message }
    if ($duplicateFailure -notmatch 'multiple releases for exact tag') {
        throw "duplicate page-two release was not rejected: $duplicateFailure"
    }
    Assert-NoReleaseMutation -State (Read-MockState)

    # Explicit zero means preflight observed no release. It must not adopt a
    # draft that appeared between preflight and publisher startup.
    Write-MockState -ReleaseExists $true -Release (New-ExistingDraftRelease) `
        -UploadMode success
    $slotRaceFailure = $null
    try { Invoke-TestPublisher -ExpectedReleaseId 0 }
    catch { $slotRaceFailure = $_.Exception.Message }
    if ($slotRaceFailure -notmatch 'appeared after preflight') {
        throw "explicit-zero publication-slot race was not rejected: $slotRaceFailure"
    }
    Assert-NoReleaseMutation -State (Read-MockState)

    # A positive preflight ID is mandatory and cannot silently rebind.
    Write-MockState -ReleaseExists $false -Release $null -UploadMode success
    $missingPinnedFailure = $null
    try { Invoke-TestPublisher -ExpectedReleaseId 379831902 }
    catch { $missingPinnedFailure = $_.Exception.Message }
    if ($missingPinnedFailure -notmatch 'Pinned release 379831902.*disappeared') {
        throw "missing pinned release was not rejected: $missingPinnedFailure"
    }
    Assert-NoReleaseMutation -State (Read-MockState)

    $changedPinnedRelease = New-ExistingDraftRelease
    $changedPinnedRelease.id = [long]379831903
    Write-MockState -ReleaseExists $true -Release $changedPinnedRelease -UploadMode success
    $changedPinnedFailure = $null
    try { Invoke-TestPublisher -ExpectedReleaseId 379831902 }
    catch { $changedPinnedFailure = $_.Exception.Message }
    if ($changedPinnedFailure -notmatch 'Pinned release ID changed') {
        throw "changed pinned release was not rejected: $changedPinnedFailure"
    }
    Assert-NoReleaseMutation -State (Read-MockState)

    # Impossible draft+immutable state is rejected before mutation.
    Write-MockState -ReleaseExists $true `
        -Release (New-ExistingDraftRelease -Immutable $true) -UploadMode success
    $immutableDraftFailure = $null
    try { Invoke-TestPublisher -ExpectedReleaseId 379831902 }
    catch { $immutableDraftFailure = $_.Exception.Message }
    if ($immutableDraftFailure -notmatch 'both draft and immutable') {
        throw "immutable draft was not rejected: $immutableDraftFailure"
    }
    Assert-NoReleaseMutation -State (Read-MockState)

    $wrongSizeAsset = [pscustomobject]@{
        name = $assetInfo.Name
        size = [long]$assetInfo.Length + 1
        digest = $assetDigest
    }
    Write-MockState -ReleaseExists $true `
        -Release (New-ExistingExperimentalRelease -Assets @($wrongSizeAsset)) `
        -UploadMode success
    $sizeFailure = $null
    try { Invoke-TestPublisher } catch { $sizeFailure = $_.Exception.Message }
    if ($sizeFailure -notmatch 'differs in size') {
        throw "same-name immutable asset size mismatch was not rejected: $sizeFailure"
    }
    $state = Read-MockState
    Assert-NoReleaseMutation -State $state
    Assert-ExperimentalMetadataUnchanged -State $state

    $matchingAsset = [pscustomobject]@{
        name = $assetInfo.Name
        size = [long]$assetInfo.Length
        digest = $assetDigest
    }
    Write-MockState -ReleaseExists $true `
        -Release (New-ExistingExperimentalRelease -Assets @($matchingAsset, $matchingAsset)) `
        -UploadMode success
    $duplicateAssetFailure = $null
    try { Invoke-TestPublisher } catch { $duplicateAssetFailure = $_.Exception.Message }
    if ($duplicateAssetFailure -notmatch 'duplicate asset names') {
        throw "duplicate remote asset names were not rejected: $duplicateAssetFailure"
    }
    $state = Read-MockState
    Assert-NoReleaseMutation -State $state
    Assert-ExperimentalMetadataUnchanged -State $state

    # Older assets may not expose a digest. The fallback download must compare
    # actual content and reject a same-name/same-size document whose bytes differ.
    $digestlessAsset = [pscustomobject]@{
        name = $assetInfo.Name
        size = [long]$assetInfo.Length
    }
    Write-MockState -ReleaseExists $true `
        -Release (New-ExistingExperimentalRelease -Assets @($digestlessAsset)) `
        -UploadMode success -DownloadMode mismatch
    $fallbackFailure = $null
    try { Invoke-TestPublisher } catch { $fallbackFailure = $_.Exception.Message }
    if ($fallbackFailure -notmatch 'differs in content') {
        throw "digestless remote asset content mismatch was not rejected: $fallbackFailure"
    }
    $state = Read-MockState
    Assert-NoReleaseMutation -State $state
    Assert-ExperimentalMetadataUnchanged -State $state

    # Same name/size but different digest on an immutable published release
    # must fail without trying to mutate it.
    $differentAsset = [pscustomobject]@{
        name = $assetInfo.Name
        size = [long]$assetInfo.Length
        digest = 'sha256:' + ('0' * 64)
    }
    Write-MockState -ReleaseExists $true `
        -Release (New-ExistingExperimentalRelease -Assets @($differentAsset)) `
        -UploadMode success
    $digestFailure = $null
    try { Invoke-TestPublisher } catch { $digestFailure = $_.Exception.Message }
    if ($digestFailure -notmatch 'differs in digest') {
        throw 'same-name immutable asset mismatch was not rejected'
    }
    $state = Read-MockState
    Assert-NoReleaseMutation -State $state
    Assert-ExperimentalMetadataUnchanged -State $state

    $unexpectedAsset = [pscustomobject]@{
        name = 'stale-build.zip'
        size = 1
        digest = 'sha256:' + ('1' * 64)
    }
    Write-MockState -ReleaseExists $true `
        -Release (New-ExistingExperimentalRelease -Assets @($unexpectedAsset)) `
        -UploadMode success
    $unexpectedFailure = $null
    try { Invoke-TestPublisher } catch { $unexpectedFailure = $_.Exception.Message }
    if ($unexpectedFailure -notmatch 'unexpected immutable asset') {
        throw 'unexpected immutable release asset was not rejected'
    }
    $state = Read-MockState
    Assert-NoReleaseMutation -State $state
    Assert-ExperimentalMetadataUnchanged -State $state

    # Raw numeric-ID uploads deliberately require an explicit workflow token;
    # they never fall back to ambient keyring authentication.
    Write-MockState -ReleaseExists $true -Release (New-ExistingDraftRelease) `
        -UploadMode success
    $env:GH_TOKEN = ''
    $missingTokenFailure = $null
    try { Invoke-TestPublisher -ExpectedReleaseId 379831902 }
    catch { $missingTokenFailure = $_.Exception.Message }
    finally { $env:GH_TOKEN = 'offline-release-contract-token' }
    if ($missingTokenFailure -notmatch 'GH_TOKEN is required') {
        throw "numeric-ID upload accepted a missing GH_TOKEN: $missingTokenFailure"
    }
    Assert-NoReleaseMutation -State (Read-MockState)

    # Recovery operates only on a private mutable draft. Failed or dropped
    # uploads must leave it private and must never finalize metadata.
    Write-MockState -ReleaseExists $true -Release (New-ExistingDraftRelease) `
        -UploadMode fail
    $uploadFailure = $null
    try { Invoke-TestPublisher -ExpectedReleaseId 379831902 }
    catch { $uploadFailure = $_.Exception.Message }
    if ($uploadFailure -notmatch 'Unable to upload') { throw 'failed upload was not rejected' }
    $state = Read-MockState
    Assert-NoMetadataEdit -State $state
    if (-not [bool]$state.release.draft) { throw 'failed recovery draft was published' }

    Write-MockState -ReleaseExists $true -Release (New-ExistingDraftRelease) `
        -UploadMode drop
    $verificationFailure = $null
    try { Invoke-TestPublisher -ExpectedReleaseId 379831902 }
    catch { $verificationFailure = $_.Exception.Message }
    if ($verificationFailure -notmatch 'still missing') {
        throw 'post-upload missing-asset verification was not enforced'
    }
    $state = Read-MockState
    Assert-NoMetadataEdit -State $state
    if (-not [bool]$state.release.draft) { throw 'unverified recovery draft was published' }

    # Numeric-ID upload must not follow a tag that is deleted and recreated
    # after the pinned draft read. The replacement remains untouched/private.
    Write-MockState -ReleaseExists $true -Release (New-ExistingDraftRelease) `
        -UploadMode success -ReplaceBeforeUpload $true
    $preUploadReplaceFailure = $null
    try { Invoke-TestPublisher -ExpectedReleaseId 379831902 }
    catch { $preUploadReplaceFailure = $_.Exception.Message }
    if ($preUploadReplaceFailure -notmatch 'Unable to upload') {
        throw "pre-upload tag replacement was not rejected: $preUploadReplaceFailure"
    }
    $state = Read-MockState
    $numericUploadCalls = @($state.calls | Where-Object { Test-MockUploadCall -Call $_ })
    if ($numericUploadCalls.Count -ne 1 -or
        @($numericUploadCalls[0].arguments)[-1] -notmatch '/releases/379831902/assets\?' -or
        [long]$state.release.id -eq 379831902 -or @($state.release.assets).Count -ne 0 -or
        -not [bool]$state.release.draft) {
        throw 'numeric-ID upload mutated or rebound to the replacement release'
    }
    Assert-NoMetadataEdit -State $state

    # Replacing the release ID after an upload is detected before metadata
    # finalization, even though the upload command itself succeeded.
    Write-MockState -ReleaseExists $true -Release (New-ExistingDraftRelease) `
        -UploadMode success -ChangeIdAfterUpload $true
    $postUploadIdFailure = $null
    try { Invoke-TestPublisher -ExpectedReleaseId 379831902 }
    catch { $postUploadIdFailure = $_.Exception.Message }
    if ($postUploadIdFailure -notmatch 'Pinned release ID changed') {
        throw "post-upload release ID change was not rejected: $postUploadIdFailure"
    }
    $state = Read-MockState
    Assert-NoMetadataEdit -State $state
    if (-not [bool]$state.release.draft) { throw 'changed-ID recovery draft was published' }

    # If the tag is deleted/recreated after the final pinned read but before
    # publication, numeric-ID PATCH targets the vanished old release and must
    # not publish the replacement draft.
    Write-MockState -ReleaseExists $true -Release (New-ExistingDraftRelease) `
        -UploadMode success -ReplaceBeforeFinalize $true
    $preFinalizeReplaceFailure = $null
    try { Invoke-TestPublisher -ExpectedReleaseId 379831902 }
    catch { $preFinalizeReplaceFailure = $_.Exception.Message }
    if ($preFinalizeReplaceFailure -notmatch 'Unable to finalize') {
        throw "pre-finalize tag replacement was not rejected: $preFinalizeReplaceFailure"
    }
    $state = Read-MockState
    if (-not [bool]$state.release.draft -or [bool]$state.release.immutable -or
        [long]$state.release.id -eq 379831902) {
        throw 'numeric-ID finalization published the replacement release'
    }

    # The selected recovery draft may live on page two. A differently-cased
    # tag on page one must not shadow the canonical exact match.
    $otherReleases = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt 100; $index++) {
        $otherReleases.Add((New-UnrelatedRelease -Index $index))
    }
    $otherReleases[0].tag_name = 'V0.3.0'
    Write-MockState -ReleaseExists $true -Release (New-ExistingDraftRelease) `
        -UploadMode success -OtherReleases @($otherReleases)
    Invoke-TestPublisher -ExpectedReleaseId 379831902
    $state = Read-MockState
    $pageTwoMutations = @($state.calls | Where-Object {
        (Test-MockUploadCall -Call $_) -or
            (Test-MockFinalizeCall -Call $_)
    })
    if ($pageTwoMutations.Count -ne 2 -or [bool]$state.release.draft -or
        -not [bool]$state.release.immutable) {
        throw 'page-two pinned recovery draft was not published exactly once'
    }

    # A partial multi-asset draft keeps an exact matching asset and uploads
    # only the missing file before the single metadata finalization.
    $secondAssetName = 'FFB-v0.3.0-symbols.zip'
    $secondAssetPath = Join-Path $assetsDirectory $secondAssetName
    [IO.File]::WriteAllText($secondAssetPath, 'second-immutable-release-content',
        [Text.UTF8Encoding]::new($false))
    try {
        Write-MockState -ReleaseExists $true `
            -Release (New-ExistingDraftRelease -Assets @($matchingAsset)) `
            -UploadMode success
        Invoke-TestPublisher -ExpectedReleaseId 379831902 `
            -ExpectedAssetNames @($assetInfo.Name, $secondAssetName)
        $state = Read-MockState
        $partialUploads = @($state.calls | Where-Object { Test-MockUploadCall -Call $_ })
        $partialEdits = @($state.calls | Where-Object { Test-MockFinalizeCall -Call $_ })
        if ($partialUploads.Count -ne 1 -or $partialEdits.Count -ne 1 -or
            @($state.release.assets).Count -ne 2 -or [bool]$state.release.draft -or
            -not [bool]$state.release.immutable) {
            throw 'partial multi-asset draft did not upload only its missing exact asset'
        }
    }
    finally {
        if (Test-Path -LiteralPath $secondAssetPath) {
            Remove-Item -LiteralPath $secondAssetPath -Force
        }
    }

    # Explicit zero may create a draft only while the slot is still absent.
    # Upload failure keeps the new release private.
    Write-MockState -ReleaseExists $false -Release $null -UploadMode fail
    $newUploadFailure = $null
    try { Invoke-TestPublisher -ExpectedReleaseId 0 }
    catch { $newUploadFailure = $_.Exception.Message }
    if ($newUploadFailure -notmatch 'Unable to upload') {
        throw 'new-release upload failure was not rejected'
    }
    $state = Read-MockState
    if (-not [bool]$state.releaseExists -or -not [bool]$state.release.draft) {
        throw 'failed new release was exposed instead of remaining a draft'
    }
    Assert-NoMetadataEdit -State $state

    # If publication does not become immutable, bounded readback fails after
    # the sole edit and never attempts another public mutation.
    $global:FFBReleaseSleepCalls = 0
    Write-MockState -ReleaseExists $false -Release $null -UploadMode success `
        -FinalImmutable $false
    $finalImmutableFailure = $null
    try { Invoke-TestPublisher -ExpectedReleaseId 0 }
    catch { $finalImmutableFailure = $_.Exception.Message }
    if ($finalImmutableFailure -notmatch 'did not become immutable') {
        throw "non-immutable final release was not rejected: $finalImmutableFailure"
    }
    $state = Read-MockState
    $finalEdits = @($state.calls | Where-Object {
        Test-MockFinalizeCall -Call $_
    })
    if ($finalEdits.Count -ne 1 -or [bool]$state.release.draft -or
        [bool]$state.release.immutable -or $global:FFBReleaseSleepCalls -ne 5) {
        throw 'final immutable readback was not bounded or attempted another mutation'
    }

    # A short propagation delay is tolerated: only readback is retried and the
    # published release becomes successful without a second metadata mutation.
    $global:FFBReleaseSleepCalls = 0
    Write-MockState -ReleaseExists $false -Release $null -UploadMode success `
        -FinalImmutable $false -ImmutableAfterReads 3
    Invoke-TestPublisher -ExpectedReleaseId 0
    $state = Read-MockState
    $delayedEdits = @($state.calls | Where-Object { Test-MockFinalizeCall -Call $_ })
    if ($delayedEdits.Count -ne 1 -or -not [bool]$state.release.immutable -or
        $global:FFBReleaseSleepCalls -ne 2 -or [int]$state.postFinalizeReadCount -ne 3) {
        throw 'delayed immutable readback did not converge through bounded read-only retries'
    }

    # Successful absent-slot publication performs create, upload, and one
    # final metadata edit in order, then verifies the immutable readback.
    Write-MockState -ReleaseExists $false -Release $null -UploadMode success
    Invoke-TestPublisher -ExpectedReleaseId 0
    $state = Read-MockState
    $mutations = @($state.calls | Where-Object {
        (Test-MockCall -Call $_ -First 'release' -Second 'create') -or
            (Test-MockUploadCall -Call $_) -or
            (Test-MockFinalizeCall -Call $_)
    })
    if ($mutations.Count -ne 3 -or
        -not (Test-MockCall -Call $mutations[0] -First 'release' -Second 'create') -or
        -not (Test-MockUploadCall -Call $mutations[1]) -or
        -not (Test-MockFinalizeCall -Call $mutations[2])) {
        throw 'release mutations did not occur in draft-create, asset-upload, metadata-finalize order'
    }
    $expectedReleaseBody = "<!-- ffb-generated:start -->`n" +
        "Release v0.3.0`nVersion 0.3.0`n" +
        "UNSIGNED EXPERIMENTAL - command telemetry only; not motor torque.`n" +
        '<!-- ffb-generated:end -->'
    if ([bool]$state.release.draft -or [bool]$state.release.prerelease -or
        -not [bool]$state.release.immutable -or
        [string]$state.release.name -cne 'FFB Interceptor v0.3.0 Stable' -or
        [string]$state.release.body -cne $expectedReleaseBody -or
        @($state.release.assets).Count -ne 1 -or
        [string]$state.release.assets[0].digest -cne $assetDigest) {
        throw 'verified draft was not finalized with the expected immutable state'
    }

    # Unbound/manual invocation may treat the exact immutable public state as
    # idempotent. The same state with a positive preflight recovery ID must be
    # rejected because positive IDs promise a still-mutable private draft.
    $exactPublishedRelease = $state.release
    Write-MockState -ReleaseExists $true -Release $exactPublishedRelease -UploadMode success
    Invoke-TestPublisher
    Assert-NoReleaseMutation -State (Read-MockState)

    Write-MockState -ReleaseExists $true -Release $exactPublishedRelease -UploadMode success
    $publishedRecoveryFailure = $null
    try { Invoke-TestPublisher -ExpectedReleaseId 379831902 }
    catch { $publishedRecoveryFailure = $_.Exception.Message }
    if ($publishedRecoveryFailure -notmatch 'already published') {
        throw "published pinned recovery was not rejected: $publishedRecoveryFailure"
    }
    Assert-NoReleaseMutation -State (Read-MockState)
}
finally {
    $env:RUNNER_TEMP = $oldRunnerTemp
    $env:GH_TOKEN = $oldGhToken
    if ($contractRoot.StartsWith($systemTempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $contractRoot)) {
        Remove-Item -LiteralPath $contractRoot -Recurse -Force
    }
}

Write-Host 'PASS release and coverage gate fixtures'
