// SPDX-License-Identifier: GPL-3.0-only
using Microsoft.Win32.SafeHandles;
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading;

namespace FFBInterceptor.Core
{
    public sealed class SecurePipeServer : IDisposable
    {
        public const string DefaultPipePath = @"\\.\pipe\ffb-interceptor-simhub-v1";
        private const int MaximumClients = 32;
        private const int ReadBufferSize = 8192;
        private const int WorkerStopTimeoutMilliseconds = 5000;
        private const int ErrorBrokenPipe = 109;
        private const int ErrorNoData = 232;
        private const int ErrorOperationAborted = 995;
        private const int ErrorNotFound = 1168;

        private readonly string _pipePath;
        private readonly Action<SourceIdentity, Guid, double> _connected;
        private readonly Action<SourceKey, Guid, double> _disconnected;
        private readonly Action<SourceKey, ProtocolFrame, double> _frameReceived;
        private readonly Action _protocolError;
        private readonly Func<double> _clock;
        private readonly object _handlesGate = new object();
        private readonly HashSet<NamedPipeServerStream> _clients = new HashSet<NamedPipeServerStream>();
        private readonly Dictionary<NamedPipeServerStream, Thread> _clientThreads =
            new Dictionary<NamedPipeServerStream, Thread>();
        private readonly ManualResetEvent _stopSignal = new ManualResetEvent(false);
        private Thread _acceptThread;
        private NamedPipeServerStream _listener;
        private IntPtr _securityDescriptor;
        private volatile bool _running;
        private int _disposed;

        public SecurePipeServer(
            Action<SourceIdentity, Guid, double> connected,
            Action<SourceKey, Guid, double> disconnected,
            Action<SourceKey, ProtocolFrame, double> frameReceived,
            Action protocolError,
            Func<double> clock,
            string pipePath = DefaultPipePath)
        {
            _connected = connected ?? throw new ArgumentNullException(nameof(connected));
            _disconnected = disconnected ?? throw new ArgumentNullException(nameof(disconnected));
            _frameReceived = frameReceived ?? throw new ArgumentNullException(nameof(frameReceived));
            _protocolError = protocolError ?? throw new ArgumentNullException(nameof(protocolError));
            _clock = clock ?? throw new ArgumentNullException(nameof(clock));
            _pipePath = string.IsNullOrWhiteSpace(pipePath)
                ? throw new ArgumentException("pipe path is required", nameof(pipePath))
                : pipePath;
        }

        public void Start()
        {
            if (Volatile.Read(ref _disposed) != 0)
                throw new ObjectDisposedException(nameof(SecurePipeServer));
            lock (_handlesGate)
            {
                if (_running) return;
                if (_acceptThread != null || _clientThreads.Count != 0)
                    throw new InvalidOperationException("pipe server has not fully stopped");
                _securityDescriptor = CreateCurrentUserSecurityDescriptor();
                _stopSignal.Reset();
                _running = true;
                var thread = new Thread(AcceptLoop)
                {
                    IsBackground = true,
                    Name = "FFB Interceptor pipe acceptor",
                };
                _acceptThread = thread;
                try
                {
                    thread.Start();
                }
                catch
                {
                    _running = false;
                    _acceptThread = null;
                    _stopSignal.Set();
                    FreeSecurityDescriptor();
                    throw;
                }
            }
        }

        public void Stop()
        {
            Thread acceptThread;
            Thread[] clientThreads;
            NamedPipeServerStream listener;
            NamedPipeServerStream[] clients;
            lock (_handlesGate)
            {
                if (!_running && _acceptThread == null && _clientThreads.Count == 0)
                {
                    FreeSecurityDescriptor();
                    return;
                }
                _running = false;
                _stopSignal.Set();
                acceptThread = _acceptThread;
                listener = _listener;
                clients = new NamedPipeServerStream[_clients.Count];
                _clients.CopyTo(clients);
                clientThreads = new Thread[_clientThreads.Count];
                _clientThreads.Values.CopyTo(clientThreads, 0);
            }

            CancelAndDispose(listener);
            foreach (var client in clients) CancelAndDispose(client);

            var deadline = Environment.TickCount + WorkerStopTimeoutMilliseconds;
            var stopped = JoinBeforeDeadline(acceptThread, deadline);
            foreach (var thread in clientThreads)
                stopped = JoinBeforeDeadline(thread, deadline) && stopped;

            lock (_handlesGate)
            {
                if (stopped)
                {
                    _acceptThread = null;
                    _listener = null;
                    _clients.Clear();
                    _clientThreads.Clear();
                    FreeSecurityDescriptor();
                }
            }
            if (!stopped)
                throw new TimeoutException("FFB Interceptor pipe workers did not stop in time");
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
            Stop();
            _stopSignal.Dispose();
        }

