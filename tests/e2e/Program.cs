// SPDX-License-Identifier: GPL-3.0-only
using FFBInterceptor.Core;
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Threading;

namespace FFBInterceptor.E2E.Tests
{
    internal static class Program
    {
        private static int Main(string[] args)
        {
            try
            {
                if (args.Length == 2 && string.Equals(
                        args[0], "--grant-interactive-desktop", StringComparison.Ordinal))
                {
                    Console.WriteLine(InteractiveDesktopAcl.Grant(args[1]));
                    return 0;
                }
                if (args.Length == 2 && string.Equals(
                        args[0], "--restore-interactive-desktop", StringComparison.Ordinal))
                {
                    InteractiveDesktopAcl.Restore(args[1]);
                    return 0;
                }
                if (args.Length != 2)
                {
                    Console.Error.WriteLine(
                        "usage: FFBInterceptor.E2E.Tests <launcher.exe> <probe.exe>");
                    return 2;
                }
                Run(Path.GetFullPath(args[0]), Path.GetFullPath(args[1]));
                Console.WriteLine("PASS launcher -> hook -> DirectInput8 -> secure pipe -> SimHub core");
                return 0;
            }
            catch (Exception error)
            {
                Console.Error.WriteLine("FAIL " + error);
                return 1;
            }
        }

        private static void Run(string launcherPath, string probePath)
        {
            RequireStandardUserToken();
            RequireFile(launcherPath);
            RequireFile(probePath);
            var hookPath = Path.Combine(Path.GetDirectoryName(launcherPath), "FFBInterceptor.Hook.dll");
            RequireFile(hookPath);
            if (File.Exists(Path.Combine(Path.GetDirectoryName(probePath), "dinput8.dll")))
                throw new InvalidOperationException("probe directory must not contain dinput8.dll");

            var sourceObserved = new ManualResetEventSlim(false);
            var deviceObserved = new ManualResetEventSlim(false);
            var engine = new ClippingEngine(DetectorSettings.Defaults());
            SourceIdentity identity = null;
            var protocolErrors = 0;
            var activeConnections = 0;
            using (sourceObserved)
            using (deviceObserved)
            using (var server = new SecurePipeServer(
                (source, connection, now) =>
                {
                    identity = source;
                    engine.Connect(source, connection, now);
                    Interlocked.Increment(ref activeConnections);
                    sourceObserved.Set();
                },
                (key, connection, now) =>
                {
                    engine.Disconnect(key, connection, now);
                    Interlocked.Decrement(ref activeConnections);
                },
                (key, frame, now) =>
                {
                    engine.ProcessFrame(key, frame, now);
                    if (frame.MessageType == MessageType.DeviceCreated &&
                        frame.HResult >= 0 && frame.DeviceId != 0)
                        deviceObserved.Set();
                },
                () =>
                {
                    Interlocked.Increment(ref protocolErrors);
                    engine.ReportProtocolError();
                },
                NowMilliseconds))
            {
                server.Start();
                using (var launcher = Process.Start(new ProcessStartInfo
                {
                    FileName = launcherPath,
                    Arguments = "--offline-only --game " + Quote(probePath) + " -- --hold-ms 5000",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                }))
                {
                    if (launcher == null) throw new InvalidOperationException("launcher did not start");
                    if (!launcher.WaitForExit(15000))
                    {
                        launcher.Kill();
                        throw new TimeoutException("launcher timed out");
                    }
                    if (launcher.ExitCode != 0)
                        throw new InvalidOperationException("launcher exit " + launcher.ExitCode);
                }

                if (!sourceObserved.Wait(8000))
                    throw new TimeoutException(
                        "producer Hello was not observed; active=" +
                        Volatile.Read(ref activeConnections) + ", protocolErrors=" +
                        Volatile.Read(ref protocolErrors));
                if (!deviceObserved.Wait(8000)) throw new TimeoutException("DeviceCreated was not observed");
                if (identity == null || !string.Equals(identity.ProcessName, Path.GetFileName(probePath),
                    StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("unexpected producer identity");
                if (string.IsNullOrWhiteSpace(identity.BuildVersion))
                    throw new InvalidOperationException("producer build version is missing");
                if (Volatile.Read(ref protocolErrors) != 0)
                    throw new InvalidOperationException("secure pipe reported a protocol error");
                var snapshot = engine.Tick(NowMilliseconds());
                if (!snapshot.Connected)
                    throw new InvalidOperationException(
                        "SimHub core did not publish the connected source; active=" +
                        Volatile.Read(ref activeConnections) + ", protocolErrors=" + protocolErrors);
                if (!snapshot.DataReliable && snapshot.ReliabilityIssues == DetectorReliabilityIssue.None)
                    throw new InvalidOperationException("unreliable data was not accompanied by a diagnostic");
                using (var probe = Process.GetProcessById((int)identity.Key.ProcessId))
                {
                    if (!probe.WaitForExit(10000))
                    {
                        probe.Kill();
                        throw new TimeoutException("DirectInput probe did not exit");
                    }
                }
            }
        }

        private static void RequireFile(string path)
        {
            if (!File.Exists(path)) throw new FileNotFoundException("required E2E file is missing", path);
        }

        private static void RequireStandardUserToken()
        {
            string sid;
            using (var identity = WindowsIdentity.GetCurrent())
            {
                sid = identity.User == null ? null : identity.User.Value;
                if (string.IsNullOrWhiteSpace(sid))
                    throw new InvalidOperationException("current Windows user SID is unavailable");
                if (new WindowsPrincipal(identity).IsInRole(
                        WindowsBuiltInRole.Administrator))
                    throw new InvalidOperationException(
                        "E2E must run outside the local Administrators group; SID=" + sid);
            }

            IntPtr token;
            if (!OpenProcessToken(GetCurrentProcess(), TokenQuery, out token))
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "OpenProcessToken failed");
            try
            {
                TokenElevationInfo elevation;
                int returnedLength;
                if (!GetTokenInformation(token, TokenElevationClass, out elevation,
                        Marshal.SizeOf(typeof(TokenElevationInfo)), out returnedLength))
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "GetTokenInformation(TokenElevation) failed");
                if (returnedLength < Marshal.SizeOf(typeof(TokenElevationInfo)))
                    throw new InvalidOperationException("TokenElevation result was truncated");
                if (elevation.TokenIsElevated != 0)
                    throw new InvalidOperationException(
                        "E2E must run with TokenElevation=0; SID=" + sid);
            }
            finally
            {
                CloseHandle(token);
            }
            Console.WriteLine("INFO standard-user token verified; SID=" + sid +
                ", TokenElevation=0");
        }

        private const uint TokenQuery = 0x0008;
        private const int TokenElevationClass = 20;

        [StructLayout(LayoutKind.Sequential)]
        private struct TokenElevationInfo
        {
            public int TokenIsElevated;
        }

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool OpenProcessToken(
            IntPtr processHandle, uint desiredAccess, out IntPtr tokenHandle);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetTokenInformation(
            IntPtr tokenHandle, int tokenInformationClass,
            out TokenElevationInfo tokenInformation, int tokenInformationLength,
            out int returnLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        private static string Quote(string value) { return "\"" + value.Replace("\"", "\\\"") + "\""; }

        private static double NowMilliseconds()
        {
            return Stopwatch.GetTimestamp() * 1000.0 / Stopwatch.Frequency;
        }
    }
}
