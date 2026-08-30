// SPDX-License-Identifier: GPL-3.0-only
using FFBInterceptor.Core;
using System;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;

namespace FFBInterceptor.SimHub
{
    public partial class SettingsControl : UserControl
    {
        private readonly FFBInterceptor _plugin;
        private readonly DispatcherTimer _statusTimer;
        private bool _initialized;

        public SettingsControl(FFBInterceptor plugin)
        {
            _plugin = plugin ?? throw new ArgumentNullException(nameof(plugin));
            InitializeComponent();
            LoadSettings(_plugin.Settings);
            StartupErrorText.Text = string.IsNullOrEmpty(_plugin.StartupError)
                ? string.Empty : "啟動錯誤：" + _plugin.StartupError;
            _initialized = true;
            UpdateSourceMode();
            _statusTimer = new DispatcherTimer(DispatcherPriority.Background)
            {
                Interval = TimeSpan.FromMilliseconds(250),
            };
            _statusTimer.Tick += (_, __) => UpdateStatus();
            _statusTimer.Start();
            Unloaded += (_, __) => _statusTimer.Stop();
            UpdateStatus();
        }

        private void LoadSettings(DetectorSettings settings)
        {
            EntryThresholdBox.Text = settings.EntryThresholdPercent.ToString("0.###", CultureInfo.InvariantCulture);
            ExitThresholdBox.Text = settings.ExitThresholdPercent.ToString("0.###", CultureInfo.InvariantCulture);
            ContinuousBox.Text = settings.ContinuousLimitMilliseconds.ToString(CultureInfo.InvariantCulture);
            RatioBox.Text = settings.RatioTriggerPercent.ToString("0.###", CultureInfo.InvariantCulture);
            WindowBox.Text = settings.RatioWindowMilliseconds.ToString(CultureInfo.InvariantCulture);
            ExitHoldBox.Text = settings.ExitHoldMilliseconds.ToString(CultureInfo.InvariantCulture);
            AutoSelectCheckBox.IsChecked = settings.AutoSelectSource;
            ManualPidBox.Text = settings.ManualProcessId.ToString(CultureInfo.InvariantCulture);
            ManualSessionBox.Text = settings.ManualSessionId ?? string.Empty;
        }

        private void UpdateStatus()
        {
            var snapshot = _plugin.CurrentSnapshot;
            StatusText.Text = snapshot.StatusText;
            SourceText.Text = snapshot.Connected
                ? snapshot.SelectedProcessName + " · PID " + snapshot.SelectedProcessId + " · " + snapshot.SelectionMode
                : snapshot.SourceCount + " 個 producer · " + snapshot.SelectionMode;
            LevelText.Text = (snapshot.CommandLevel * 100.0).ToString("0.0", CultureInfo.InvariantCulture) + "%";
            LevelText.Foreground = snapshot.IsClipping
                ? new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(255, 82, 82))
                : snapshot.AtLimit
                    ? new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(255, 193, 7))
                    : new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(100, 211, 163));
        }

        private void SourceModeChanged(object sender, RoutedEventArgs e)
        {
            if (_initialized) UpdateSourceMode();
        }

        private void UpdateSourceMode()
        {
            var manual = AutoSelectCheckBox.IsChecked != true;
            ManualPidBox.IsEnabled = manual;
            ManualSessionBox.IsEnabled = manual;
        }

        private void ApplyClick(object sender, RoutedEventArgs e)
        {
            DetectorSettings parsed;
            string error;
            if (!TryReadSettings(out parsed, out error))
            {
                ValidationText.Text = error;
                return;
            }
            _plugin.ApplySettings(parsed);
            LoadSettings(_plugin.Settings);
            UpdateSourceMode();
            ValidationText.Foreground = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(100, 211, 163));
            ValidationText.Text = "設定已套用。";
        }

        private void DefaultsClick(object sender, RoutedEventArgs e)
        {
            LoadSettings(DetectorSettings.Defaults());
            UpdateSourceMode();
            ValidationText.Text = "已載入預設值；按「套用設定」後生效。";
        }

        private void ResetPeakClick(object sender, RoutedEventArgs e)
        {
            _plugin.ResetPeak();
            ValidationText.Text = "峰值已清除。";
        }

        private bool TryReadSettings(out DetectorSettings settings, out string error)
        {
            settings = null;
            error = string.Empty;
            double entry = 0, exit = 0, ratio = 0;
            int continuous = 0, window = 0, exitHold = 0;
            uint processId = 0;
            if (!TryDouble(EntryThresholdBox.Text, out entry) || entry < 1 || entry > 100)
                error = "進入門檻必須是 1–100。";
            else if (!TryDouble(ExitThresholdBox.Text, out exit) || exit < 0 || exit > entry)
                error = "離開門檻必須是 0 到進入門檻之間。";
            else if (!int.TryParse(ContinuousBox.Text, NumberStyles.Integer, CultureInfo.InvariantCulture, out continuous) || continuous < 10 || continuous > 5000)
                error = "連續碰頂時間必須是 10–5000 ms。";
            else if (!TryDouble(RatioBox.Text, out ratio) || ratio < 0.1 || ratio > 100)
                error = "碰頂比例必須是 0.1–100%。";
            else if (!int.TryParse(WindowBox.Text, NumberStyles.Integer, CultureInfo.InvariantCulture, out window) || window < 100 || window > 10000)
                error = "比例視窗必須是 100–10000 ms。";
            else if (!int.TryParse(ExitHoldBox.Text, NumberStyles.Integer, CultureInfo.InvariantCulture, out exitHold) || exitHold < 0 || exitHold > 5000)
                error = "解除保持時間必須是 0–5000 ms。";
            else if (!uint.TryParse(ManualPidBox.Text, NumberStyles.Integer, CultureInfo.InvariantCulture, out processId))
                error = "手動 PID 必須是 0 或有效的正整數。";
            else if ((ManualSessionBox.Text ?? string.Empty).Trim().Length > 31)
                error = "Session ID 不可超過 31 個字元。";

            if (!string.IsNullOrEmpty(error)) return false;
            settings = new DetectorSettings
            {
                EntryThresholdPercent = entry,
                ExitThresholdPercent = exit,
                ContinuousLimitMilliseconds = continuous,
                RatioTriggerPercent = ratio,
                RatioWindowMilliseconds = window,
                ExitHoldMilliseconds = exitHold,
                AutoSelectSource = AutoSelectCheckBox.IsChecked == true,
                ManualProcessId = processId,
                ManualSessionId = (ManualSessionBox.Text ?? string.Empty).Trim(),
            };
            return true;
        }

        private static bool TryDouble(string text, out double value)
        {
            return double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out value) &&
                   !double.IsNaN(value) && !double.IsInfinity(value);
        }
    }
}