        private void AcceptLoop()
        {
            while (_running)
            {
                NamedPipeServerStream pipe = null;
                try
                {
                    pipe = CreatePipeInstance();
                    lock (_handlesGate)
                    {
                        if (!_running)
                        {
                            pipe.Dispose();
                            break;
                        }
                        _listener = pipe;
                    }

                    if (!WaitForConnection(pipe))
                    {
                        pipe.Dispose();
                        continue;
                    }

                    lock (_handlesGate)
                    {
                        if (ReferenceEquals(_listener, pipe)) _listener = null;
                        if (!_running || _clients.Count >= MaximumClients)
                        {
                            pipe.Dispose();
                            continue;
                        }
                        var accepted = pipe;
                        var clientThread = new Thread(() => RunClient(accepted))
                        {
                            IsBackground = true,
                            Name = "FFB Interceptor pipe client",
                        };
                        _clients.Add(accepted);
                        _clientThreads.Add(accepted, clientThread);
                        try
                        {
                            clientThread.Start();
                            pipe = null;
                        }
                        catch
                        {
                            _clientThreads.Remove(accepted);
                            _clients.Remove(accepted);
                            accepted.Dispose();
                            throw;
                        }
                    }
                }
                catch (Exception)
                {
                    if (_running) SafeProtocolError();
                    pipe?.Dispose();
                    if (_running) Thread.Sleep(100);
                }
                finally
                {
                    lock (_handlesGate)
                    {
                        if (ReferenceEquals(_listener, pipe)) _listener = null;
                    }
                }
            }
        }

        private bool WaitForConnection(NamedPipeServerStream pipe)
        {
            IAsyncResult pending = null;
            WaitHandle completion = null;
            try
            {
                pending = pipe.BeginWaitForConnection(null, null);
                completion = pending.AsyncWaitHandle;
                if (WaitHandle.WaitAny(new[] { completion, _stopSignal }) == 1)
                {
                    CancelIo(pipe);
                    if (!completion.WaitOne(WorkerStopTimeoutMilliseconds))
                        throw new TimeoutException("pipe connection cancellation timed out");
                }
                pipe.EndWaitForConnection(pending);
                return _running;
            }
            catch (ObjectDisposedException) when (!_running)
            {
                return false;
            }
            catch (IOException) when (!_running)
            {
                return false;
            }
            finally
            {
                completion?.Close();
            }
        }

        private NamedPipeServerStream CreatePipeInstance()
        {
            var attributes = new NativeMethods.SecurityAttributes
            {
                Length = Marshal.SizeOf(typeof(NativeMethods.SecurityAttributes)),
                SecurityDescriptor = _securityDescriptor,
                InheritHandle = 0,
            };
            var handle = NativeMethods.CreateNamedPipe(
                _pipePath,
                NativeMethods.PipeAccessInbound | NativeMethods.FileFlagOverlapped,
                NativeMethods.PipeTypeByte | NativeMethods.PipeReadModeByte |
                    NativeMethods.PipeWait | NativeMethods.PipeRejectRemoteClients,
                MaximumClients,
                0,
                ProtocolDecoder.MaximumFrameSize,
                0,
                ref attributes);
            if (handle.IsInvalid)
            {
                var error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "CreateNamedPipe failed");
            }
            try
            {
                return new NamedPipeServerStream(PipeDirection.In, true, false, handle);
            }
            catch
            {
                handle.Dispose();
                throw;
            }
        }

