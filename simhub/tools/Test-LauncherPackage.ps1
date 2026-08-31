# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$PackagePath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
try {
    $testIsAdministrator = ([Security.Principal.WindowsPrincipal]::new($currentIdentity)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
finally { $currentIdentity.Dispose() }

function Initialize-FFBRestrictedProcessHost {
    if ($null -ne ('FFBInterceptor.PackageTestRestrictedProcess' -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace FFBInterceptor
{
    public static class PackageTestRestrictedProcess
    {
        private const UInt32 TOKEN_ASSIGN_PRIMARY = 0x0001;
        private const UInt32 TOKEN_DUPLICATE = 0x0002;
        private const UInt32 TOKEN_QUERY = 0x0008;
        private const UInt32 DISABLE_MAX_PRIVILEGE = 0x0001;
        private const UInt32 CREATE_NO_WINDOW = 0x08000000;
        private const UInt32 WAIT_OBJECT_0 = 0x00000000;
        private const UInt32 WAIT_TIMEOUT = 0x00000102;
        private const UInt32 WAIT_FAILED = 0xFFFFFFFF;
        private const int ERROR_PRIVILEGE_NOT_HELD = 1314;

        [StructLayout(LayoutKind.Sequential)]
        private struct SID_IDENTIFIER_AUTHORITY
        {
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 6)]
            public byte[] Value;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SID_AND_ATTRIBUTES
        {
            public IntPtr Sid;
            public UInt32 Attributes;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct STARTUPINFO
        {
            public UInt32 cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public UInt32 dwX;
            public UInt32 dwY;
            public UInt32 dwXSize;
            public UInt32 dwYSize;
            public UInt32 dwXCountChars;
            public UInt32 dwYCountChars;
            public UInt32 dwFillAttribute;
            public UInt32 dwFlags;
            public UInt16 wShowWindow;
            public UInt16 cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_INFORMATION
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public UInt32 dwProcessId;
            public UInt32 dwThreadId;
        }

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern UInt32 WaitForSingleObject(IntPtr handle, UInt32 milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetExitCodeProcess(IntPtr process, out UInt32 exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool TerminateProcess(IntPtr process, UInt32 exitCode);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool OpenProcessToken(
            IntPtr process, UInt32 desiredAccess, out IntPtr token);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool AllocateAndInitializeSid(
            ref SID_IDENTIFIER_AUTHORITY identifierAuthority,
            byte subAuthorityCount,
            UInt32 subAuthority0,
            UInt32 subAuthority1,
            UInt32 subAuthority2,
            UInt32 subAuthority3,
            UInt32 subAuthority4,
            UInt32 subAuthority5,
            UInt32 subAuthority6,
            UInt32 subAuthority7,
            out IntPtr sid);

        [DllImport("advapi32.dll")]
        private static extern IntPtr FreeSid(IntPtr sid);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateRestrictedToken(
            IntPtr existingToken,
            UInt32 flags,
            UInt32 disableSidCount,
            [In] SID_AND_ATTRIBUTES[] sidsToDisable,
            UInt32 deletePrivilegeCount,
            IntPtr privilegesToDelete,
            UInt32 restrictedSidCount,
            IntPtr sidsToRestrict,
            out IntPtr newToken);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CheckTokenMembership(
            IntPtr token, IntPtr sidToCheck, out bool isMember);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DuplicateToken(
            IntPtr existingToken, int impersonationLevel, out IntPtr duplicateToken);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProcessAsUserW(
            IntPtr token,
            string applicationName,
            StringBuilder commandLine,
            IntPtr processAttributes,
            IntPtr threadAttributes,
            [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
            UInt32 creationFlags,
            IntPtr environment,
            string currentDirectory,
            ref STARTUPINFO startupInfo,
            out PROCESS_INFORMATION processInformation);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProcessWithTokenW(
            IntPtr token,
            UInt32 logonFlags,
            string applicationName,
            StringBuilder commandLine,
            UInt32 creationFlags,
            IntPtr environment,
            string currentDirectory,
            ref STARTUPINFO startupInfo,
            out PROCESS_INFORMATION processInformation);

        private static StringBuilder BuildCommandLine(string applicationName, string arguments)
        {
            return new StringBuilder("\"" + applicationName + "\" " + arguments);
        }

        public static int Run(string applicationName, string arguments,
            string currentDirectory, UInt32 timeoutMilliseconds)
        {
            if (String.IsNullOrWhiteSpace(applicationName) || applicationName.IndexOf('"') >= 0)
                throw new ArgumentException("The test application path is invalid.", "applicationName");

            IntPtr sourceToken = IntPtr.Zero;
            IntPtr restrictedToken = IntPtr.Zero;
            IntPtr verificationToken = IntPtr.Zero;
            IntPtr administratorsSid = IntPtr.Zero;
            PROCESS_INFORMATION process = new PROCESS_INFORMATION();
            try
            {
                if (!OpenProcessToken(GetCurrentProcess(),
                    TOKEN_ASSIGN_PRIMARY | TOKEN_DUPLICATE | TOKEN_QUERY, out sourceToken))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcessToken failed.");

                SID_IDENTIFIER_AUTHORITY ntAuthority = new SID_IDENTIFIER_AUTHORITY {
                    Value = new byte[] { 0, 0, 0, 0, 0, 5 }
                };
                if (!AllocateAndInitializeSid(ref ntAuthority, 2, 32, 544,
                    0, 0, 0, 0, 0, 0, out administratorsSid))
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "Could not create the Administrators SID.");

                SID_AND_ATTRIBUTES[] disabled = new SID_AND_ATTRIBUTES[1];
                disabled[0].Sid = administratorsSid;
                disabled[0].Attributes = 0;
                if (!CreateRestrictedToken(sourceToken, DISABLE_MAX_PRIVILEGE, 1, disabled,
                    0, IntPtr.Zero, 0, IntPtr.Zero, out restrictedToken))
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "CreateRestrictedToken failed.");

                bool isAdministrator;
                if (!DuplicateToken(restrictedToken, 1, out verificationToken) ||
                    !CheckTokenMembership(verificationToken, administratorsSid, out isAdministrator))
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "Could not verify the restricted package-test token.");
                if (isAdministrator)
                    throw new InvalidOperationException(
                        "The package-test child token is still an administrator token.");

                STARTUPINFO startup = new STARTUPINFO();
                startup.cb = (UInt32)Marshal.SizeOf(typeof(STARTUPINFO));
                bool created = CreateProcessAsUserW(restrictedToken, applicationName,
                    BuildCommandLine(applicationName, arguments), IntPtr.Zero, IntPtr.Zero,
                    false, CREATE_NO_WINDOW, IntPtr.Zero, currentDirectory, ref startup, out process);
                int createError = created ? 0 : Marshal.GetLastWin32Error();
                if (!created && createError == ERROR_PRIVILEGE_NOT_HELD)
                {
                    created = CreateProcessWithTokenW(restrictedToken, 0, applicationName,
                        BuildCommandLine(applicationName, arguments), CREATE_NO_WINDOW,
                        IntPtr.Zero, currentDirectory, ref startup, out process);
                    createError = created ? 0 : Marshal.GetLastWin32Error();
                }
                if (!created)
                    throw new Win32Exception(createError,
                        "Could not start the restricted package-test child process.");

                UInt32 wait = WaitForSingleObject(process.hProcess, timeoutMilliseconds);
                if (wait == WAIT_TIMEOUT)
                {
                    TerminateProcess(process.hProcess, 124);
                    WaitForSingleObject(process.hProcess, 5000);
                    throw new TimeoutException("The restricted package-test child process timed out.");
                }
                if (wait == WAIT_FAILED)
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "Waiting for the restricted package-test child process failed.");
                if (wait != WAIT_OBJECT_0)
                    throw new InvalidOperationException("The restricted package-test wait returned an invalid result.");

                UInt32 exitCode;
                if (!GetExitCodeProcess(process.hProcess, out exitCode))
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "Could not read the restricted package-test exit code.");
                return unchecked((int)exitCode);
            }
            finally
            {
                if (process.hThread != IntPtr.Zero) CloseHandle(process.hThread);
                if (process.hProcess != IntPtr.Zero) CloseHandle(process.hProcess);
                if (verificationToken != IntPtr.Zero) CloseHandle(verificationToken);
                if (restrictedToken != IntPtr.Zero) CloseHandle(restrictedToken);
                if (sourceToken != IntPtr.Zero) CloseHandle(sourceToken);
                if (administratorsSid != IntPtr.Zero) FreeSid(administratorsSid);
            }
        }
    }
}
'@ | Out-Null
}

function ConvertTo-FFBEncodedCommand {
    param([Parameter(Mandatory = $true)][string]$Script)
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
}

function Invoke-FFBStartRuntimeFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Starter,
        [Parameter(Mandatory = $true)][string]$GameExecutable,
        [Parameter(Mandatory = $true)][string]$SimHubInstallPath,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )
    $powerShell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powerShell -PathType Leaf)) {
        throw "Windows PowerShell is missing: $powerShell"
    }

    if (-not $testIsAdministrator) {
        $savedErrorAction = $ErrorActionPreference
        $savedLocation = Get-Location
        try {
            $ErrorActionPreference = 'Continue'
            Set-Location -LiteralPath $WorkingDirectory
            $output = @(& $powerShell -NoProfile -ExecutionPolicy Bypass -File $Starter `
                -GameExecutable $GameExecutable -SimHubInstallPath $SimHubInstallPath -NoPause 2>&1)
            $exitCode = $LASTEXITCODE
        }
        finally {
            Set-Location -LiteralPath $savedLocation.Path
            $ErrorActionPreference = $savedErrorAction
        }
        return [pscustomobject]@{ ExitCode = $exitCode; Text = ($output -join "`n") }
    }

    Initialize-FFBRestrictedProcessHost
    $escape = { param([string]$Value) $Value.Replace("'", "''") }
    $inner = @"
`$savedErrorAction = `$ErrorActionPreference
try {
    `$ErrorActionPreference = 'Continue'
    `$output = @(& '$(& $escape $powerShell)' -NoProfile -ExecutionPolicy Bypass -File '$(& $escape $Starter)' -GameExecutable '$(& $escape $GameExecutable)' -SimHubInstallPath '$(& $escape $SimHubInstallPath)' -NoPause 2>&1)
    `$exitCode = `$LASTEXITCODE
    [IO.File]::WriteAllText('$(& $escape $OutputPath)', (`$output -join "`n"), (New-Object Text.UTF8Encoding(`$false)))
    exit `$exitCode
}
catch {
    [IO.File]::WriteAllText('$(& $escape $OutputPath)', `$_.Exception.ToString(), (New-Object Text.UTF8Encoding(`$false)))
    exit 125
}
finally { `$ErrorActionPreference = `$savedErrorAction }
"@
    $encoded = ConvertTo-FFBEncodedCommand -Script $inner
    $exitCode = [FFBInterceptor.PackageTestRestrictedProcess]::Run(
        $powerShell, "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded",
        $WorkingDirectory, 60000)
    $text = if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
        [IO.File]::ReadAllText($OutputPath, [Text.Encoding]::UTF8)
    }
    else { '' }
    return [pscustomobject]@{ ExitCode = $exitCode; Text = $text }
}

function New-FFBManagerHandoffStub {
    param(
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$SentinelName
    )
    if ($SentinelName -cnotmatch '^\.ffb-manager-handoff-[a-f0-9]{32}\.sentinel$') {
        throw 'The Manager handoff sentinel name is invalid.'
    }
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
        throw "The .NET Framework C# compiler required by the Manager handoff fixture is missing: $compiler"
    }
    $escapedSentinel = $SentinelName.Replace('\', '\\').Replace('"', '\"')
    $source = @"
using System;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Text;

internal static class FFBManagerHandoffStub
{
    private static int Main(string[] args)
    {
        string root = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string sentinel = Path.Combine(root, "$escapedSentinel");
        string temporary = sentinel + "." + Guid.NewGuid().ToString("N") + ".tmp";
        string[] record = new string[] {
            args.Length.ToString(CultureInfo.InvariantCulture),
            Convert.ToBase64String(Encoding.UTF8.GetBytes(Directory.GetCurrentDirectory()))
        };
        File.WriteAllLines(temporary, record, new UTF8Encoding(false));
        try { File.Move(temporary, sentinel); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
        return 0;
    }
}
"@
    [IO.File]::WriteAllText($SourcePath, $source, [Text.UTF8Encoding]::new($false))
    $savedErrorAction = $ErrorActionPreference
    try {
        # Windows PowerShell 5 reports native stderr as ErrorRecord. Compiler
        # diagnostics are captured explicitly and handled by the exit code.
        $ErrorActionPreference = 'Continue'
        $compilerOutput = @(& $compiler '/nologo' '/target:exe' '/optimize+' '/platform:anycpu' `
            "/out:$OutputPath" $SourcePath 2>&1)
        $compilerExitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedErrorAction }
    if ($compilerExitCode -ne 0 -or -not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
        throw "Could not build the Manager handoff fixture: $($compilerOutput -join "`n")"
    }
}

function Wait-FFBManagerHandoffSentinel {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedWorkingDirectory
    )
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $Path -PathType Leaf) -and
        [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 50
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'Default Start returned without launching the package Manager handoff stub.'
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        $item.Length -gt 4096) {
        throw 'The Manager handoff sentinel is not a safe regular file.'
    }
    $record = [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)
    $argumentCount = 0
    if ($record.Count -ne 2 -or
        -not [int]::TryParse($record[0], [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$argumentCount) -or
        $argumentCount -ne 0) {
        throw 'Default Start did not launch Manager with the required empty argument list.'
    }
    try {
        $workingDirectory = [Text.Encoding]::UTF8.GetString(
            [Convert]::FromBase64String($record[1]))
    }
    catch { throw 'The Manager handoff sentinel contains an invalid working directory record.' }
    $actual = [IO.Path]::GetFullPath($workingDirectory).TrimEnd('\')
    $expected = [IO.Path]::GetFullPath($ExpectedWorkingDirectory).TrimEnd('\')
    if (-not $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Manager handoff used an unexpected working directory: $actual"
    }
}

function Assert-FFBSimHubClosedForPackageLifecycle {
    param([object[]]$RunningProcesses = @(
        Get-Process -Name 'SimHub', 'SimHubWPF' -ErrorAction SilentlyContinue))
    if ($RunningProcesses.Count -gt 0) {
        $identities = @($RunningProcesses | ForEach-Object { "$($_.ProcessName) (PID $($_.Id))" }) -join ', '
        throw "Close SimHub before validating the Launcher package. Full install/uninstall lifecycle validation is mandatory and cannot fall back to WhatIf. Running: $identities"
    }
}

$archivePath = (Resolve-Path -LiteralPath $PackagePath -ErrorAction Stop).Path
$validatorSource = [IO.File]::ReadAllText($PSCommandPath, [Text.Encoding]::UTF8)
if ([regex]::IsMatch($validatorSource,
    '(?ims)&\s+(?:powershell\.exe|\$powerShell)\b.{0,300}?-File\s+\$installer\b.{0,300}?\s-WhatIf(?:\s|$)')) {
    throw 'Launcher package validation must not replace its install/uninstall lifecycle with WhatIf.'
}
$simHubContractRejected = $false
try {
    Assert-FFBSimHubClosedForPackageLifecycle -RunningProcesses @(
        [pscustomobject]@{ ProcessName = 'SimHub'; Id = 424242 })
}
catch {
    if ($_.Exception.Message -notmatch 'Full install/uninstall lifecycle validation is mandatory') { throw }
    $simHubContractRejected = $true
}
if (-not $simHubContractRejected) {
    throw 'The package validator no longer rejects a running SimHub process.'
}
$zip = [IO.Compression.ZipFile]::OpenRead($archivePath)
try {
    $names = @($zip.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
    if ($names.Count -eq 0) { throw 'Launcher package is empty.' }
    $seenNames = @{}
    foreach ($name in $names) {
        if ([string]::IsNullOrWhiteSpace($name) -or $name.StartsWith('/') -or $name.Contains('\')) {
            throw "Package contains an unsafe entry name: $name"
        }
        $key = $name.ToLowerInvariant()
        if ($seenNames.ContainsKey($key)) { throw "Package contains a duplicate entry name: $name" }
        $seenNames[$key] = $true
        $segments = @($name.TrimEnd('/') -split '/')
        foreach ($segment in $segments) {
            if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.' -or $segment -eq '..' -or
                $segment.Contains(':') -or $segment.EndsWith('.') -or $segment.EndsWith(' ')) {
                throw "Package contains a non-canonical entry name: $name"
            }
        }
    }
    $roots = @($names | ForEach-Object { ($_ -split '/')[0] } | Where-Object { $_ -like 'FFBInterceptor-Launcher-*' } | Sort-Object -Unique)
    if ($roots.Count -ne 1) { throw 'Package must contain exactly one FFBInterceptor-Launcher root directory.' }
    $root = $roots[0]
    $required = @(
        "$root/FFBInterceptor.Common.ps1",
        "$root/FFBInterceptor.Manager.exe",
        "$root/Start-FFBInterceptor.cmd",
        "$root/Start-FFBInterceptor.ps1",
        "$root/Install-SimHubPlugin.cmd",
        "$root/Install-SimHubPlugin.ps1",
        "$root/Uninstall-SimHubPlugin.cmd",
        "$root/Uninstall-SimHubPlugin.ps1",
        "$root/launcher/x64/FFBInterceptor.Launcher.exe",
        "$root/launcher/x64/FFBInterceptor.Hook.dll",
        "$root/launcher/x86/FFBInterceptor.Launcher.exe",
        "$root/launcher/x86/FFBInterceptor.Hook.dll",
        "$root/simhub/FFBInterceptor.SimHub.dll",
        "$root/simhub/FFBInterceptor.Core.dll",
        "$root/Dashboards/FFB Interceptor 800x480.simhubdash",
        "$root/Dashboards/FFB Interceptor Overlay 480x160.simhubdash",
        "$root/README.zh-TW.md",
        "$root/MANAGER.zh-TW.md",
        "$root/SHA256SUMS.txt",
        "$root/LICENSE",
        "$root/THIRD_PARTY_NOTICES.md",
        "$root/licenses/upstream-dcs-force-feedback-fix-MIT.txt"
    )
    $files = @($names | Where-Object { -not $_.EndsWith('/') })
    foreach ($entry in $required) { if ($files -cnotcontains $entry) { throw "Package is missing required entry: $entry" } }
    foreach ($entry in $files) { if ($required -cnotcontains $entry) { throw "Package contains an unexpected file: $entry" } }
    $allowedDirectories = @(
        "$root/",
        "$root/launcher/",
        "$root/launcher/x64/",
        "$root/launcher/x86/",
        "$root/simhub/",
        "$root/Dashboards/",
        "$root/licenses/"
    )
    foreach ($entry in @($names | Where-Object { $_.EndsWith('/') })) {
        if ($allowedDirectories -cnotcontains $entry) { throw "Package contains an unexpected directory: $entry" }
    }
    if ($names | Where-Object { $_ -match '(^|/)dinput8\.dll$' }) { throw 'Launcher package must not contain dinput8.dll.' }
    if (@($names | Where-Object { $_ -like '*.exe' }).Count -ne 3) { throw 'Launcher package must contain exactly three executables.' }
    if (@($names | Where-Object { $_ -like '*.dll' }).Count -ne 4) { throw 'Launcher package must contain exactly four project DLLs.' }
    if ($names | Where-Object { $_ -match '/(SimHub\.Plugins|GameReaderCommon|SimHub\.Logging|log4net)\.dll$' }) {
        throw 'Package unexpectedly contains a SimHub-owned dependency.'
    }
}
finally { $zip.Dispose() }

$temporaryRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('ffb-launcher-package-smoke-' + [Guid]::NewGuid().ToString('N'))))
$systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $temporaryRoot.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -or
    -not ([IO.Path]::GetFileName($temporaryRoot)).StartsWith('ffb-launcher-package-smoke-', [StringComparison]::Ordinal)) {
    throw "Unsafe temporary path: $temporaryRoot"
}

$originalPackageTest = $env:FFB_INTERCEPTOR_PACKAGE_TEST
$originalTestStateDirectory = $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY
try {
    [IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $temporaryRoot)
    $packageRoot = Join-Path $temporaryRoot $root
    $packageRootFull = [IO.Path]::GetFullPath($packageRoot)
    foreach ($entry in $names) {
        $candidate = [IO.Path]::GetFullPath((Join-Path $temporaryRoot $entry))
        if (-not $candidate.Equals($packageRootFull, [StringComparison]::OrdinalIgnoreCase) -and
            -not $candidate.StartsWith($packageRootFull + [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "Package entry escapes its root: $entry"
        }
    }

    foreach ($relativeScript in @(
        'FFBInterceptor.Common.ps1',
        'Install-SimHubPlugin.ps1',
        'Uninstall-SimHubPlugin.ps1',
        'Start-FFBInterceptor.ps1'
    )) {
        $scriptPath = Join-Path $packageRoot $relativeScript
        $tokens = $null
        $errors = $null
        [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors.Count -gt 0) { throw "PowerShell syntax error in packaged $relativeScript : $($errors[0].Message)" }
    }

    $startCommand = [IO.File]::ReadAllText((Join-Path $packageRoot 'Start-FFBInterceptor.cmd'))
    if ($startCommand -match '(?i)(?:^|\s)-NoPause(?:\s|$)') {
        throw 'Packaged Start command suppresses the first-run instruction pause.'
    }
    if ($startCommand -notmatch '(?im)^exit /b %errorlevel%\s*$') {
        throw 'Packaged Start command does not preserve the PowerShell exit code.'
    }
    $startScriptText = [IO.File]::ReadAllText((Join-Path $packageRoot 'Start-FFBInterceptor.ps1'))
    if ($startScriptText -match '(?i)ManagerInvocationEvent|\bRunAs\b') {
        throw 'Packaged Start script must not manufacture a Manager handshake or elevate itself.'
    }

    $manifestPath = Join-Path $packageRoot 'SHA256SUMS.txt'
    $expectedManifestEntries = @($required | Where-Object { $_ -cne "$root/SHA256SUMS.txt" } |
        ForEach-Object { $_.Substring($root.Length + 1) })
    $manifestEntries = @{}
    foreach ($line in (Get-Content -LiteralPath $manifestPath)) {
        if ($line -notmatch '^([A-F0-9]{64})  (.+)$') { throw "Invalid manifest line: $line" }
        $relative = $Matches[2]
        if ($expectedManifestEntries -cnotcontains $relative -or $manifestEntries.ContainsKey($relative)) {
            throw "Unexpected or duplicate manifest entry: $relative"
        }
        $manifestEntries[$relative] = $true
        $candidate = [IO.Path]::GetFullPath((Join-Path $packageRoot $relative))
        if (-not $candidate.StartsWith($packageRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsafe manifest path: $candidate"
        }
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf) -or
            (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -ne $Matches[1]) {
            throw "Manifest verification failed: $candidate"
        }
    }
    if ($manifestEntries.Count -ne $expectedManifestEntries.Count) {
        throw 'SHA256SUMS.txt does not cover every packaged file.'
    }

    # Compile the exact native pipe helper embedded in the packaged Start
    # script. This runs even when an elevated token or a live SimHub process
    # makes the complete normal-user Start fixture unsafe to execute.
    $nativeDefinitionMatch = [regex]::Match($startScriptText,
        "(?ms)^\s*Add-Type\s+-TypeDefinition\s+@'\r?\n(?<definition>.*?)\r?\n'@\s*$")
    if (-not $nativeDefinitionMatch.Success) {
        throw 'Packaged Start script does not contain the native pipe helper definition.'
    }
    Add-Type -TypeDefinition $nativeDefinitionMatch.Groups['definition'].Value | Out-Null
    $launcherNativeType = 'FFBInterceptor.LauncherNativeMethods' -as [type]
    if ($null -eq $launcherNativeType -or
        $null -eq $launcherNativeType.GetMethod('WaitNamedPipe')) {
        throw 'Packaged Start native pipe helper is not publicly callable.'
    }
    $missingTestPipe = "\\.\pipe\ffb-interceptor-package-test-$([Guid]::NewGuid().ToString('N'))"
    if ($launcherNativeType::WaitNamedPipe($missingTestPipe, 0)) {
        throw 'Packaged Start native pipe helper unexpectedly found the isolated test pipe.'
    }

    & (Join-Path $PSScriptRoot '..\..\tests\powershell\standalone_boundary_tests.ps1') `
        -PackageRoot $packageRoot

    $fakeSimHub = Join-Path $temporaryRoot 'fake-simhub'
    [IO.Directory]::CreateDirectory($fakeSimHub) | Out-Null
    $systemWhere = Join-Path ([Environment]::SystemDirectory) 'where.exe'
    Copy-Item -LiteralPath $systemWhere -Destination (Join-Path $fakeSimHub 'SimHubWPF.exe')

    $installer = Join-Path $packageRoot 'Install-SimHubPlugin.ps1'
    $uninstaller = Join-Path $packageRoot 'Uninstall-SimHubPlugin.ps1'
    $starter = Join-Path $packageRoot 'Start-FFBInterceptor.ps1'
    $env:FFB_INTERCEPTOR_PACKAGE_TEST = '1'
    $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY = Join-Path $temporaryRoot 'state'

    if ($testIsAdministrator) {
        # CI and release runners are often elevated (and may run as SYSTEM).
        # Prove that the test-only child really lost Administrators membership;
        # never turn a failed downgrade into a skipped normal-user fixture.
        Initialize-FFBRestrictedProcessHost
        $probeScript = @'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
try {
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 91 }
    exit 0
}
finally { $identity.Dispose() }
'@
        $probePowerShell = Join-Path ([Environment]::SystemDirectory) `
            'WindowsPowerShell\v1.0\powershell.exe'
        $probeEncoded = ConvertTo-FFBEncodedCommand -Script $probeScript
        $probeExitCode = [FFBInterceptor.PackageTestRestrictedProcess]::Run(
            $probePowerShell,
            "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $probeEncoded",
            $packageRoot, 30000)
        if ($probeExitCode -ne 0) {
            throw "The restricted package-test child retained administrator membership (exit $probeExitCode)."
        }
    }

    # Default first-run Start must really invoke the fixed sibling Manager.
    # A disposable observable stub atomically records invocation facts; this
    # makes deleting or bypassing Start-Process a hard test failure.
    $handoffRoot = Join-Path $temporaryRoot 'manager-handoff-package'
    Copy-Item -LiteralPath $packageRoot -Destination $handoffRoot -Recurse
    $handoffManager = Join-Path $handoffRoot 'FFBInterceptor.Manager.exe'
    $sentinelName = '.ffb-manager-handoff-' + [Guid]::NewGuid().ToString('N') + '.sentinel'
    $sentinelPath = Join-Path $handoffRoot $sentinelName
    $stubSource = Join-Path $temporaryRoot 'FFBManagerHandoffStub.cs'
    $stubBinary = Join-Path $temporaryRoot 'FFBManagerHandoffStub.exe'
    New-FFBManagerHandoffStub -OutputPath $stubBinary -SourcePath $stubSource `
        -SentinelName $sentinelName
    Copy-Item -LiteralPath $stubBinary -Destination $handoffManager -Force
    $handoffManifest = Join-Path $handoffRoot 'SHA256SUMS.txt'
    $handoffManagerHash = (Get-FileHash -LiteralPath $handoffManager -Algorithm SHA256).Hash
    $handoffReplacements = 0
    $handoffManifestLines = @(Get-Content -LiteralPath $handoffManifest | ForEach-Object {
        if ($_ -match '^[A-F0-9]{64}  FFBInterceptor\.Manager\.exe$') {
            $handoffReplacements++
            "$handoffManagerHash  FFBInterceptor.Manager.exe"
        }
        else { $_ }
    })
    if ($handoffReplacements -ne 1) {
        throw 'Default Start fixture could not replace exactly one Manager manifest entry.'
    }
    [IO.File]::WriteAllLines($handoffManifest, $handoffManifestLines,
        [Text.UTF8Encoding]::new($false))
    $handoffResult = Invoke-FFBStartRuntimeFixture `
        -Starter (Join-Path $handoffRoot 'Start-FFBInterceptor.ps1') `
        -GameExecutable (Join-Path $handoffRoot 'LICENSE') `
        -SimHubInstallPath $fakeSimHub -WorkingDirectory $handoffRoot `
        -OutputPath (Join-Path $temporaryRoot 'first-run-start-output.txt')
    try {
        Wait-FFBManagerHandoffSentinel -Path $sentinelPath `
            -ExpectedWorkingDirectory $handoffRoot
    }
    finally {
        if (Test-Path -LiteralPath $sentinelPath -PathType Leaf) {
            Remove-Item -LiteralPath $sentinelPath -Force
        }
    }
    if ($handoffResult.ExitCode -ne 0 -or
        $handoffResult.Text -notmatch 'setup is handled by FFBInterceptor Manager') {
        throw "Default Start did not hand missing installation state to Manager: $($handoffResult.Text)"
    }
    if ((Test-Path -LiteralPath $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY) -or
        (Test-Path -LiteralPath (Join-Path $fakeSimHub 'FFBInterceptor.SimHub.dll')) -or
        (Test-Path -LiteralPath (Join-Path $fakeSimHub 'FFBInterceptor.Core.dll'))) {
        throw 'Default Start Manager handoff wrote plug-in files or installation state.'
    }

    $runningSimHub = @(Get-Process -Name 'SimHub', 'SimHubWPF' -ErrorAction SilentlyContinue)
    Assert-FFBSimHubClosedForPackageLifecycle -RunningProcesses $runningSimHub

        $collision = Join-Path $fakeSimHub 'FFBInterceptor.SimHub.dll'
        [IO.Directory]::CreateDirectory($collision) | Out-Null
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -SimHubInstallPath $fakeSimHub `
            -NoElevation -NoDashboardImport -NoPause
        if ($LASTEXITCODE -eq 0) { throw 'Packaged installer accepted a directory at a managed-file destination.' }
        if (@(Get-ChildItem -LiteralPath $collision -Force).Count -ne 0) {
            throw 'Packaged installer moved a file into a managed-file destination directory.'
        }
        if (Test-Path -LiteralPath $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY) {
            throw 'Rejected directory collision created installation state.'
        }
        Remove-Item -LiteralPath $collision -Force

        $originalFiles = @{}
        foreach ($name in @('FFBInterceptor.SimHub.dll', 'FFBInterceptor.Core.dll')) {
            $destination = Join-Path $fakeSimHub $name
            [IO.File]::WriteAllText($destination, "original-$name", [Text.UTF8Encoding]::new($false))
            $originalFiles[$name] = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        }

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -SimHubInstallPath $fakeSimHub `
            -NoElevation -NoDashboardImport -NoPause
        if ($LASTEXITCODE -ne 0) { throw 'Packaged SimHub installer lifecycle smoke test failed.' }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -SimHubInstallPath $fakeSimHub `
            -NoElevation -NoDashboardImport -NoPause
        if ($LASTEXITCODE -ne 0) { throw 'Packaged SimHub installer is not idempotent.' }

        # An existing valid state belongs to exactly one SimHub directory. An
        # explicit different destination must fail before the idempotent
        # success path and must not write either destination or state.
        $differentSimHub = Join-Path $temporaryRoot 'different-fake-simhub'
        [IO.Directory]::CreateDirectory($differentSimHub) | Out-Null
        Copy-Item -LiteralPath $systemWhere `
            -Destination (Join-Path $differentSimHub 'SimHubWPF.exe')
        $differentStateFile = Join-Path $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY `
            'simhub-plugin-state.json'
        $differentStateHash = (Get-FileHash -LiteralPath $differentStateFile `
            -Algorithm SHA256).Hash
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer `
            -SimHubInstallPath $differentSimHub -NoElevation -NoDashboardImport -NoPause
        if ($LASTEXITCODE -eq 0) {
            throw 'Packaged installer reported success for an existing state in a different SimHub directory.'
        }
        foreach ($name in @('FFBInterceptor.SimHub.dll', 'FFBInterceptor.Core.dll')) {
            if (Test-Path -LiteralPath (Join-Path $differentSimHub $name)) {
                throw "Rejected different SimHub destination received a managed file: $name"
            }
        }
        if ((Get-FileHash -LiteralPath $differentStateFile -Algorithm SHA256).Hash -ne
            $differentStateHash) {
            throw 'Rejected different SimHub destination changed installation state.'
        }

        # Exercise the real daily Start path without -SkipSimHubCheck. The
        # expected .exe validation error proves setup/state/pipe checks passed.
        $pipe = [IO.Pipes.NamedPipeServerStream]::new(
            'ffb-interceptor-simhub-v1', [IO.Pipes.PipeDirection]::InOut, 1,
            [IO.Pipes.PipeTransmissionMode]::Byte, [IO.Pipes.PipeOptions]::Asynchronous)
        try {
            [void]$pipe.BeginWaitForConnection($null, $null)
            $defaultResult = Invoke-FFBStartRuntimeFixture `
                -Starter $starter -GameExecutable (Join-Path $packageRoot 'LICENSE') `
                -SimHubInstallPath $fakeSimHub -WorkingDirectory $packageRoot `
                -OutputPath (Join-Path $temporaryRoot 'daily-start-output.txt')
        }
        finally { $pipe.Dispose() }
        if ($defaultResult.ExitCode -eq 0 -or
            $defaultResult.Text -notmatch 'already installed and verified' -or
            $defaultResult.Text -notmatch 'selected file must be an \.exe' -or
            $defaultResult.Text -match 'Manager window') {
            throw "Packaged default Start path did not reach game validation: $($defaultResult.Text)"
        }

        $upgradeSource = Join-Path $packageRoot 'simhub\FFBInterceptor.Core.dll'
        $upgradeSourceBytes = [IO.File]::ReadAllBytes($upgradeSource)
        $installedCore = Join-Path $fakeSimHub 'FFBInterceptor.Core.dll'
        $installedCoreHash = (Get-FileHash -LiteralPath $installedCore -Algorithm SHA256).Hash
        $stateFile = Join-Path $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY 'simhub-plugin-state.json'
        $stateHash = (Get-FileHash -LiteralPath $stateFile -Algorithm SHA256).Hash
        try {
            [IO.File]::AppendAllText($upgradeSource, 'different-package-version')
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -SimHubInstallPath $fakeSimHub `
                -NoElevation -NoDashboardImport -NoPause
            if ($LASTEXITCODE -eq 0) { throw 'Packaged installer treated a different package version as already installed.' }
            if ((Get-FileHash -LiteralPath $installedCore -Algorithm SHA256).Hash -ne $installedCoreHash) {
                throw 'Rejected package upgrade changed the installed plug-in.'
            }
            if (-not (Test-Path -LiteralPath $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY -PathType Container)) {
                throw 'Rejected package upgrade removed installation state.'
            }
            if ((Get-FileHash -LiteralPath $stateFile -Algorithm SHA256).Hash -ne $stateHash) {
                throw 'Rejected package upgrade changed installation state.'
            }
        }
        finally {
            [IO.File]::WriteAllBytes($upgradeSource, $upgradeSourceBytes)
        }

        $tampered = Join-Path $fakeSimHub 'FFBInterceptor.SimHub.dll'
        [IO.File]::AppendAllText($tampered, 'tampered')
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uninstaller -NoElevation -NoPause
        if ($LASTEXITCODE -eq 0) { throw 'Packaged uninstaller accepted a changed managed file.' }
        Copy-Item -LiteralPath (Join-Path $packageRoot 'simhub\FFBInterceptor.SimHub.dll') `
            -Destination $tampered -Force

        $directoryCollision = Join-Path $fakeSimHub 'FFBInterceptor.Core.dll'
        Remove-Item -LiteralPath $directoryCollision -Force
        [IO.Directory]::CreateDirectory($directoryCollision) | Out-Null
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uninstaller -NoElevation -NoPause
        if ($LASTEXITCODE -eq 0) { throw 'Packaged uninstaller accepted a directory at a managed-file destination.' }
        if (-not (Test-Path -LiteralPath $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY -PathType Container)) {
            throw 'Rejected uninstall directory collision removed installation state.'
        }
        Remove-Item -LiteralPath $directoryCollision -Force
        Copy-Item -LiteralPath (Join-Path $packageRoot 'simhub\FFBInterceptor.Core.dll') `
            -Destination $directoryCollision

        # SimHub may be upgraded or manually removed before cleanup. The
        # protected state and locked directory identity are sufficient to
        # restore managed DLL backups; the main executable is not required.
        Remove-Item -LiteralPath (Join-Path $fakeSimHub 'SimHubWPF.exe') -Force
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uninstaller -NoElevation -NoPause
        if ($LASTEXITCODE -ne 0) { throw 'Packaged SimHub uninstaller lifecycle smoke test failed.' }
        foreach ($name in $originalFiles.Keys) {
            $restored = Join-Path $fakeSimHub $name
            if ((Get-FileHash -LiteralPath $restored -Algorithm SHA256).Hash -ne $originalFiles[$name]) {
                throw "Packaged uninstaller did not restore the original file: $name"
            }
        }
        if (Test-Path -LiteralPath $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY) {
            $leftoverState = @(Get-ChildItem -LiteralPath $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY -Force)
            if ($leftoverState.Count -ne 0) { throw 'Packaged uninstaller left installation state behind.' }
        }

    foreach ($architecture in @('x64', 'x86')) {
        $testTarget = Join-Path $packageRoot "launcher\$architecture\FFBInterceptor.Launcher.exe"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $starter -GameExecutable $testTarget `
            -SkipSimHubCheck -ValidateOnly -NoPause
        if ($LASTEXITCODE -ne 0) { throw "Packaged $architecture launcher validation failed." }
    }
}
finally {
    $env:FFB_INTERCEPTOR_PACKAGE_TEST = $originalPackageTest
    $env:FFB_INTERCEPTOR_TEST_STATE_DIRECTORY = $originalTestStateDirectory
    if (Test-Path -LiteralPath $temporaryRoot) {
        $cleanupError = $null
        for ($cleanupAttempt = 0; $cleanupAttempt -lt 50; $cleanupAttempt++) {
            try {
                Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
                $cleanupError = $null
                break
            }
            catch {
                $cleanupError = $_
                Start-Sleep -Milliseconds 100
            }
        }
        if ($null -ne $cleanupError) { throw $cleanupError }
    }
}

Write-Output "Launcher package validation passed: $archivePath"
