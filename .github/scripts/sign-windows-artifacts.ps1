# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Paths,
    [string]$CertificateThumbprint = $env:FFB_SIGNING_CERT_SHA1,
    [string]$TimestampUrl = 'http://timestamp.digicert.com',
    [switch]$RequireSigning
)

$ErrorActionPreference = 'Stop'
$files = @($Paths | ForEach-Object { (Resolve-Path -LiteralPath $_ -ErrorAction Stop).Path } |
    Sort-Object -Unique)
if ($files.Count -eq 0) { throw 'No signing targets were provided' }
if ([string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
    if ($RequireSigning) { throw 'Stable release signing is required, but FFB_SIGNING_CERT_SHA1 is unavailable' }
    Write-Warning 'No code-signing certificate configured; artifacts remain UNSIGNED EXPERIMENTAL.'
    return
}
$thumbprint = ($CertificateThumbprint -replace '\s', '').ToUpperInvariant()
if ($thumbprint -notmatch '^[A-F0-9]{40}$') { throw 'Certificate thumbprint must be 40 hexadecimal characters' }

$certificate = Get-ChildItem -LiteralPath "Cert:\CurrentUser\My\$thumbprint" -ErrorAction SilentlyContinue
$machineStore = $false
if (-not $certificate) {
    $certificate = Get-ChildItem -LiteralPath "Cert:\LocalMachine\My\$thumbprint" -ErrorAction SilentlyContinue
    $machineStore = $true
}
if (-not $certificate -or -not $certificate.HasPrivateKey) {
    throw "Code-signing certificate $thumbprint with private key was not found"
}
$now = Get-Date
if ($now -lt $certificate.NotBefore -or $now -ge $certificate.NotAfter) {
    throw "Code-signing certificate $thumbprint is outside its validity period"
}
if (-not @($certificate.EnhancedKeyUsageList | Where-Object {
    [string]$_.ObjectId -eq '1.3.6.1.5.5.7.3.3'
})) { throw "Certificate $thumbprint is not valid for code signing" }

$kitRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
$signTool = Get-ChildItem -LiteralPath $kitRoot -Filter 'signtool.exe' -Recurse -ErrorAction Stop |
    Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' } |
    Sort-Object { [version]$_.Directory.Parent.Name } -Descending |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $signTool) { throw 'Windows SDK x64 signtool.exe was not found' }

foreach ($file in $files) {
    $extension = [IO.Path]::GetExtension($file).ToLowerInvariant()
    if ($extension -eq '.ps1') {
        $parameters = @{ FilePath = $file; Certificate = $certificate; HashAlgorithm = 'SHA256' }
        if ($TimestampUrl) { $parameters.TimestampServer = $TimestampUrl }
        $signature = Set-AuthenticodeSignature @parameters
        if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid) {
            throw "PowerShell Authenticode signing failed for $file : $($signature.StatusMessage)"
        }
        continue
    }
    if ($extension -notin @('.exe', '.dll')) { throw "Unsupported signing target: $file" }
    $arguments = @('sign', '/fd', 'SHA256', '/sha1', $thumbprint, '/s', 'My')
    if ($machineStore) { $arguments += '/sm' }
    if ($TimestampUrl) { $arguments += @('/tr', $TimestampUrl, '/td', 'SHA256') }
    $arguments += $file
    & $signTool @arguments
    if ($LASTEXITCODE -ne 0) { throw "signtool signing failed for $file" }
    & $signTool verify /pa /all $file
    if ($LASTEXITCODE -ne 0) { throw "Authenticode verification failed for $file" }
}
Write-Host "Authenticode signed and verified $($files.Count) artifact(s) with $thumbprint"