        private void RunClient(NamedPipeServerStream pipe)
        {
            var connectionId = Guid.NewGuid();
            SourceKey? sourceKey = null;
            var accumulator = new FrameAccumulator();
            var buffer = new byte[ReadBufferSize];
            var hasSequence = false;
            ulong lastSequence = 0;
            try
            {
                uint clientProcessId;
                if (!NativeMethods.GetNamedPipeClientProcessId(pipe.SafePipeHandle, out clientProcessId) ||
                    clientProcessId == 0)
                    throw new ProtocolException("cannot verify pipe client process");

                while (_running)
                {
                    var bytesRead = ReadCancelable(pipe, buffer);
                    if (bytesRead <= 0) break;
                    foreach (var frame in accumulator.Feed(buffer, bytesRead))
                    {
                        if (hasSequence && frame.Sequence <= lastSequence)
                            throw new ProtocolException("frame sequence is not strictly increasing");
                        hasSequence = true;
                        lastSequence = frame.Sequence;

                        if (!sourceKey.HasValue)
                        {
                            if (frame.MessageType != MessageType.Hello)
                                throw new ProtocolException("first frame is not Hello");
                            if (frame.ProcessId != clientProcessId)
                                throw new ProtocolException("Hello process id does not match pipe client");
                            if (!IsSafeSessionId(frame.SessionId))
                                throw new ProtocolException("invalid session id");
                            var key = new SourceKey(clientProcessId, frame.SessionId);
                            sourceKey = key;
                            _connected(new SourceIdentity(
                                key,
                                SanitizeLabel(frame.Text, 63),
                                SanitizeLabel(frame.BuildVersion, 31),
                                frame.Flags == 32 || frame.Flags == 64 ? (int)frame.Flags : 0),
                                connectionId,
                                _clock());
                            continue;
                        }
                        if (frame.MessageType == MessageType.Hello)
                            throw new ProtocolException("duplicate Hello frame");
                        if (frame.ProcessId != clientProcessId)
                            throw new ProtocolException("frame process id does not match pipe client");
                        _frameReceived(sourceKey.Value, frame, _clock());
                    }
                }
                accumulator.Complete();
            }
            catch (ProtocolException)
            {
                if (_running) SafeProtocolError();
            }
            catch (Win32Exception exception) when (
                exception.NativeErrorCode == ErrorBrokenPipe ||
                exception.NativeErrorCode == ErrorNoData ||
                (!_running && exception.NativeErrorCode == ErrorOperationAborted))
            {
            }
            catch (ObjectDisposedException) when (!_running)
            {
            }
            catch (IOException) when (!_running)
            {
            }
            catch (Exception)
            {
                if (_running) SafeProtocolError();
            }
            finally
            {
                try
                {
                    if (sourceKey.HasValue)
                        _disconnected(sourceKey.Value, connectionId, _clock());
                }
                catch (Exception)
                {
                    if (_running) SafeProtocolError();
                }
                lock (_handlesGate)
                {
                    _clients.Remove(pipe);
                    _clientThreads.Remove(pipe);
                }
                pipe.Dispose();
            }
        }

        private int ReadCancelable(NamedPipeServerStream pipe, byte[] buffer)
        {
            IAsyncResult pending = null;
            WaitHandle completion = null;
            try
            {
                pending = pipe.BeginRead(buffer, 0, buffer.Length, null, null);
                completion = pending.AsyncWaitHandle;
                if (WaitHandle.WaitAny(new[] { completion, _stopSignal }) == 1)
                {
                    CancelIo(pipe);
                    if (!completion.WaitOne(WorkerStopTimeoutMilliseconds))
                        throw new TimeoutException("pipe read cancellation timed out");
                }
                return pipe.EndRead(pending);
            }
            finally
            {
                completion?.Close();
            }
        }

        private void SafeProtocolError()
        {
            try { _protocolError(); }
            catch (Exception) { }
        }

        private static void CancelAndDispose(NamedPipeServerStream pipe)
        {
            if (pipe == null) return;
            CancelIo(pipe);
            try { pipe.Dispose(); }
            catch (Exception) { }
        }

        private static void CancelIo(NamedPipeServerStream pipe)
        {
            if (pipe == null) return;
            try
            {
                if (pipe.SafePipeHandle.IsInvalid || pipe.SafePipeHandle.IsClosed) return;
                if (!NativeMethods.CancelIoEx(pipe.SafePipeHandle, IntPtr.Zero))
                {
                    var error = Marshal.GetLastWin32Error();
                    if (error != ErrorNotFound && error != ErrorOperationAborted)
                    {
                        // Cancellation is best-effort; disposal is the
                        // secondary wake-up path for the asynchronous worker.
                    }
                }
            }
            catch (Exception) { }
        }

