# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StableManagerPath,
    [Parameter(Mandatory = $true)][string]$ExperimentalManagerPath,
    [Parameter(Mandatory = $true)][string]$ExpectedSigner,
    [string]$PolicyScriptPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if ([string]::IsNullOrWhiteSpace($PolicyScriptPath)) {
    $PolicyScriptPath = Join-Path $root 'simhub\tools\Test-ManagerBuildPolicy.ps1'
}
$policyScript = (Resolve-Path -LiteralPath $PolicyScriptPath -ErrorAction Stop).Path
$stableManager = (Resolve-Path -LiteralPath $StableManagerPath -ErrorAction Stop).Path
$experimentalManager = (Resolve-Path -LiteralPath $ExperimentalManagerPath -ErrorAction Stop).Path
if ($ExpectedSigner -cnotmatch '\A[A-F0-9]{64}\z') {
    throw 'ExpectedSigner must be exactly 64 uppercase hexadecimal characters.'
}

$testRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) `
    ('ffb-manager-policy-test-' + [Guid]::NewGuid().ToString('N'))))
$systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not $testRoot.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -or
    -not [IO.Path]::GetFileName($testRoot).StartsWith('ffb-manager-policy-test-',
        [StringComparison]::Ordinal)) {
    throw "Unsafe Manager policy test path: $testRoot"
}

function Join-FFBByteArrays {
    param(
        [Parameter(Mandatory = $true)][byte[]]$First,
        [Parameter(Mandatory = $true)][byte[]]$Second
    )
    [long]$longLength = [long]$First.LongLength + [long]$Second.LongLength
    if ($longLength -le 0 -or $longLength -gt [int]::MaxValue) {
        throw "Combined Manager policy fixture has an invalid size: $longLength"
    }
    [int]$length = $longLength
    $combined = New-Object byte[] $length
    [Buffer]::BlockCopy($First, 0, $combined, 0, $First.Length)
    [Buffer]::BlockCopy($Second, 0, $combined, $First.Length, $Second.Length)
    return ,$combined
}

function Assert-FFBPolicyRejected {
    param(
        [Parameter(Mandatory = $true)][string]$CandidatePath,
        [Parameter(Mandatory = $true)][string]$CaseName,
        [Parameter(Mandatory = $true)][string]$ExpectedMessagePattern
    )
    $message = ''
    try {
        & $policyScript -ManagerPath $CandidatePath | Out-Null
    }
    catch {
        $message = $_.Exception.Message
    }
    if ([string]::IsNullOrEmpty($message)) {
        throw "$CaseName was accepted by the stable Manager policy validator."
    }
    if ($message -notmatch $ExpectedMessagePattern) {
        throw "$CaseName was rejected for an unexpected reason: $message"
    }
}

try {
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null

    $stableSigner = @(& $policyScript -ManagerPath $stableManager)
    if ($stableSigner.Count -ne 1 -or [string]$stableSigner[0] -cne $ExpectedSigner) {
        throw "Stable Manager signer mismatch. Expected $ExpectedSigner; got $($stableSigner -join ', ')."
    }

    Assert-FFBPolicyRejected -CandidatePath $experimentalManager `
        -CaseName 'Experimental Manager' `
        -ExpectedMessagePattern 'missing, malformed, unpinned, or not NUL-terminated'

    $markerText = 'FFB_MANAGER_BUILD_POLICY_V1|MODE=STABLE|SIGNER_SHA256=' +
        $ExpectedSigner + '|END' + [char]0
    $markerBytes = [Text.Encoding]::ASCII.GetBytes($markerText)
    $stableBytes = [IO.File]::ReadAllBytes($stableManager)
    $stableAscii = [Text.Encoding]::ASCII.GetString($stableBytes)
    $markerOffset = $stableAscii.IndexOf($markerText, [StringComparison]::Ordinal)
    if ($markerOffset -lt 0 -or
        $stableAscii.IndexOf($markerText, $markerOffset + 1,
            [StringComparison]::Ordinal) -ge 0) {
        throw 'Stable Manager fixture must contain exactly one expected build-policy marker.'
    }

    # Preserve the project-built PE structure, erase its mapped marker, then put
    # the only valid marker in the file overlay. The candidate is never loaded.
    [byte[]]$withoutMappedMarker = $stableBytes.Clone()
    for ($index = 0; $index -lt $markerBytes.Length; $index++) {
        $withoutMappedMarker[$markerOffset + $index] = 0x58
    }
    $overlayOnlyPath = Join-Path $testRoot 'overlay-only.exe'
    [byte[]]$overlayOnlyBytes = Join-FFBByteArrays `
        -First $withoutMappedMarker -Second $markerBytes
    [IO.File]::WriteAllBytes($overlayOnlyPath, $overlayOnlyBytes)
    Assert-FFBPolicyRejected -CandidatePath $overlayOnlyPath `
        -CaseName 'Overlay-only marker fixture' `
        -ExpectedMessagePattern 'not contained in exactly one PE section'

    $duplicatePath = Join-Path $testRoot 'duplicate-marker.exe'
    [byte[]]$duplicateBytes = Join-FFBByteArrays -First $stableBytes -Second $markerBytes
    [IO.File]::WriteAllBytes($duplicatePath, $duplicateBytes)
    Assert-FFBPolicyRejected -CandidatePath $duplicatePath `
        -CaseName 'Duplicate marker fixture' `
        -ExpectedMessagePattern 'must contain exactly one build-policy marker; found 2'

    Write-Host 'PASS stable Manager build-policy fixtures'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
