# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [string]$PfxBase64 = $env:FFB_SIGNING_PFX_BASE64,
    [string]$PfxPassword = $env:FFB_SIGNING_PFX_PASSWORD,
    [string]$ExpectedSignerSha256 = $env:FFB_EXPECTED_SIGNER_SHA256,
    [switch]$RequireSigning
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($PfxBase64)) {
    if ($RequireSigning) { throw 'Stable release signing requires the PFX secret.' }
    Write-Warning 'No signing PFX was supplied; continuing as UNSIGNED EXPERIMENTAL.'
    return
}
if ($RequireSigning -and [string]::IsNullOrWhiteSpace($PfxPassword)) {
    throw 'Stable release signing requires a non-empty PFX password secret.'
}
if ($RequireSigning -and $ExpectedSignerSha256 -cnotmatch '^[A-F0-9]{64}\z') {
    throw 'Stable release signing requires an exact 64-character uppercase signer SHA-256 pin.'
}
if ($PfxBase64.Length -gt 4194304) { throw 'Signing PFX secret is unexpectedly large.' }

try { $bytes = [Convert]::FromBase64String($PfxBase64) }
catch { throw 'Signing PFX secret is not valid base64.' }
if ($bytes.Length -eq 0 -or $bytes.Length -gt 3145728) { throw 'Signing PFX payload has an invalid size.' }

