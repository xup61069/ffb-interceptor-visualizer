// SPDX-License-Identifier: GPL-3.0-only
using FFBInterceptor.Core;
using GameReaderCommon;
using SimHub.Plugins;
using System;
using System.Globalization;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace FFBInterceptor.SimHub
{
    [PluginDescription("DirectInput force-feedback command clipping detector for FFB Interceptor")]
    [PluginAuthor("FFB Interceptor contributors")]
    [PluginName("FFB Interceptor")]
    public sealed class FFBInterceptor : IPlugin, IDataPlugin, IWPFSettingsV2
    {
        private static readonly ImageSource MenuIcon = CreateMenuIcon();
        private readonly GlobalClippingEventGate _globalClippingEvents = new GlobalClippingEventGate();
        private readonly SourceCountEventGate _sourceCountEvents = new SourceCountEventGate();
        private MonitorService _monitor;
        private ClippingSnapshot _published = ClippingSnapshot.Empty;
        private string _startupError = string.Empty;

        public PluginManager PluginManager { get; set; }
        public DetectorSettings Settings { get; private set; } = DetectorSettings.Defaults();
        public ImageSource PictureIcon => MenuIcon;
        public string LeftMenuTitle => "FFB Interceptor";
        public ClippingSnapshot CurrentSnapshot => Volatile.Read(ref _published);
        public string StartupError => _startupError;

        public void Init(PluginManager pluginManager)
        {
            _globalClippingEvents.Reset();
            _sourceCountEvents.Reset();
            try
            {
                Settings = this.ReadCommonSettings<DetectorSettings>(
                    "GeneralSettings", DetectorSettings.Defaults).CloneNormalized();
            }
            catch (Exception exception)
            {
                Settings = DetectorSettings.Defaults();
                global::SimHub.Logging.Current.Error(
                    "FFB Interceptor: invalid settings; defaults restored: " + exception);
            }
            AttachProperties();
            this.AddEvent("ClippingStarted");
            this.AddEvent("ClippingEnded");
            this.AddEvent("SourceConnected");
            this.AddEvent("SourceDisconnected");
            this.AddAction("ResetPeak", (a, b) => ResetPeak());
            this.AddAction("UseAutomaticSource", (a, b) => UseAutomaticSource());

            try
            {
                _monitor = new MonitorService(Settings);
                _monitor.Start();
                global::SimHub.Logging.Current.Info("FFB Interceptor: SimHub telemetry pipe started");
            }
            catch (Exception exception)
            {
                _startupError = exception.Message;
                try { _monitor?.Dispose(); }
                catch (Exception disposeException)
                {
                    global::SimHub.Logging.Current.Error(
                        "FFB Interceptor: startup cleanup failed: " + disposeException);
                }
                _monitor = null;
                global::SimHub.Logging.Current.Error("FFB Interceptor: startup failed: " + exception);
            }
        }

        public void DataUpdate(PluginManager pluginManager, ref GameData data)
        {
            try
            {
                var monitor = _monitor;
                var snapshot = monitor?.Snapshot ?? ClippingSnapshot.Empty;
                Volatile.Write(ref _published, snapshot);
                if (monitor == null) return;
                var clippingTransition = _globalClippingEvents.Update(snapshot.AnyClipping);
                if (clippingTransition == DetectorTransitionKind.ClippingStarted)
                    this.TriggerEvent("ClippingStarted");
                else if (clippingTransition == DetectorTransitionKind.ClippingEnded)
                    this.TriggerEvent("ClippingEnded");
                var sourceTransition = _sourceCountEvents.Update(snapshot.SourceCount);
                if (sourceTransition == DetectorTransitionKind.SourceConnected)
                    this.TriggerEvent("SourceConnected");
                else if (sourceTransition == DetectorTransitionKind.SourceDisconnected)
                    this.TriggerEvent("SourceDisconnected");
                DetectorTransition transition;
                for (var count = 0; count < 16 && monitor.TryDequeueTransition(out transition); count++) { }
            }
            catch
            {
                // SimHub calls this on its critical game-data path. Telemetry
                // is best-effort and must never disturb the host update loop.
            }
        }

        public void End(PluginManager pluginManager)
        {
            var monitor = Interlocked.Exchange(ref _monitor, null);
            try
            {
                monitor?.Dispose();
            }
            catch (Exception exception)
            {
                global::SimHub.Logging.Current.Error("FFB Interceptor: shutdown failed: " + exception);
            }
            try
            {
                this.SaveCommonSettings("GeneralSettings", Settings);
            }
            catch (Exception exception)
            {
                global::SimHub.Logging.Current.Error("FFB Interceptor: settings save failed: " + exception);
            }
            Volatile.Write(ref _published, ClippingSnapshot.Empty);
            _globalClippingEvents.Reset();
            _sourceCountEvents.Reset();
        }

        public Control GetWPFSettingsControl(PluginManager pluginManager)
        {
            return new SettingsControl(this);
        }

        public void ApplySettings(DetectorSettings settings)
        {
            Settings = (settings ?? DetectorSettings.Defaults()).CloneNormalized();
            try
            {
                _monitor?.UpdateSettings(Settings);
                this.SaveCommonSettings("GeneralSettings", Settings);
            }
            catch (Exception exception)
            {
                global::SimHub.Logging.Current.Error("FFB Interceptor: applying settings failed: " + exception);
            }
        }

        public void ResetPeak()
        {
            try { _monitor?.ResetPeak(); }
            catch (ObjectDisposedException) { }
        }

        public void UseAutomaticSource()
        {
            var settings = Settings.CloneNormalized();
            settings.AutoSelectSource = true;
            ApplySettings(settings);
        }

        private void AttachProperties()
        {
            this.AttachDelegate("Connected", () => CurrentSnapshot.Connected);
            this.AttachDelegate("SourceCount", () => CurrentSnapshot.SourceCount);
            this.AttachDelegate("ManualSourceAvailable", () => CurrentSnapshot.ManualSourceAvailable);
            this.AttachDelegate("SelectionMode", () => CurrentSnapshot.SelectionMode);
            this.AttachDelegate("SelectedProcessName", () => CurrentSnapshot.SelectedProcessName);
            this.AttachDelegate("SelectedProcessId", () => (double)CurrentSnapshot.SelectedProcessId);
            this.AttachDelegate("SelectedSessionId", () => CurrentSnapshot.SelectedSessionId);
            this.AttachDelegate("ProxyBuildVersion", () => CurrentSnapshot.ProxyBuildVersion);
            this.AttachDelegate("ProducerBitness", () => CurrentSnapshot.ProducerBitness);
            this.AttachDelegate("CommandLevel", () => CurrentSnapshot.CommandLevel);
            this.AttachDelegate("CommandPercent", () => CurrentSnapshot.CommandLevel * 100.0);
            this.AttachDelegate("PeakCommandPercent", () => CurrentSnapshot.PeakCommandLevel * 100.0);
            this.AttachDelegate("EffectiveCommandPercent", () => CurrentSnapshot.EffectiveCommandLevel * 100.0);
            this.AttachDelegate("EffectGainPercent", () => CurrentSnapshot.EffectGain * 100.0);
            this.AttachDelegate("DeviceGainPercent", () => CurrentSnapshot.DeviceGain * 100.0);
            this.AttachDelegate("AtLimit", () => CurrentSnapshot.AtLimit);
            this.AttachDelegate("IsClipping", () => CurrentSnapshot.IsClipping);
            this.AttachDelegate("AnyClipping", () => CurrentSnapshot.AnyClipping);
            this.AttachDelegate("DataReliable", () => CurrentSnapshot.DataReliable);
            this.AttachDelegate("ClipRatio1s", () => CurrentSnapshot.ClipRatio);
            this.AttachDelegate("ClipPercent1s", () => CurrentSnapshot.ClipRatio * 100.0);
            this.AttachDelegate("ClipRatio", () => CurrentSnapshot.ClipRatio);
            this.AttachDelegate("ClipPercent", () => CurrentSnapshot.ClipRatio * 100.0);
            this.AttachDelegate("RatioWindowMilliseconds", () => CurrentSnapshot.RatioWindowMilliseconds);
            this.AttachDelegate("ClipWindowText", () => string.Format(
                CultureInfo.InvariantCulture,
                "CLIP {0:0.###}S",
                CurrentSnapshot.RatioWindowMilliseconds / 1000.0));
            this.AttachDelegate("ActiveEffectCount", () => CurrentSnapshot.ActiveEffectCount);
            this.AttachDelegate("UnsupportedEffectCount", () => CurrentSnapshot.UnsupportedEffectCount);
            this.AttachDelegate("LastEffectKind", () => CurrentSnapshot.LastEffectKind);
            this.AttachDelegate("DroppedFrames", () => (double)CurrentSnapshot.DroppedFrames);
            this.AttachDelegate("ProtocolErrors", () => (double)CurrentSnapshot.ProtocolErrors);
            this.AttachDelegate("StatusText", () => CurrentSnapshot.StatusText);
            this.AttachDelegate("EntryThresholdPercent", () => CurrentSnapshot.EntryThreshold * 100.0);
            this.AttachDelegate("ExitThresholdPercent", () => CurrentSnapshot.ExitThreshold * 100.0);
            this.AttachDelegate("ThresholdText", () => string.Format(
                CultureInfo.InvariantCulture,
                "{0:0.#}% / {1:0.#}% HYSTERESIS",
                CurrentSnapshot.EntryThreshold * 100.0,
                CurrentSnapshot.ExitThreshold * 100.0));
            this.AttachDelegate("Definition", () => CurrentSnapshot.Definition);
        }

        private static ImageSource CreateMenuIcon()
        {
            var group = new DrawingGroup();
            group.Children.Add(new GeometryDrawing(
                Brushes.Transparent,
                new Pen(Brushes.White, 1.5),
                new RectangleGeometry(new Rect(2, 3, 20, 18), 2, 2)));
            group.Children.Add(new GeometryDrawing(
                Brushes.White,
                null,
                Geometry.Parse("M 5,16 L 5,12 L 8,12 L 8,16 Z M 10,16 L 10,8 L 13,8 L 13,16 Z M 15,16 L 15,5 L 19,5 L 19,16 Z")));
            group.Freeze();
            var image = new DrawingImage(group);
            image.Freeze();
            return image;
        }
    }
}
