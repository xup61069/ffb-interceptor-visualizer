# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).Path
$managerPath = Join-Path $root 'launcher\manager_main.cpp'
$modelPath = Join-Path $root 'launcher\manager_model.cpp'
$manager = [IO.File]::ReadAllText($managerPath, [Text.Encoding]::UTF8)
$model = [IO.File]::ReadAllText($modelPath, [Text.Encoding]::UTF8)

function Get-SourceSlice {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Start,
        [Parameter(Mandatory = $true)][string]$End
    )
    $startIndex = $Source.IndexOf($Start, [StringComparison]::Ordinal)
    $endIndex = $Source.IndexOf($End, $startIndex + $Start.Length,
        [StringComparison]::Ordinal)
    if ($startIndex -lt 0 -or $endIndex -le $startIndex) {
        throw "Could not isolate source boundary: $Start -> $End"
    }
    return $Source.Substring($startIndex, $endIndex - $startIndex)
}

function Assert-MarkersInOrder {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string[]]$Markers,
        [Parameter(Mandatory = $true)][string]$Description
    )
    $offset = 0
    foreach ($marker in $Markers) {
        $found = $Source.IndexOf($marker, $offset, [StringComparison]::Ordinal)
        if ($found -lt 0) { throw "$Description is missing or misorders: $marker" }
        $offset = $found + $marker.Length
    }
}

function Set-TestDirectoryAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][Security.AccessControl.DirectorySecurity]$Security
    )
    $extensions = 'System.IO.FileSystemAclExtensions' -as [type]
    if ($null -eq $extensions) {
        [IO.Directory]::SetAccessControl($Path, $Security)
        return
    }
    $method = @($extensions.GetMethods() | Where-Object {
        $_.Name -eq 'SetAccessControl' -and $_.GetParameters().Count -eq 2 -and
        $_.GetParameters()[0].ParameterType -eq [IO.DirectoryInfo]
    })[0]
    [void]$method.Invoke($null, @([IO.DirectoryInfo]::new($Path), $Security))
}

$eventCreation = Get-SourceSlice -Source $manager `
    -Start 'bool create_manager_invocation_event(' `
    -End 'bool build_parameter_text('
foreach ($marker in @(
    'ConvertStringSecurityDescriptorToSecurityDescriptorW',
    '0x00100002;;;AU',
    'BCryptGenRandom',
    'CreateEventExW(',
    'SYNCHRONIZE | EVENT_MODIFY_STATE'
)) {
    if ($eventCreation.IndexOf($marker, [StringComparison]::Ordinal) -lt 0) {
        throw "Cross-token Manager event creation is missing: $marker"
    }
}

$runScript = Get-SourceSlice -Source $manager -Start 'bool run_script(' -End 'bool install_plugin('
Assert-MarkersInOrder -Source $runScript -Description 'Manager package-to-UAC lifecycle' -Markers @(
    'is_installer',
    'is_uninstaller',
    'acquire_package_read_lock',
    'verify_package_integrity',
    'verify_package_signatures',
    'locate_system_windows_powershell',
    'create_manager_invocation_event',
    'L"--elevated-plugin-op"',
    'L"--manager-invocation-event"',
    'run_elevated_process'
)
if ($runScript -notmatch 'run_elevated_process\(\s*window_,\s*executable_path_,\s*system_directory') {
    throw 'Manager does not elevate the already-locked native Manager executable.'
}
if ($runScript -notmatch 'in_doubt_package_lock_\s*=\s*std::move\(package_lock\)') {
    throw 'Manager does not retain the package lock when the elevated process may still run.'
}

$runElevated = Get-SourceSlice -Source $manager -Start 'bool run_elevated_process(' -End 'bool run_process('
foreach ($marker in @(
    'build_parameter_text',
    'launch.lpVerb = L"runas"',
    'launch.lpFile = executable.c_str()',
    'ShellExecuteExW(&launch)',
    'wait_for_elevated_process',
    'invocation_confirmed'
)) {
    if ($runElevated.IndexOf($marker, [StringComparison]::Ordinal) -lt 0) {
        throw "Controlled UAC launcher is missing: $marker"
    }
}
if ($runElevated -match '(?i)\bcmd(?:\.exe)?\b|lpFile\s*=\s*L"powershell\.exe"') {
    throw 'Controlled UAC launcher uses a shell or relative PowerShell lookup.'
}