$password = if ([string]::IsNullOrEmpty($PfxPassword)) {
    [Security.SecureString]::new()
} else {
    ConvertTo-SecureString -String $PfxPassword -AsPlainText -Force
}
$ephemeral = [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
$collection = [Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
$trackedThumbprints = [Collections.Generic.List[string]]::new()

function Remove-TrackedSigningCertificates {
    param([Collections.Generic.List[string]]$Thumbprints)

    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($thumbprint in $Thumbprints) {
        if ($thumbprint -cnotmatch '^[A-F0-9]{40}\z' -or -not $seen.Add($thumbprint)) {
            throw 'Refusing ambiguous imported-certificate cleanup state.'
        }
    }
    foreach ($thumbprint in $Thumbprints) {
        $certificatePath = "Cert:\CurrentUser\My\$thumbprint"
        if (Test-Path -LiteralPath $certificatePath) {
            Remove-Item -LiteralPath $certificatePath -DeleteKey -Force -ErrorAction Stop
        }
    }
}

try {
    try { $collection.Import($bytes, $PfxPassword, $ephemeral) }
    catch { throw 'Signing PFX could not be opened with the configured password.' }
    $pfxCertificates = @($collection | ForEach-Object { $_ })
    if ($pfxCertificates.Count -eq 0) { throw 'Signing PFX contains no certificates.' }
    $privateKeyIdentities = @($pfxCertificates | Where-Object { $_.HasPrivateKey })
    if ($privateKeyIdentities.Count -ne 1) {
        throw 'Signing PFX must contain exactly one private-key identity.'
    }
    $identity = $privateKeyIdentities[0]
    $sha1 = $identity.Thumbprint.ToUpperInvariant()
    $sha256Algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $sha256 = ([BitConverter]::ToString($sha256Algorithm.ComputeHash($identity.RawData))).Replace('-', '')
    }
    finally { $sha256Algorithm.Dispose() }
    if ($ExpectedSignerSha256) {
        $expected = if ($RequireSigning) {
            $ExpectedSignerSha256
        } else {
            ($ExpectedSignerSha256 -replace '\s', '').ToUpperInvariant()
        }
        if ($expected -notmatch '^[A-F0-9]{64}\z') { throw 'Expected signer SHA-256 must be 64 hexadecimal characters.' }
        if ($sha256 -cne $expected) { throw 'Signing certificate does not match the pinned signer SHA-256.' }
    }
    if (-not @($identity.Extensions | Where-Object {
        $_ -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] -and
        @($_.EnhancedKeyUsages | Where-Object { $_.Value -eq '1.3.6.1.5.5.7.3.3' }).Count -gt 0
    })) { throw 'Signing certificate is not valid for code signing.' }
    $now = Get-Date
    if ($now -lt $identity.NotBefore -or $now -ge $identity.NotAfter) {
        throw 'Signing certificate is outside its validity period.'
    }

    $pfxThumbprints = [Collections.Generic.List[string]]::new()
    $pfxThumbprintSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($certificate in $pfxCertificates) {
        $thumbprint = ([string]$certificate.Thumbprint).ToUpperInvariant()
        if ($thumbprint -cnotmatch '^[A-F0-9]{40}\z' -or -not $pfxThumbprintSet.Add($thumbprint)) {
            throw 'Signing PFX contains an invalid or duplicate certificate thumbprint.'
        }
        $certificatePath = "Cert:\CurrentUser\My\$thumbprint"
        if (Test-Path -LiteralPath $certificatePath) {
            throw "Refusing to reuse a certificate already present in CurrentUser\My: $thumbprint"
        }
        $pfxThumbprints.Add($thumbprint)
    }
    if (-not $env:GITHUB_ENV) {
        throw 'GITHUB_ENV is unavailable; refusing to import signing state ambiguously.'
    }

    $temporarySource = $env:RUNNER_TEMP
    if ([string]::IsNullOrWhiteSpace($temporarySource)) { $temporarySource = [IO.Path]::GetTempPath() }
    $temporaryRoot = [IO.Path]::GetFullPath($temporarySource)
    $pfxPath = [IO.Path]::GetFullPath((Join-Path $temporaryRoot (
        'ffb-signing-' + [Guid]::NewGuid().ToString('N') + '.pfx')))
    if (-not $pfxPath.StartsWith($temporaryRoot.TrimEnd('\') + '\',
        [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unsafe temporary PFX path.'
    }
    try {
        [IO.File]::WriteAllBytes($pfxPath, $bytes)
        foreach ($thumbprint in $pfxThumbprints) { $trackedThumbprints.Add($thumbprint) }
        $importedCertificates = @(Import-PfxCertificate -FilePath $pfxPath `
            -CertStoreLocation 'Cert:\CurrentUser\My' -Password $password -Exportable:$false `
            -ErrorAction Stop)
        foreach ($certificate in $importedCertificates) { $certificate.Dispose() }
    }
    finally {
        if (Test-Path -LiteralPath $pfxPath) { Remove-Item -LiteralPath $pfxPath -Force }
    }

    foreach ($thumbprint in $trackedThumbprints) {
        if (-not (Test-Path -LiteralPath "Cert:\CurrentUser\My\$thumbprint" -PathType Leaf)) {
            throw "Signing PFX certificate was not imported into CurrentUser\My: $thumbprint"
        }
    }
    $existingIdentity = Get-Item -LiteralPath "Cert:\CurrentUser\My\$sha1" -ErrorAction Stop
    if (-not $existingIdentity.HasPrivateKey) { throw 'Imported signing identity has no private key.' }

    @(
        "FFB_SIGNING_CERT_SHA1=$sha1",
        "FFB_SIGNER_SHA256=$sha256",
        "FFB_SIGNING_CERT_THUMBPRINTS=$([string]::Join(',', $trackedThumbprints))",
        'FFB_REMOVE_SIGNING_CERTIFICATE=1'
    ) | Out-File -LiteralPath $env:GITHUB_ENV -Encoding utf8 -Append
    Write-Host "Loaded one signing identity and $($trackedThumbprints.Count) PFX certificate(s); signer SHA-256 $sha256."
}
catch {
    $failure = $_
    if ($trackedThumbprints.Count -gt 0) {
        try { Remove-TrackedSigningCertificates -Thumbprints $trackedThumbprints }
        catch {
            throw "Signing certificate cleanup failed after '$($failure.Exception.Message)': $($_.Exception.Message)"
        }
    }
    throw $failure
}
finally {
    foreach ($certificate in @($collection | ForEach-Object { $_ })) { $certificate.Dispose() }
    $password.Dispose()
    [Array]::Clear($bytes, 0, $bytes.Length)
}
