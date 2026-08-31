// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;

namespace FFBInterceptor.E2E.Tests
{
    internal static class InteractiveDesktopAcl
    {
        private const int DaclSecurityInformation = 0x00000004;
        private const int WindowStationAllAccess = 0x000F037F;
        private const int DesktopAllAccess = 0x000F01FF;

        internal static string Grant(string sidValue)
        {
            var sid = new SecurityIdentifier(sidValue);
            var station = RequireHandle(GetProcessWindowStation(), "window station");
            var desktop = RequireHandle(
                GetThreadDesktop(GetCurrentThreadId()), "desktop");
            var stationOriginal = ReadDescriptor(station, "window station");
            var desktopOriginal = ReadDescriptor(desktop, "desktop");
            var stationUpdated = AddAllowedAce(
                stationOriginal, sid, WindowStationAllAccess, true);
            var desktopUpdated = AddAllowedAce(
                desktopOriginal, sid, DesktopAllAccess, false);
            var backup = Convert.ToBase64String(stationOriginal) + "." +
                Convert.ToBase64String(stationUpdated) + "." +
                Convert.ToBase64String(desktopOriginal) + "." +
                Convert.ToBase64String(desktopUpdated);

            var stationWritten = false;
            var desktopWritten = false;
            try
            {
                WriteDescriptor(station, stationUpdated, "window station");
                stationWritten = true;
                WriteDescriptor(desktop, desktopUpdated, "desktop");
                desktopWritten = true;
                return backup;
            }
            catch (Exception primary)
            {
                var errors = new List<Exception> { primary };
                if (desktopWritten)
                    TryRestoreUnchanged(
                        desktop, desktopOriginal, desktopUpdated,
                        "desktop", errors);
                if (stationWritten)
                    TryRestoreUnchanged(
                        station, stationOriginal, stationUpdated,
                        "window station", errors);
                if (errors.Count > 1)
                    throw new AggregateException(
                        "Interactive desktop grant failed and rollback was incomplete.",
                        errors);
                throw;
            }
        }

        internal static void Restore(string backup)
        {
            if (string.IsNullOrWhiteSpace(backup))
                throw new ArgumentException("desktop ACL backup is required", nameof(backup));
            var parts = backup.Split(new[] { '.' }, StringSplitOptions.None);
            if (parts.Length != 4)
                throw new ArgumentException("desktop ACL backup is malformed", nameof(backup));
            var stationOriginal = Convert.FromBase64String(parts[0]);
            var stationUpdated = Convert.FromBase64String(parts[1]);
            var desktopOriginal = Convert.FromBase64String(parts[2]);
            var desktopUpdated = Convert.FromBase64String(parts[3]);
            var station = RequireHandle(GetProcessWindowStation(), "window station");
            var desktop = RequireHandle(
                GetThreadDesktop(GetCurrentThreadId()), "desktop");
            var errors = new List<Exception>();
            TryRestoreUnchanged(
                desktop, desktopOriginal, desktopUpdated, "desktop", errors);
            TryRestoreUnchanged(
                station, stationOriginal, stationUpdated,
                "window station", errors);
            if (errors.Count > 0)
                throw new AggregateException(
                    "Interactive desktop ACL restoration was incomplete.", errors);
        }

        private static byte[] AddAllowedAce(
            byte[] original, SecurityIdentifier sid, int accessMask,
            bool isContainer)
        {
            var descriptor = new CommonSecurityDescriptor(
                isContainer, false, original, 0);
            descriptor.DiscretionaryAcl.AddAccess(
                AccessControlType.Allow,
                sid,
                accessMask,
                InheritanceFlags.None,
                PropagationFlags.None);
            var updated = new byte[descriptor.BinaryLength];
            descriptor.GetBinaryForm(updated, 0);
            return updated;
        }

        private static byte[] ReadDescriptor(IntPtr handle, string label)
        {
            var information = DaclSecurityInformation;
            uint required;
            GetUserObjectSecurity(handle, ref information, null, 0, out required);
            if (required == 0)
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(), "Could not size " + label + " DACL");
            var descriptor = new byte[required];
            if (!GetUserObjectSecurity(
                    handle, ref information, descriptor,
                    (uint)descriptor.Length, out required))
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(), "Could not read " + label + " DACL");
            return descriptor;
        }

        private static void WriteDescriptor(
            IntPtr handle, byte[] descriptor, string label)
        {
            var information = DaclSecurityInformation;
            if (!SetUserObjectSecurity(handle, ref information, descriptor))
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(), "Could not write " + label + " DACL");
        }

        private static void TryRestoreUnchanged(
            IntPtr handle, byte[] original, byte[] expected, string label,
            ICollection<Exception> errors)
        {
            try
            {
                var current = ReadDescriptor(handle, label);
                if (!DescriptorEquals(current, expected))
                    throw new InvalidOperationException(
                        label + " DACL changed after the E2E grant; " +
                        "refusing to overwrite another update");
                WriteDescriptor(handle, original, label);
            }
            catch (Exception error) { errors.Add(error); }
        }

        private static bool DescriptorEquals(byte[] left, byte[] right)
        {
            if (left == null || right == null || left.Length != right.Length)
                return false;
            for (var index = 0; index < left.Length; ++index)
                if (left[index] != right[index]) return false;
            return true;
        }

        private static IntPtr RequireHandle(IntPtr handle, string label)
        {
            if (handle == IntPtr.Zero)
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(), "Could not open current " + label);
            return handle;
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr GetProcessWindowStation();

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr GetThreadDesktop(uint threadId);

        [DllImport("kernel32.dll")]
        private static extern uint GetCurrentThreadId();

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetUserObjectSecurity(
            IntPtr handle,
            ref int requestedInformation,
            [Out] byte[] securityDescriptor,
            uint descriptorLength,
            out uint requiredLength);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetUserObjectSecurity(
            IntPtr handle,
            ref int requestedInformation,
            byte[] securityDescriptor);
    }
}