$helperEntry = Get-SourceSlice -Source $manager `
    -Start 'int run_elevated_plugin_operation(' -End 'bool run_process('
Assert-MarkersInOrder -Source $helperEntry -Description 'Elevated native helper lifecycle' -Markers @(
    'query_current_process_elevation',
    'locate_bundle_root',
    'L"FFBInterceptor.Manager.exe"',
    'OpenEventW',
    'WAIT_TIMEOUT',
    'acquire_package_read_lock',
    'verify_package_integrity',
    'verify_package_signatures',
    'locate_system_windows_powershell',
    'L"-NonInteractive"',
    'L"-ManagerInvocationEvent"',
    'run_sanitized_system_power_shell'
)

$sanitizedLaunch = Get-SourceSlice -Source $manager `
    -Start 'bool run_sanitized_system_power_shell(' -End 'int run_elevated_plugin_operation('
foreach ($marker in @(
    'quote_command_argument',
    'build_sanitized_powershell_environment',
    'CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT',
    'CreateProcessW(',
    'power_shell.c_str()',
    'FALSE, flags, environment.data()',
    'WaitForSingleObject(process.get(), INFINITE)'
)) {
    if ($sanitizedLaunch.IndexOf($marker, [StringComparison]::Ordinal) -lt 0) {
        throw "Sanitized PowerShell launcher is missing: $marker"
    }
}
if ($sanitizedLaunch -match '(?i)\bcmd(?:\.exe)?\b|ShellExecute|GetEnvironmentStrings') {
    throw 'Elevated helper PowerShell launch reaches a shell or inherited environment.'
}

$mainEntry = Get-SourceSlice -Source $manager -Start 'int WINAPI wWinMain(' -End 'HANDLE instance_mutex = CreateMutexW'
Assert-MarkersInOrder -Source $mainEntry -Description 'Pre-GUI elevated helper dispatch' -Markers @(
    'CommandLineToArgvW',
    'parse_elevated_plugin_request',
    'ElevatedPluginParseResult::invalid',
    'ElevatedPluginParseResult::valid',
    'run_elevated_plugin_operation'
)

$helperParser = Get-SourceSlice -Source $model `
    -Start 'ElevatedPluginParseResult parse_elevated_plugin_request(' `
    -End 'std::wstring redact_user_path('
foreach ($marker in @(
    'kElevatedPluginOperationSwitch',
    'arguments.size() == 4 || arguments.size() == 6',
    'kManagerInvocationEventSwitch',
    'manager_invocation_event_name_is_valid',
    'kSimHubInstallPathSwitch',
    'path_is_absolute_local',
    'ElevatedPluginParseResult::invalid'
)) {
    if ($helperParser.IndexOf($marker, [StringComparison]::Ordinal) -lt 0) {
        throw "Strict elevated-helper parser is missing: $marker"
    }
}

