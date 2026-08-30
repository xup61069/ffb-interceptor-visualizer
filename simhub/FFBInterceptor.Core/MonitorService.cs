// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Diagnostics;
using System.Threading;

namespace FFBInterceptor.Core
{
    public sealed class MonitorService : IDisposable
    {
        private readonly ClippingEngine _engine;
        private readonly SecurePipeServer _pipeServer;
        private readonly Timer _timer;
        private ClippingSnapshot _snapshot = ClippingSnapshot.Empty;
        private int _started;
        private int _disposed;
        private int _tickActive;

        public MonitorService(DetectorSettings settings)
        {
            _engine = new ClippingEngine(settings);
            _pipeServer = new SecurePipeServer(
                _engine.Connect,
                _engine.Disconnect,
                _engine.ProcessFrame,
                _engine.ReportProtocolError,
                NowMilliseconds);
            _timer = new Timer(Tick, null, Timeout.Infinite, Timeout.Infinite);
        }

        public ClippingSnapshot Snapshot => Volatile.Read(ref _snapshot);

        public void Start()
        {
            ThrowIfDisposed();
            if (Interlocked.Exchange(ref _started, 1) != 0) return;
            try
            {
                _pipeServer.Start();
                _timer.Change(0, 16);
            }
            catch
            {
                Interlocked.Exchange(ref _started, 0);
                try { _pipeServer.Stop(); }
                catch (Exception) { }
                throw;
            }
        }

        public void UpdateSettings(DetectorSettings settings)
        {
            ThrowIfDisposed();
            _engine.UpdateSettings(settings);
        }

        public void ResetPeak()
        {
            ThrowIfDisposed();
            _engine.ResetPeak();
        }

        public bool TryDequeueTransition(out DetectorTransition transition)
        {
            return _engine.TryDequeueTransition(out transition);
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
            _timer.Change(Timeout.Infinite, Timeout.Infinite);
            try
            {
                _pipeServer.Dispose();
            }
            finally
            {
                _timer.Dispose();
                Interlocked.Exchange(ref _started, 0);
            }
        }

        private void Tick(object state)
        {
            if (Volatile.Read(ref _disposed) != 0) return;
            if (Interlocked.Exchange(ref _tickActive, 1) != 0) return;
            try
            {
                Volatile.Write(ref _snapshot, _engine.Tick(NowMilliseconds()));
            }
            catch
            {
                _engine.ReportProtocolError();
            }
            finally
            {
                Volatile.Write(ref _tickActive, 0);
            }
        }

        private static double NowMilliseconds()
        {
            return Stopwatch.GetTimestamp() * 1000.0 / Stopwatch.Frequency;
        }

        private void ThrowIfDisposed()
        {
            if (Volatile.Read(ref _disposed) != 0) throw new ObjectDisposedException(nameof(MonitorService));
        }
    }
}
