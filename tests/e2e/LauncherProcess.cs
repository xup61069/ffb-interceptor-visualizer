// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace FFBInterceptor.E2E.Tests
{
    internal sealed class LauncherProcessResult
    {
        internal LauncherProcessResult(
            int exitCode, string standardOutput, string standardError, bool usedLuaToken)
        {
            ExitCode = exitCode;
            StandardOutput = standardOutput ?? string.Empty;
            StandardError = standardError ?? string.Empty;
            UsedLuaToken = usedLuaToken;
        }

        internal int ExitCode { get; private set; }
        internal string StandardOutput { get; private set; }
        internal string StandardError { get; private set; }
        internal bool UsedLuaToken { get; private set; }
    }

    // GitHub-hosted Windows runners are administrators with UAC disabled, while
    // the production Launcher correctly refuses to start a game from an elevated
    // token. The test therefore creates and verifies a test-only LUA token rather
    // than weakening the production policy or compiling a bypass into the binary.
    internal static class LauncherProcess
    {
        private const uint TokenAssignPrimary = 0x0001;
        private const uint TokenDuplicate = 0x0002;
        private const uint TokenQuery = 0x0008;
        private const uint DisableMaxPrivilege = 0x0001;
        private const uint LuaToken = 0x0004;
        private const uint CreateUnicodeEnvironment = 0x00000400;
        private const uint CreateNoWindow = 0x08000000;
        private const uint StartfUseStdHandles = 0x00000100;
        private const uint HandleFlagInherit = 0x00000001;
        private const uint WaitObject0 = 0x00000000;
        private const uint WaitTimeout = 0x00000102;
        private const uint WaitFailed = 0xFFFFFFFF;
        private const int ErrorBrokenPipe = 109;
        private const int ErrorPrivilegeNotHeld = 1314;
        private const int TokenElevationClass = 20;

        [StructLayout(LayoutKind.Sequential)]
        private struct SidIdentifierAuthority
        {
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 6)]
            internal byte[] Value;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SidAndAttributes
        {
            internal IntPtr Sid;
            internal uint Attributes;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct TokenElevation
        {
            internal uint TokenIsElevated;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes
        {
            internal uint Length;
            internal IntPtr SecurityDescriptor;

            [MarshalAs(UnmanagedType.Bool)]
            internal bool InheritHandle;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct StartupInfo
        {
            internal uint Size;
            internal string Reserved;
            internal string Desktop;
            internal string Title;
            internal uint X;
            internal uint Y;
            internal uint XSize;
            internal uint YSize;
            internal uint XCountChars;
            internal uint YCountChars;
            internal uint FillAttribute;
            internal uint Flags;
            internal ushort ShowWindow;
            internal ushort Reserved2Size;
            internal IntPtr Reserved2;
            internal IntPtr StandardInput;
            internal IntPtr StandardOutput;
            internal IntPtr StandardError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInformation
        {
            internal IntPtr Process;
            internal IntPtr Thread;
            internal uint ProcessId;
            internal uint ThreadId;
        }

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr GetEnvironmentStringsW();

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool FreeEnvironmentStringsW(IntPtr environment);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreatePipe(
            out IntPtr readPipe, out IntPtr writePipe,
            ref SecurityAttributes pipeAttributes, uint size);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetHandleInformation(
            IntPtr handle, uint mask, uint flags);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ReadFile(
            IntPtr file, byte[] buffer, uint bytesToRead,
            out uint bytesRead, IntPtr overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool TerminateProcess(IntPtr process, uint exitCode);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool OpenProcessToken(
            IntPtr process, uint desiredAccess, out IntPtr token);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool AllocateAndInitializeSid(
            ref SidIdentifierAuthority identifierAuthority,
            byte subAuthorityCount,
            uint subAuthority0,
            uint subAuthority1,
            uint subAuthority2,
            uint subAuthority3,
            uint subAuthority4,
            uint subAuthority5,
            uint subAuthority6,
            uint subAuthority7,
            out IntPtr sid);

        [DllImport("advapi32.dll")]
        private static extern IntPtr FreeSid(IntPtr sid);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateRestrictedToken(
            IntPtr existingToken,
            uint flags,
            uint disableSidCount,
            [In] SidAndAttributes[] sidsToDisable,
            uint deletePrivilegeCount,
            IntPtr privilegesToDelete,
            uint restrictedSidCount,
            IntPtr sidsToRestrict,
            out IntPtr newToken);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetTokenInformation(
            IntPtr token,
            int tokenInformationClass,
            out TokenElevation tokenInformation,
            uint tokenInformationLength,
            out uint returnLength);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DuplicateToken(
            IntPtr existingToken, int impersonationLevel, out IntPtr duplicateToken);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CheckTokenMembership(
            IntPtr token, IntPtr sidToCheck,
            [MarshalAs(UnmanagedType.Bool)] out bool isMember);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProcessAsUserW(
            IntPtr token,
            string applicationName,
            StringBuilder commandLine,
            IntPtr processAttributes,
            IntPtr threadAttributes,
            [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
            uint creationFlags,
            IntPtr environment,
            string currentDirectory,
            ref StartupInfo startupInfo,
            out ProcessInformation processInformation);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProcessWithTokenW(
            IntPtr token,
            uint logonFlags,
            string applicationName,
            StringBuilder commandLine,
            uint creationFlags,
            IntPtr environment,
            string currentDirectory,
            ref StartupInfo startupInfo,
            out ProcessInformation processInformation);

        internal static LauncherProcessResult Run(
            string applicationName, string arguments, string currentDirectory,
            uint timeoutMilliseconds)
        {
            if (string.IsNullOrWhiteSpace(applicationName) || applicationName.IndexOf('"') >= 0)
                throw new ArgumentException("The launcher path is invalid.", "applicationName");

            return IsCurrentProcessElevated()
                ? RunWithLuaToken(applicationName, arguments, currentDirectory, timeoutMilliseconds)
                : RunDirect(applicationName, arguments, currentDirectory, timeoutMilliseconds);
        }

        private static LauncherProcessResult RunDirect(
            string applicationName, string arguments, string currentDirectory,
            uint timeoutMilliseconds)
        {
            using (var process = Process.Start(new ProcessStartInfo
            {
                FileName = applicationName,
                Arguments = arguments,
                WorkingDirectory = currentDirectory,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
            }))
            {
                if (process == null) throw new InvalidOperationException("launcher did not start");
                if (!process.WaitForExit(checked((int)timeoutMilliseconds)))
                {
                    process.Kill();
                    process.WaitForExit();
                    throw new TimeoutException("launcher timed out");
                }
                // A successful Launcher creates the deliberately long-lived
                // probe. Windows may propagate standard handles to that child
                // even when bInheritHandles is FALSE, so read redirected pipes
                // only on failure, when no probe remains to retain them.
                if (process.ExitCode == 0)
                    return new LauncherProcessResult(0, string.Empty, string.Empty, false);
                string output = process.StandardOutput.ReadToEnd();
                string error = process.StandardError.ReadToEnd();
                return new LauncherProcessResult(
                    process.ExitCode, output, error, false);
            }
        }

        private static bool IsCurrentProcessElevated()
        {
            IntPtr token = IntPtr.Zero;
            try
            {
                if (!OpenProcessToken(GetCurrentProcess(), TokenQuery, out token))
                    throw LastError("OpenProcessToken failed");
                return ReadTokenElevation(token, "current process") != 0;
            }
            finally
            {
                Close(ref token);
            }
        }

        private static uint ReadTokenElevation(IntPtr token, string description)
        {
            TokenElevation elevation;
            uint returned;
            if (!GetTokenInformation(
                token, TokenElevationClass, out elevation,
                (uint)Marshal.SizeOf(typeof(TokenElevation)), out returned) ||
                returned < Marshal.SizeOf(typeof(TokenElevation)))
            {
                throw LastError("Could not inspect " + description + " elevation");
            }
            return elevation.TokenIsElevated;
        }

        private static LauncherProcessResult RunWithLuaToken(
            string applicationName, string arguments, string currentDirectory,
            uint timeoutMilliseconds)
        {
            IntPtr sourceToken = IntPtr.Zero;
            IntPtr restrictedToken = IntPtr.Zero;
            IntPtr verificationToken = IntPtr.Zero;
            IntPtr administratorsSid = IntPtr.Zero;
            IntPtr standardInputRead = IntPtr.Zero;
            IntPtr standardInputWrite = IntPtr.Zero;
            IntPtr standardOutputRead = IntPtr.Zero;
            IntPtr standardOutputWrite = IntPtr.Zero;
            IntPtr standardErrorRead = IntPtr.Zero;
            IntPtr standardErrorWrite = IntPtr.Zero;
            IntPtr environment = IntPtr.Zero;
            ProcessInformation process = new ProcessInformation();
            try
            {
                if (!OpenProcessToken(
                    GetCurrentProcess(),
                    TokenAssignPrimary | TokenDuplicate | TokenQuery,
                    out sourceToken))
                {
                    throw LastError("OpenProcessToken failed");
                }

                var authority = new SidIdentifierAuthority
                {
                    Value = new byte[] { 0, 0, 0, 0, 0, 5 },
                };
                if (!AllocateAndInitializeSid(
                    ref authority, 2, 32, 544, 0, 0, 0, 0, 0, 0,
                    out administratorsSid))
                {
                    throw LastError("Could not create the Administrators SID");
                }

                var disabled = new[]
                {
                    new SidAndAttributes { Sid = administratorsSid, Attributes = 0 },
                };
                if (!CreateRestrictedToken(
                    sourceToken, DisableMaxPrivilege | LuaToken,
                    1, disabled, 0, IntPtr.Zero, 0, IntPtr.Zero,
                    out restrictedToken))
                {
                    throw LastError("CreateRestrictedToken(LUA_TOKEN) failed");
                }
                if (ReadTokenElevation(restrictedToken, "LUA token") != 0)
                    throw new InvalidOperationException("The test LUA token is still elevated.");

                bool isAdministrator;
                if (!DuplicateToken(restrictedToken, 2, out verificationToken) ||
                    !CheckTokenMembership(
                        verificationToken, administratorsSid, out isAdministrator))
                {
                    throw LastError("Could not verify the test LUA token");
                }
                if (isAdministrator)
                    throw new InvalidOperationException(
                        "The test LUA token retained Administrators membership.");

                CreatePipes(
                    out standardInputRead, out standardInputWrite,
                    out standardOutputRead, out standardOutputWrite,
                    out standardErrorRead, out standardErrorWrite);

                var startup = new StartupInfo
                {
                    Size = (uint)Marshal.SizeOf(typeof(StartupInfo)),
                    Flags = StartfUseStdHandles,
                    StandardInput = standardInputRead,
                    StandardOutput = standardOutputWrite,
                    StandardError = standardErrorWrite,
                };
                // CreateProcessWithTokenW does not inherit the caller's
                // environment when lpEnvironment is null. Pass an explicit
                // snapshot on both paths so coverage child-tracking variables
                // and the instrumented-runtime PATH survive the LUA boundary.
                environment = GetEnvironmentStringsW();
                if (environment == IntPtr.Zero)
                    throw LastError("Could not copy the test process environment");
                bool created = CreateProcessAsUserW(
                    restrictedToken, applicationName,
                    BuildCommandLine(applicationName, arguments),
                    IntPtr.Zero, IntPtr.Zero, true,
                    CreateNoWindow | CreateUnicodeEnvironment,
                    environment, currentDirectory, ref startup, out process);
                int createError = created ? 0 : Marshal.GetLastWin32Error();
                if (!created && createError == ErrorPrivilegeNotHeld)
                {
                    created = CreateProcessWithTokenW(
                        restrictedToken, 0, applicationName,
                        BuildCommandLine(applicationName, arguments),
                        CreateNoWindow | CreateUnicodeEnvironment,
                        environment, currentDirectory,
                        ref startup, out process);
                    createError = created ? 0 : Marshal.GetLastWin32Error();
                }
                if (!created)
                    throw new Win32Exception(
                        createError, "Could not start Launcher with the verified LUA token.");

                // The parent must release its copies so the readers observe EOF
                // when Launcher exits. Launcher emits only short status messages,
                // so reading after the wait cannot fill the anonymous pipe buffer.
                Close(ref process.Thread);
                Close(ref standardInputRead);
                Close(ref standardInputWrite);
                Close(ref standardOutputWrite);
                Close(ref standardErrorWrite);

                uint wait = WaitForSingleObject(process.Process, timeoutMilliseconds);
                if (wait == WaitTimeout)
                {
                    TerminateProcess(process.Process, 124);
                    WaitForSingleObject(process.Process, 5000);
                }
                else if (wait == WaitFailed)
                {
                    throw LastError("Waiting for Launcher failed");
                }
                else if (wait != WaitObject0)
                {
                    throw new InvalidOperationException(
                        "Waiting for Launcher returned an unexpected result.");
                }

                if (wait == WaitTimeout)
                    throw new TimeoutException("launcher timed out (verified LUA token)");

                uint exitCode;
                if (!GetExitCodeProcess(process.Process, out exitCode))
                    throw LastError("Could not read Launcher exit code");
                if (exitCode == 0)
                    return new LauncherProcessResult(0, string.Empty, string.Empty, true);
                string output = ReadPipe(standardOutputRead);
                string error = ReadPipe(standardErrorRead);
                return new LauncherProcessResult(
                    unchecked((int)exitCode), output, error, true);
            }
            finally
            {
                Close(ref process.Thread);
                Close(ref process.Process);
                Close(ref standardInputRead);
                Close(ref standardInputWrite);
                Close(ref standardOutputRead);
                Close(ref standardOutputWrite);
                Close(ref standardErrorRead);
                Close(ref standardErrorWrite);
                Close(ref verificationToken);
                Close(ref restrictedToken);
                Close(ref sourceToken);
                if (environment != IntPtr.Zero)
                {
                    FreeEnvironmentStringsW(environment);
                }
                if (administratorsSid != IntPtr.Zero)
                {
                    FreeSid(administratorsSid);
                }
            }
        }

        private static void CreatePipes(
            out IntPtr inputRead, out IntPtr inputWrite,
            out IntPtr outputRead, out IntPtr outputWrite,
            out IntPtr errorRead, out IntPtr errorWrite)
        {
            inputRead = IntPtr.Zero;
            inputWrite = IntPtr.Zero;
            outputRead = IntPtr.Zero;
            outputWrite = IntPtr.Zero;
            errorRead = IntPtr.Zero;
            errorWrite = IntPtr.Zero;
            var attributes = new SecurityAttributes
            {
                Length = (uint)Marshal.SizeOf(typeof(SecurityAttributes)),
                InheritHandle = true,
            };
            if (!CreatePipe(out inputRead, out inputWrite, ref attributes, 0) ||
                !SetHandleInformation(inputWrite, HandleFlagInherit, 0) ||
                !CreatePipe(out outputRead, out outputWrite, ref attributes, 0) ||
                !SetHandleInformation(outputRead, HandleFlagInherit, 0) ||
                !CreatePipe(out errorRead, out errorWrite, ref attributes, 0) ||
                !SetHandleInformation(errorRead, HandleFlagInherit, 0))
            {
                throw LastError("Could not create inherited Launcher pipes");
            }
        }

        private static StringBuilder BuildCommandLine(string applicationName, string arguments)
        {
            return new StringBuilder("\"" + applicationName + "\" " + arguments);
        }

        private static string ReadPipe(IntPtr pipe)
        {
            using (var bytes = new MemoryStream())
            {
                var buffer = new byte[4096];
                while (true)
                {
                    uint read;
                    if (!ReadFile(pipe, buffer, (uint)buffer.Length, out read, IntPtr.Zero))
                    {
                        int error = Marshal.GetLastWin32Error();
                        if (error == ErrorBrokenPipe) break;
                        throw new Win32Exception(error, "Could not read Launcher output.");
                    }
                    if (read == 0) break;
                    bytes.Write(buffer, 0, checked((int)read));
                }
                return Encoding.UTF8.GetString(bytes.ToArray());
            }
        }

        private static Win32Exception LastError(string message)
        {
            return new Win32Exception(Marshal.GetLastWin32Error(), message);
        }

        private static void Close(ref IntPtr handle)
        {
            if (handle == IntPtr.Zero) return;
            CloseHandle(handle);
            handle = IntPtr.Zero;
        }
    }
}