$systemPowerShell = Get-SourceSlice -Source $model `
    -Start 'bool locate_system_windows_powershell(' -End 'bool path_is_absolute_local('
Assert-MarkersInOrder -Source $systemPowerShell -Description 'System32 PowerShell resolution' -Markers @(
    'GetSystemDirectoryW',
    'FILE_FLAG_OPEN_REPARSE_POINT',
    'final_path_for_handle',
    'L"WindowsPowerShell\\v1.0\\powershell.exe"',
    'open_regular_file',
    '_wcsicmp(final_executable.c_str(), expected.c_str())'
)

$sanitizedEnvironment = Get-SourceSlice -Source $model `
    -Start 'bool build_sanitized_powershell_environment(' `
    -End 'bool path_is_absolute_local('
foreach ($marker in @(
    'locate_system_windows_powershell',
    'get_windows_directory_path',
    'FOLDERID_Profile',
    'FOLDERID_LocalAppData',
    'FOLDERID_ProgramData',
    'L"SystemRoot"',
    'L"Path"',
    'L"PSModulePath"',
    'environment->push_back(L''\0'')'
)) {
    if ($sanitizedEnvironment.IndexOf($marker, [StringComparison]::Ordinal) -lt 0) {
        throw "Sanitized child environment is missing: $marker"
    }
}
if ($sanitizedEnvironment -match 'GetEnvironment(?:Variable|Strings)|COR_|COMPLUS_|DOTNET_|APPDOMAIN_') {
    throw 'Sanitized child environment copies or names inherited runtime startup controls.'
}

foreach ($relative in @(
    'simhub\launcher-portable\Install-SimHubPlugin.ps1',
    'simhub\launcher-portable\Uninstall-SimHubPlugin.ps1'
)) {
    $path = Join-Path $root $relative
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        throw "PowerShell syntax error in $relative : $($errors[0].Message)"
    }
    $source = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    $boundaryOffset = $source.IndexOf('$packageBoundary =', [StringComparison]::Ordinal)
    if ($boundaryOffset -lt 0) { throw "$relative has no standalone boundary marker." }
    $bootstrap = $source.Substring(0, $boundaryOffset)
    if ($bootstrap.IndexOf('$env:SystemRoot', [StringComparison]::Ordinal) -ge 0) {
        throw "$relative trusts inherited SystemRoot before authenticating the package."
    }
    Assert-MarkersInOrder -Source $source -Description "$relative elevated boundary" -Markers @(
        '$packageBoundary = Enter-FFBStandalonePackageBoundary',
        '[Threading.EventWaitHandle]::OpenExisting',
        '. $commonScript',
        '$managerInvocationHandle.Set()'
    )
    foreach ($marker in @(
        'ManagerInvocationEvent',
        '[IO.Path]::Combine($trustedPSHome, ''powershell.exe'')',
        '$script:PSModuleAutoLoadingPreference = ''None''',
        '$env:PSModulePath = [IO.Path]::Combine($trustedPSHome, ''Modules'')',
        'Microsoft.PowerShell.Management',
        'Microsoft.PowerShell.Utility',
        'Microsoft.PowerShell.Security',
        'Import-Module -Name $trustedModule',
        'Local\\FFBInterceptor\.ManagerElevation\.v1\.',
        '[A-F0-9]{64}',
        '[IO.FileShare]::Read',
        'Get-AuthenticodeSignature',
        'SHA256SUMS.txt'
    )) {
        if ($source.IndexOf($marker, [StringComparison]::Ordinal) -lt 0) {
            throw "$relative is missing controlled boundary marker: $marker"
        }
    }
    if ($source -match '(?i)-Verb\s+RunAs|Invoke-ElevatedSelf|\s-EncodedCommand\s') {
        throw "$relative contains an independent self-elevation path."
    }
}

$commonPath = Join-Path $root 'simhub\launcher-portable\FFBInterceptor.Common.ps1'
$commonSource = [IO.File]::ReadAllText($commonPath, [Text.Encoding]::UTF8)
foreach ($marker in @(
    'DirectoryMutationLock',
    'FileFlagOpenReparsePoint',
    'FileFlagBackupSemantics',
    'FileShareRead | FileShareWrite',
    'GetStableFixedDriveTarget',
    'IsPhysicalVolumeDeviceName',
    'HarddiskVolume[0-9]+$',
    'OpenMutationLease',
    'OpenMutationSentinel',
    'GetFinalPathNameByHandleW',
    'GetIdentity',
    'GetDriveTypeW',
    'QueryDosDeviceW',
    '\\Device\\HarddiskVolume',
    'Enter-FFBSimHubMutationBoundary',
    'Enter-FFBStateMutationBoundary',
    'Exit-FFBSimHubMutationBoundary',
    'if (-not $ReadOnly)',
    'Assert-FFBSimHubRoot -Path $full'
)) {
    if ($commonSource.IndexOf($marker, [StringComparison]::Ordinal) -lt 0) {
        throw "SimHub destination mutation boundary is missing: $marker"
    }
}

foreach ($relative in @(
    'simhub\launcher-portable\Install-SimHubPlugin.ps1',
    'simhub\launcher-portable\Uninstall-SimHubPlugin.ps1'
)) {
    $source = [IO.File]::ReadAllText((Join-Path $root $relative), [Text.Encoding]::UTF8)
    if ($source.IndexOf('-ReadOnly:$WhatIfPreference', [StringComparison]::Ordinal) -lt 0) {
        throw "$relative does not keep WhatIf destination validation read-only."
    }
    if ($relative -like '*Uninstall*') {
        Assert-MarkersInOrder -Source $source -Description "$relative SimHub destination lifecycle" -Markers @(
            '$simHubMutationBoundary = Enter-FFBSimHubMutationBoundary',
            '$stateMutationBoundary = Enter-FFBStateMutationBoundary',
            '$state = Read-FFBPluginState',
            '[IO.File]::Move($destination, $operation.Staged)',
            'Remove-Item -LiteralPath $statePath',
            'Exit-FFBSimHubMutationBoundary -Boundary $stateMutationBoundary',
            'Exit-FFBSimHubMutationBoundary -Boundary $simHubMutationBoundary'
        )
    }
    else {
        Assert-MarkersInOrder -Source $source -Description "$relative SimHub destination lifecycle" -Markers @(
            '$simHubMutationBoundary = Enter-FFBSimHubMutationBoundary',
            '$stateMutationBoundary = Enter-FFBStateMutationBoundary',
            'Install-ManagedFile',
            'Exit-FFBSimHubMutationBoundary -Boundary $stateMutationBoundary',
            'Exit-FFBSimHubMutationBoundary -Boundary $simHubMutationBoundary'
        )
        Assert-MarkersInOrder -Source $source -Description "$relative existing-state destination check" -Markers @(
            '$requestedSimHubPath = Resolve-SimHubPath',
            '$existingState = Read-FFBPluginState -AllowMissing -RequireSimHubExecutable',
            '$stateMutationBoundary = Enter-FFBStateMutationBoundary',
            'different SimHub directory. Uninstall it before switching directories.',
            'already installed and verified'
        )
    }
}

$saveState = $commonSource.Substring($commonSource.IndexOf(
    'function Save-FFBPluginState {', [StringComparison]::Ordinal))
Assert-MarkersInOrder -Source $saveState -Description 'Protected state write lifecycle' -Markers @(
    '$stateBoundary = Enter-FFBStateMutationBoundary -AllowCreate',
    'Set-FFBProtectedDirectoryAcl -Path $directory',
    '[IO.File]::WriteAllText($temporary',
    '[IO.File]::Move($temporary, $path)',
    'Exit-FFBSimHubMutationBoundary -Boundary $stateBoundary'
)

. $commonPath
if ($null -eq ('FFBInterceptor.RawDosDeviceFixture' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace FFBInterceptor
{
    public static class RawDosDeviceFixture
    {
        private const uint RawTarget = 0x00000001;
        private const uint RemoveDefinition = 0x00000002;
        private const uint ExactMatch = 0x00000004;
        private const uint NoBroadcast = 0x00000008;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DefineDosDeviceW(
            uint flags, string deviceName, string targetPath);

        public static bool Define(string deviceName, string targetPath)
        {
            return DefineDosDeviceW(RawTarget | NoBroadcast, deviceName, targetPath);
        }

        public static bool Remove(string deviceName, string targetPath)
        {
            return DefineDosDeviceW(
                RawTarget | RemoveDefinition | ExactMatch | NoBroadcast,
                deviceName,
                targetPath);
        }
    }
}
'@
}
$temporaryRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) `
    ('ffb-manager-destination-lock-' + [Guid]::NewGuid().ToString('N'))))
$systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not $temporaryRoot.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -or
    -not [IO.Path]::GetFileName($temporaryRoot).StartsWith(
        'ffb-manager-destination-lock-', [StringComparison]::Ordinal)) {
    throw "Unsafe destination-lock fixture path: $temporaryRoot"
}
$boundary = $null
$readOnlyBoundary = $null
$stateBoundary = $null
$leaseProcess = $null
$leaseReleasePath = ''
$rawDosDrive = ''
$rawDosTarget = ''
$substDrive = ''
$substExecutable = Join-Path ([Environment]::SystemDirectory) 'subst.exe'
$previousPackageTest = $env:FFB_INTERCEPTOR_PACKAGE_TEST
$previousStateDirectory = $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY
$readOnlyAclPath = ''
try {
    $simHubRoot = Join-Path $temporaryRoot 'regular\SimHub'
    [IO.Directory]::CreateDirectory($simHubRoot) | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $simHubRoot 'SimHubWPF.exe'), [byte[]]@(0))
    $boundary = Enter-FFBSimHubMutationBoundary -Path $simHubRoot -RequireExecutable
    $renameFailure = $null
    try { [IO.Directory]::Move($simHubRoot, ($simHubRoot + '-renamed')) }
    catch { $renameFailure = $_ }
    if ($null -eq $renameFailure) {
        throw 'A held SimHub mutation boundary did not block directory rename.'
    }
    $ancestor = Split-Path -Parent $simHubRoot
    $ancestorRenameFailure = $null
    try { [IO.Directory]::Move($ancestor, ($ancestor + '-renamed')) }
    catch { $ancestorRenameFailure = $_ }
    if ($null -eq $ancestorRenameFailure) {
        throw 'A held SimHub mutation boundary did not block ancestor rename.'
    }
    Exit-FFBSimHubMutationBoundary -Boundary $boundary
    $boundary = $null
    if (@(Get-ChildItem -LiteralPath $simHubRoot -Filter `
            '.ffb-interceptor-mutation-*.lock' -Force).Count -ne 0) {
        throw 'The SimHub mutation boundary left its delete-on-close sentinel behind.'
    }
    if (Test-Path -LiteralPath (Join-Path $simHubRoot '.ffb-interceptor-mutation.lock')) {
        throw 'The SimHub mutation boundary left its fixed lease behind.'
    }
    [IO.Directory]::Move($simHubRoot, ($simHubRoot + '-renamed'))
    [IO.Directory]::Move(($simHubRoot + '-renamed'), $simHubRoot)

    # Prove the fixed mutation lease is a cross-process exclusion primitive,
    # not merely a GUID sentinel that compatible processes can each create.
    $leaseReadyPath = Join-Path $temporaryRoot 'lease-ready'
    $leaseReleasePath = Join-Path $temporaryRoot 'lease-release'
    $escapedCommonPath = $commonPath.Replace("'", "''")
    $escapedSimHubRoot = $simHubRoot.Replace("'", "''")
    $escapedReadyPath = $leaseReadyPath.Replace("'", "''")
    $escapedReleasePath = $leaseReleasePath.Replace("'", "''")
    $leaseChildScript = @"
`$ErrorActionPreference = 'Stop'
. '$escapedCommonPath'
`$held = `$null
try {
    `$held = Enter-FFBSimHubMutationBoundary -Path '$escapedSimHubRoot' -RequireExecutable
    [IO.File]::WriteAllText('$escapedReadyPath', 'ready')
    `$deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not (Test-Path -LiteralPath '$escapedReleasePath')) {
        if ([DateTime]::UtcNow -ge `$deadline) { throw 'Timed out waiting to release the mutation lease.' }
        Start-Sleep -Milliseconds 50
    }
}
finally { Exit-FFBSimHubMutationBoundary -Boundary `$held }
"@
    $leaseEncoded = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($leaseChildScript))
    $testEngine = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $leaseProcess = Start-Process -FilePath $testEngine -WindowStyle Hidden -PassThru `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-EncodedCommand', $leaseEncoded)
    $readyDeadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $leaseReadyPath)) {
        if ($leaseProcess.HasExited) {
            throw "Mutation lease holder exited early: $($leaseProcess.ExitCode)"
        }
        if ([DateTime]::UtcNow -ge $readyDeadline) {
            throw 'Timed out waiting for the mutation lease holder.'
        }
        Start-Sleep -Milliseconds 50
    }
    $contendedFailure = $null
    try { [void](Enter-FFBSimHubMutationBoundary -Path $simHubRoot -RequireExecutable) }
    catch { $contendedFailure = $_ }
    if ($null -eq $contendedFailure -or
        $contendedFailure.Exception.Message -notmatch 'mutation is active|lease is stale') {
        throw 'A second process entered an active destination mutation boundary.'
    }
    [IO.File]::WriteAllText($leaseReleasePath, 'release')
    if (-not $leaseProcess.WaitForExit(10000) -or $leaseProcess.ExitCode -ne 0) {
        throw 'The cross-process mutation lease holder did not exit cleanly.'
    }
    $leaseProcess.Dispose()
    $leaseProcess = $null
    if ((Test-Path -LiteralPath (Join-Path $simHubRoot '.ffb-interceptor-mutation.lock')) -or
        @(Get-ChildItem -LiteralPath $simHubRoot -Filter `
            '.ffb-interceptor-mutation-*.lock' -Force).Count -ne 0) {
        throw 'The cross-process mutation fixture left a lease or sentinel behind.'
    }

    # WhatIf uses the same directory and identity locks but must not create a
    # sentinel, even on a writable destination.
    $readOnlyBoundary = Enter-FFBSimHubMutationBoundary `
        -Path $simHubRoot -RequireExecutable -ReadOnly
    if (@(Get-ChildItem -LiteralPath $simHubRoot -Filter `
            '.ffb-interceptor-mutation-*.lock' -Force).Count -ne 0) {
        throw 'A read-only SimHub boundary created a mutation sentinel.'
    }
    Exit-FFBSimHubMutationBoundary -Boundary $readOnlyBoundary
    $readOnlyBoundary = $null

    # Simulate Program Files with a directory that grants this medium-token
    # process read/execute only. Read-only validation must succeed without a
    # file creation, while a real mutation boundary must fail closed.
    $readOnlyAclPath = Join-Path $temporaryRoot 'read-only\SimHub'
    [IO.Directory]::CreateDirectory($readOnlyAclPath) | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $readOnlyAclPath 'SimHubWPF.exe'), [byte[]]@(0))
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $readOnlyAcl = New-Object Security.AccessControl.DirectorySecurity
    $readOnlyAcl.SetAccessRuleProtection($true, $false)
    $readOnlyAcl.SetOwner($currentSid)
    $aclInheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor `
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $readOnlyAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        $currentSid,
        [Security.AccessControl.FileSystemRights]::ReadAndExecute,
        $aclInheritance,
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow)))
    Set-TestDirectoryAcl -Path $readOnlyAclPath -Security $readOnlyAcl
    $readOnlyBoundary = Enter-FFBSimHubMutationBoundary `
        -Path $readOnlyAclPath -RequireExecutable -ReadOnly
    Exit-FFBSimHubMutationBoundary -Boundary $readOnlyBoundary
    $readOnlyBoundary = $null
    if (@(Get-ChildItem -LiteralPath $readOnlyAclPath -Filter `
            '.ffb-interceptor-mutation-*.lock' -Force).Count -ne 0) {
        throw 'Read-only validation left a file in the protected destination.'
    }
    $protectedMutationFailure = $null
    try {
        [void](Enter-FFBSimHubMutationBoundary `
            -Path $readOnlyAclPath -RequireExecutable)
    }
    catch { $protectedMutationFailure = $_ }
    if ($null -eq $protectedMutationFailure) {
        throw 'A real mutation unexpectedly succeeded in a read-only destination.'
    }

    # The state directory is another elevated write destination. Its boundary
    # must cover the directory and ancestors and must reject a junction before
    # any ACL or state-file mutation is attempted.
    $stateFixtureRoot = Join-Path $temporaryRoot (
        'ffb-launcher-package-smoke-' + [Guid]::NewGuid().ToString('N'))
    $env:FFB_INTERCEPTOR_PACKAGE_TEST = '1'
    $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY = Join-Path $stateFixtureRoot 'state'
    $stateBoundary = Enter-FFBStateMutationBoundary -AllowCreate
    $stateRenameFailure = $null
    try {
        [IO.Directory]::Move($env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY,
            ($env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY + '-renamed'))
    }
    catch { $stateRenameFailure = $_ }
    if ($null -eq $stateRenameFailure) {
        throw 'A held state mutation boundary did not block directory rename.'
    }
    $stateAncestorFailure = $null
    try { [IO.Directory]::Move($stateFixtureRoot, ($stateFixtureRoot + '-renamed')) }
    catch { $stateAncestorFailure = $_ }
    if ($null -eq $stateAncestorFailure) {
        throw 'A held state mutation boundary did not block ancestor rename.'
    }
    Exit-FFBSimHubMutationBoundary -Boundary $stateBoundary
    $stateBoundary = $null
    if (@(Get-ChildItem -LiteralPath $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY `
            -Filter '.ffb-interceptor-mutation-*.lock' -Force).Count -ne 0) {
        throw 'The state mutation boundary left its sentinel behind.'
    }

    $fakeSimHub = Join-Path $stateFixtureRoot 'fake-simhub'
    [IO.Directory]::CreateDirectory($fakeSimHub) | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $fakeSimHub 'SimHubWPF.exe'), [byte[]]@(0))
    $stateFiles = @()
    foreach ($name in @('FFBInterceptor.SimHub.dll', 'FFBInterceptor.Core.dll')) {
        $stateFiles += [pscustomobject][ordered]@{
            Destination = Join-Path $fakeSimHub $name
            Backup = ''
            BackupSha256 = ''
            InstalledSha256 = ('A' * 64)
            Changed = $true
        }
    }
    Save-FFBPluginState -State ([pscustomobject][ordered]@{
        SchemaVersion = 1
        InstalledAtUtc = [DateTime]::UtcNow.ToString('o')
        InstallPath = $fakeSimHub
        Files = $stateFiles
    })
    if (-not (Test-FFBStateProtection)) {
        throw 'Save-FFBPluginState did not protect the state directory and file.'
    }
    $savedState = Read-FFBPluginState -RequireSimHubExecutable
    if ($savedState.Files.Count -ne 2 -or
        -not (Test-FFBPathEqual -Left ([string]$savedState.InstallPath) `
            -Right $fakeSimHub)) {
        throw 'The boundary-protected plug-in state did not round-trip.'
    }
    if (@(Get-ChildItem -LiteralPath $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY `
            -Filter '.ffb-interceptor-mutation-*.lock' -Force).Count -ne 0) {
        throw 'Save-FFBPluginState left its state sentinel behind.'
    }
    Remove-Item -LiteralPath (Get-FFBStatePath) -Force
    Remove-Item -LiteralPath $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY -Force
    $stateJunctionTarget = Join-Path $stateFixtureRoot 'junction-target'
    [IO.Directory]::CreateDirectory($stateJunctionTarget) | Out-Null
    New-Item -ItemType Junction -Path $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY `
        -Target $stateJunctionTarget | Out-Null
    $stateJunctionFailure = $null
    try { [void](Enter-FFBStateMutationBoundary) }
    catch { $stateJunctionFailure = $_ }
    if ($null -eq $stateJunctionFailure) {
        throw 'A reparse-point protected state directory passed the mutation boundary.'
    }

    $driveRoot = [IO.Path]::GetPathRoot($simHubRoot)
    $driveTarget = [FFBInterceptor.DirectoryMutationLock]::GetStableFixedDriveTarget(
        $driveRoot)
    if (-not $driveTarget.StartsWith('\Device\HarddiskVolume',
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Destination-lock fixture was not anchored to a physical volume: $driveTarget"
    }
    if (-not [FFBInterceptor.DirectoryMutationLock]::IsPhysicalVolumeDeviceName($driveTarget) -or
        [FFBInterceptor.DirectoryMutationLock]::IsPhysicalVolumeDeviceName(
            ($driveTarget + '\user-controlled-suffix'))) {
        throw 'Physical-volume validation accepted a raw DOS target with a directory suffix.'
    }

    # A raw DOS alias can point directly at a subdirectory while still
    # beginning with \Device\HarddiskVolume. Exercise the real API when the
    # current token may allocate an unused local drive name.
    $rawAliasDirectory = Join-Path $temporaryRoot 'raw-device-target'
    [IO.Directory]::CreateDirectory($rawAliasDirectory) | Out-Null
    $rawDosTarget = $driveTarget + $rawAliasDirectory.Substring(2)
    foreach ($letter in [char[]]'ZYXWVUTSRQPONMLKJIHGFED') {
        $candidateDrive = ([string]$letter) + ':'
        if ([IO.Directory]::Exists($candidateDrive + '\')) { continue }
        if ([FFBInterceptor.RawDosDeviceFixture]::Define($candidateDrive, $rawDosTarget)) {
            $rawDosDrive = $candidateDrive
            break
        }
    }
    if ($rawDosDrive) {
        $rawAliasFailure = $null
        try {
            [void][FFBInterceptor.DirectoryMutationLock]::GetStableFixedDriveTarget(
                ($rawDosDrive + '\'))
        }
        catch { $rawAliasFailure = $_ }
        if ($null -eq $rawAliasFailure -or
            $rawAliasFailure.Exception.Message -notmatch 'stable physical volume') {
            throw 'A raw DOS device alias with a directory suffix passed fixed-volume validation.'
        }
        if (-not [FFBInterceptor.RawDosDeviceFixture]::Remove(
                $rawDosDrive, $rawDosTarget)) {
            throw "Unable to remove the test-only raw DOS device alias: $rawDosDrive"
        }
        $rawDosDrive = ''
        $rawDosTarget = ''
    }
    else {
        Write-Warning 'The current token could not allocate a raw DOS device alias; direct target validation still ran.'
    }

    # A SUBST drive is reported as a local drive by ordinary path APIs but its
    # DOS device target is user-replaceable. The elevated mutation boundary
    # must reject it before creating or moving any managed file.
    $existingSubst = @(& $substExecutable 2>$null) -join "`n"
    foreach ($letter in [char[]]'ZYXWVUTSRQPONMLKJIHGFED') {
        $candidateDrive = ([string]$letter) + ':'
        if ($existingSubst -match "(?im)^$letter`:\\" -or
            [IO.Directory]::Exists($candidateDrive + '\')) { continue }
        $substTarget = Join-Path $temporaryRoot 'subst-SimHub'
        [IO.Directory]::CreateDirectory($substTarget) | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $substTarget 'SimHubWPF.exe'), [byte[]]@(0))
        & $substExecutable $candidateDrive $substTarget | Out-Null
        if ($LASTEXITCODE -ne 0) { continue }
        $substDrive = $candidateDrive
        break
    }
    if ($substDrive) {
        $substFailure = $null
        try {
            [void](Enter-FFBSimHubMutationBoundary `
                -Path ($substDrive + '\') -RequireExecutable)
        }
        catch { $substFailure = $_ }
        if ($null -eq $substFailure -or
            $substFailure.Exception.Message -notmatch 'stable physical SimHub drive') {
            throw 'A user-replaceable SUBST drive passed the SimHub mutation boundary.'
        }
    }
    else {
        Write-Warning 'No unused DOS drive letter was available for the SUBST boundary fixture.'
    }

    $junctionTarget = Join-Path $temporaryRoot 'junction-target'
    $junctionPath = Join-Path $temporaryRoot 'junction-SimHub'
    [IO.Directory]::CreateDirectory($junctionTarget) | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $junctionTarget 'SimHubWPF.exe'), [byte[]]@(0))
    New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget | Out-Null
    $junctionFailure = $null
    try { [void](Enter-FFBSimHubMutationBoundary -Path $junctionPath -RequireExecutable) }
    catch { $junctionFailure = $_ }
    if ($null -eq $junctionFailure) {
        throw 'A reparse-point SimHub destination passed the mutation boundary.'
    }
}
finally {
    if ($null -ne $leaseProcess) {
        if (-not [string]::IsNullOrWhiteSpace($leaseReleasePath)) {
            try { [IO.File]::WriteAllText($leaseReleasePath, 'release') } catch { }
        }
        try {
            if (-not $leaseProcess.WaitForExit(5000)) { $leaseProcess.Kill() }
        }
        catch { }
        $leaseProcess.Dispose()
    }
    Exit-FFBSimHubMutationBoundary -Boundary $stateBoundary
    Exit-FFBSimHubMutationBoundary -Boundary $readOnlyBoundary
    Exit-FFBSimHubMutationBoundary -Boundary $boundary
    if ($rawDosDrive) {
        if (-not [FFBInterceptor.RawDosDeviceFixture]::Remove(
                $rawDosDrive, $rawDosTarget)) {
            throw "Unable to remove the test-only raw DOS device alias: $rawDosDrive"
        }
    }
    $env:FFB_INTERCEPTOR_PACKAGE_TEST = $previousPackageTest
    $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY = $previousStateDirectory
    if (-not [string]::IsNullOrWhiteSpace($readOnlyAclPath) -and
        (Test-Path -LiteralPath $readOnlyAclPath -PathType Container)) {
        $currentName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $icacls = Join-Path ([Environment]::SystemDirectory) 'icacls.exe'
        & $icacls $readOnlyAclPath /grant:r "${currentName}:(OI)(CI)F" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to restore the test-only read-only ACL: $readOnlyAclPath"
        }
    }
    if ($substDrive) {
        & $substExecutable $substDrive /D | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to remove the test-only SUBST mapping: $substDrive"
        }
    }
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

Write-Output 'Manager controlled-elevation boundary fixtures passed.'