        private static bool JoinBeforeDeadline(Thread thread, int deadline)
        {
            if (thread == null) return true;
            // Never declare a worker stopped while Stop is running on that
            // same worker; doing so could free the security descriptor and
            // clear ownership before its stack has unwound.
            if (thread == Thread.CurrentThread) return false;
            try
            {
                var remaining = unchecked(deadline - Environment.TickCount);
                if (remaining <= 0) return !thread.IsAlive;
                return thread.Join(remaining);
            }
            catch (ThreadStateException)
            {
                return !thread.IsAlive;
            }
        }

        private void FreeSecurityDescriptor()
        {
            if (_securityDescriptor == IntPtr.Zero) return;
            NativeMethods.LocalFree(_securityDescriptor);
            _securityDescriptor = IntPtr.Zero;
        }

        private static IntPtr CreateCurrentUserSecurityDescriptor()
        {
            using (var identity = WindowsIdentity.GetCurrent())
            {
                if (identity.User == null)
                    throw new InvalidOperationException("current Windows identity has no SID");
                var sddl = "D:P(A;;GA;;;SY)(A;;GA;;;" + identity.User.Value + ")";
                IntPtr descriptor;
                uint size;
                if (!NativeMethods.ConvertStringSecurityDescriptorToSecurityDescriptor(
                    sddl, 1, out descriptor, out size))
                    throw new Win32Exception(
                        Marshal.GetLastWin32Error(), "security descriptor creation failed");
                return descriptor;
            }
        }

        private static bool IsSafeSessionId(string value)
        {
            if (string.IsNullOrEmpty(value) || value.Length > 31) return false;
            foreach (var character in value)
            {
                if (!(character >= 'a' && character <= 'z') &&
                    !(character >= 'A' && character <= 'Z') &&
                    !(character >= '0' && character <= '9') &&
                    character != '-' && character != '_' && character != '.') return false;
            }
            return true;
        }

        private static string SanitizeLabel(string value, int maximumLength)
        {
            if (string.IsNullOrEmpty(value)) return string.Empty;
            var builder = new StringBuilder(Math.Min(value.Length, maximumLength));
            foreach (var character in value)
            {
                if (builder.Length >= maximumLength) break;
                if (!char.IsControl(character) && character != '\\' && character != '/')
                    builder.Append(character);
            }
            return builder.ToString();
        }

        private static class NativeMethods
        {
            internal const uint PipeAccessInbound = 0x00000001;
            internal const uint FileFlagOverlapped = 0x40000000;
            internal const uint PipeTypeByte = 0x00000000;
            internal const uint PipeReadModeByte = 0x00000000;
            internal const uint PipeWait = 0x00000000;
            internal const uint PipeRejectRemoteClients = 0x00000008;

            [StructLayout(LayoutKind.Sequential)]
            internal struct SecurityAttributes
            {
                internal int Length;
                internal IntPtr SecurityDescriptor;
                internal int InheritHandle;
            }

            [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
            internal static extern SafePipeHandle CreateNamedPipe(
                string name, uint openMode, uint pipeMode, int maximumInstances,
                uint outputBufferSize, uint inputBufferSize, uint defaultTimeout,
                ref SecurityAttributes securityAttributes);

            [DllImport("kernel32.dll", SetLastError = true)]
            [return: MarshalAs(UnmanagedType.Bool)]
            internal static extern bool CancelIoEx(SafePipeHandle file, IntPtr overlapped);

            [DllImport("kernel32.dll", SetLastError = true)]
            [return: MarshalAs(UnmanagedType.Bool)]
            internal static extern bool GetNamedPipeClientProcessId(
                SafePipeHandle pipe, out uint clientProcessId);

            [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
            [return: MarshalAs(UnmanagedType.Bool)]
            internal static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(
                string stringSecurityDescriptor, uint stringSdRevision,
                out IntPtr securityDescriptor, out uint securityDescriptorSize);

            [DllImport("kernel32.dll")]
            internal static extern IntPtr LocalFree(IntPtr memory);
        }
    }
}
