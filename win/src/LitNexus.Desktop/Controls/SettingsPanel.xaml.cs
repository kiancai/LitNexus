using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using LitNexus.Core.Domain;
using LitNexus.Core.Workspace;

namespace LitNexus.Desktop.Controls
{
    /// <summary>
    /// Event payload for the SettingsPanel's explicit save hand-off. The host
    /// owns persistence and normally calls WorkspaceSession.ReplaceConfig with
    /// <see cref="Configuration"/>. The panel deliberately does not keep a
    /// SQLite or WorkspaceSession handle after loading.
    /// </summary>
    public sealed class SettingsSaveRequestedEventArgs : EventArgs
    {
        public SettingsSaveRequestedEventArgs(AppConfig configuration)
        {
            Configuration = configuration ?? throw new ArgumentNullException(nameof(configuration));
        }

        /// <summary>A normalized, independent configuration snapshot.</summary>
        public AppConfig Configuration { get; private set; }
    }

    /// <summary>
    /// Reusable editor for the first Windows configuration slice: download
    /// days, journal lines, keyword lines, and the portable project accent hue.
    /// It has no implicit active-project behavior. Call <see cref="Load(WorkspaceSession)"/>
    /// when a project is explicitly opened, then handle <see cref="SaveRequested"/>
    /// to perform the session's atomic configuration replacement.
    /// </summary>
    public partial class SettingsPanel : UserControl
    {
        private static readonly Color DefaultAccentColor = Color.FromRgb(0x10, 0x9A, 0x8D);

        private AppConfig? _sourceConfiguration;
        private bool _isLoading;

        public SettingsPanel()
        {
            InitializeComponent();
            SetAccentPreview(null, isInvalid: false);
            SetStatus("打开项目后即可编辑基础检索配置。", isError: false);
        }

        /// <summary>
        /// Raised after the current fields validate and before any persistence
        /// occurs. A host can save with:
        /// <code>session.ReplaceConfig(args.Configuration);</code>
        /// Throw from the handler to keep the panel on the editable values and
        /// present the failure to the user.
        /// </summary>
        public event EventHandler<SettingsSaveRequestedEventArgs>? SaveRequested;

        /// <summary>Whether this control currently has a configuration snapshot.</summary>
        public bool IsLoadedConfiguration
        {
            get { return _sourceConfiguration != null; }
        }

        /// <summary>
        /// Loads the configuration of one already opened, explicit workspace.
        /// The control copies its data and never infers or opens a workspace.
        /// </summary>
        public void Load(WorkspaceSession session)
        {
            if (session == null)
            {
                throw new ArgumentNullException(nameof(session));
            }

            if (session.IsDisposed)
            {
                throw new ObjectDisposedException(nameof(session));
            }

            Load(session.Config);
        }

        /// <summary>
        /// Loads a configuration snapshot without requiring a WPF host to expose
        /// its WorkspaceSession. This is useful for previews and UI tests.
        /// </summary>
        public void Load(AppConfig configuration)
        {
            if (configuration == null)
            {
                throw new ArgumentNullException(nameof(configuration));
            }

            _sourceConfiguration = CloneConfiguration(configuration);
            _isLoading = true;
            try
            {
                DownloadDaysText.Text = _sourceConfiguration.Download.Days.ToString(CultureInfo.InvariantCulture);
                JournalsText.Text = JoinLines(_sourceConfiguration.Download.Journals);
                KeywordsText.Text = JoinLines(_sourceConfiguration.Download.Keywords);
                AccentHueText.Text = FormatHue(_sourceConfiguration.Theme.AccentHue);
            }
            finally
            {
                _isLoading = false;
            }

            SetAccentPreview(_sourceConfiguration.Theme.AccentHue, isInvalid: false);
            SaveButton.IsEnabled = true;
            SetStatus("已加载项目配置。保存时只更新本页四项，其余项目设置会保留。", isError: false);
        }

        /// <summary>
        /// Builds a normalized replacement configuration from the visible fields
        /// without persisting it. Hosts may use this for their own save commands.
        /// </summary>
        public bool TryCreateConfiguration(out AppConfig? configuration, out string? validationMessage)
        {
            configuration = null;
            validationMessage = null;

            AppConfig? source = _sourceConfiguration;
            if (source == null)
            {
                validationMessage = "请先打开项目，再编辑配置。";
                return false;
            }

            int days;
            string rawDays = (DownloadDaysText.Text ?? string.Empty).Trim();
            if (!Int32.TryParse(rawDays, NumberStyles.Integer, CultureInfo.InvariantCulture, out days) || days < 0)
            {
                validationMessage = "下载时间窗口必须是 0 或正整数。";
                return false;
            }

            double? accentHue;
            string rawHue = (AccentHueText.Text ?? string.Empty).Trim();
            if (rawHue.Length == 0)
            {
                accentHue = null;
            }
            else
            {
                double parsedHue;
                if (!TryParseHue(rawHue, out parsedHue)
                    || Double.IsNaN(parsedHue)
                    || Double.IsInfinity(parsedHue)
                    || parsedHue < 0d
                    || parsedHue > 1d)
                {
                    validationMessage = "项目强调色色相必须是 0 到 1 之间的数字；留空表示默认青绿。";
                    return false;
                }

                accentHue = ThemeConfig.NormalizeAccentHue(parsedHue);
            }

            AppConfig replacement = CloneConfiguration(source);
            replacement.Download.Days = days;
            replacement.Download.Journals = SplitLines(JournalsText.Text);
            replacement.Download.Keywords = SplitLines(KeywordsText.Text);
            replacement.Theme.AccentHue = accentHue;
            replacement.Normalize();

            configuration = replacement;
            return true;
        }

        private void OnSaveClick(object sender, RoutedEventArgs e)
        {
            AppConfig? replacement;
            string? validationMessage;
            if (!TryCreateConfiguration(out replacement, out validationMessage) || replacement == null)
            {
                SetStatus(validationMessage ?? "配置无法保存。", isError: true);
                return;
            }

            EventHandler<SettingsSaveRequestedEventArgs>? handler = SaveRequested;
            if (handler == null)
            {
                SetStatus("配置已验证，但当前窗口尚未接入保存处理。", isError: true);
                return;
            }

            try
            {
                handler(this, new SettingsSaveRequestedEventArgs(replacement));
                _sourceConfiguration = CloneConfiguration(replacement);
                AccentHueText.Text = FormatHue(_sourceConfiguration.Theme.AccentHue);
                SetAccentPreview(_sourceConfiguration.Theme.AccentHue, isInvalid: false);
                SetStatus("配置已保存。", isError: false);
            }
            catch (Exception exception)
            {
                SetStatus("保存配置失败：" + exception.Message, isError: true);
            }
        }

        private void OnResetAccentClick(object sender, RoutedEventArgs e)
        {
            AccentHueText.Text = string.Empty;
            AccentHueText.Focus();
        }

        private void OnAccentHueTextChanged(object sender, TextChangedEventArgs e)
        {
            if (_isLoading)
            {
                return;
            }

            string rawHue = (AccentHueText.Text ?? string.Empty).Trim();
            if (rawHue.Length == 0)
            {
                SetAccentPreview(null, isInvalid: false);
                return;
            }

            double hue;
            bool isValid = TryParseHue(rawHue, out hue)
                && !Double.IsNaN(hue)
                && !Double.IsInfinity(hue)
                && hue >= 0d
                && hue <= 1d;
            SetAccentPreview(isValid ? ThemeConfig.NormalizeAccentHue(hue) : null, isInvalid: !isValid);
        }

        private void SetAccentPreview(double? hue, bool isInvalid)
        {
            AccentPreviewBorder.Background = new SolidColorBrush(
                hue.HasValue ? HsvToColor(hue.Value, 0.72d, 0.72d) : DefaultAccentColor);
            AccentHueText.BorderBrush = FindResource(isInvalid ? "ErrorBrush" : "LineBrush") as Brush
                ?? new SolidColorBrush(isInvalid ? Color.FromRgb(0xB4, 0x23, 0x18) : Color.FromRgb(0xDC, 0xE7, 0xE3));
        }

        private void SetStatus(string message, bool isError)
        {
            StatusText.Text = message ?? string.Empty;
            StatusText.Foreground = FindResource(isError ? "ErrorBrush" : "MutedBrush") as Brush
                ?? new SolidColorBrush(isError ? Color.FromRgb(0xB4, 0x23, 0x18) : Color.FromRgb(0x71, 0x81, 0x7C));
        }

        private static bool TryParseHue(string raw, out double hue)
        {
            return Double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out hue)
                || Double.TryParse(raw, NumberStyles.Float, CultureInfo.CurrentCulture, out hue);
        }

        private static string FormatHue(double? hue)
        {
            return hue.HasValue
                ? hue.Value.ToString("R", CultureInfo.InvariantCulture)
                : string.Empty;
        }

        private static string JoinLines(IEnumerable<string>? lines)
        {
            if (lines == null)
            {
                return string.Empty;
            }

            return string.Join(Environment.NewLine, lines.Select(line => line ?? string.Empty));
        }

        private static List<string> SplitLines(string? text)
        {
            var result = new List<string>();
            using (var reader = new StringReader(text ?? string.Empty))
            {
                string? line;
                while ((line = reader.ReadLine()) != null)
                {
                    result.Add(line);
                }
            }

            return result;
        }

        private static AppConfig CloneConfiguration(AppConfig source)
        {
            var copy = new AppConfig
            {
                Download = new DownloadConfig
                {
                    Days = source.Download?.Days ?? 30,
                    PageSize = source.Download?.PageSize ?? 1000,
                    RequestDelay = source.Download?.RequestDelay ?? 0.5d,
                    Journals = new List<string>(source.Download?.Journals ?? Enumerable.Empty<string>()),
                    Keywords = new List<string>(source.Download?.Keywords ?? Enumerable.Empty<string>()),
                },
                AI = new AIConfig
                {
                    Active = source.AI?.Active ?? string.Empty,
                    Profiles = (source.AI?.Profiles ?? Enumerable.Empty<AIProfile>())
                        .Where(profile => profile != null)
                        .Select(profile => new AIProfile
                        {
                            Id = profile.Id,
                            Name = profile.Name,
                            BaseUrl = profile.BaseUrl,
                            Model = profile.Model,
                            ApiKey = profile.ApiKey,
                            ExtraParams = profile.ExtraParams,
                        })
                        .ToList(),
                },
                Translate = new TranslateConfig
                {
                    BatchSize = source.Translate?.BatchSize ?? 30,
                    Concurrency = source.Translate?.Concurrency ?? 20,
                    TranslateAbstract = source.Translate?.TranslateAbstract ?? true,
                    AbstractBatchSize = source.Translate?.AbstractBatchSize ?? 10,
                },
                Classify = new ClassifyConfig
                {
                    MaxWorkers = source.Classify?.MaxWorkers ?? 20,
                    BatchSize = source.Classify?.BatchSize ?? 15,
                    MaxAttempts = source.Classify?.MaxAttempts ?? 3,
                    NextQuestionNumber = source.Classify?.NextQuestionNumber ?? 1,
                    Questions = (source.Classify?.Questions ?? Enumerable.Empty<Question>())
                        .Where(question => question != null)
                        .Select(question => new Question
                        {
                            Id = question.Id,
                            Nickname = question.Nickname,
                            Text = question.Text,
                            Classify = question.Classify,
                            Export = question.Export,
                            Archived = question.Archived,
                            ClassifyAfterRowId = question.ClassifyAfterRowId,
                        })
                        .ToList(),
                },
                Schema = new SchemaConfig
                {
                    CustomColumns = new List<string>(source.Schema?.CustomColumns ?? Enumerable.Empty<string>()),
                },
                Export = new ExportConfig
                {
                    Filter = source.Export?.Filter ?? "pending",
                    ExcludeColumns = new List<string>(source.Export?.ExcludeColumns ?? Enumerable.Empty<string>()),
                },
                Theme = new ThemeConfig
                {
                    AccentHue = source.Theme?.AccentHue,
                },
            };

            copy.Normalize();
            return copy;
        }

        private static Color HsvToColor(double hue, double saturation, double value)
        {
            hue = hue - Math.Floor(hue);
            double chroma = value * saturation;
            double position = hue * 6d;
            double secondary = chroma * (1d - Math.Abs((position % 2d) - 1d));
            double red;
            double green;
            double blue;

            if (position < 1d)
            {
                red = chroma; green = secondary; blue = 0d;
            }
            else if (position < 2d)
            {
                red = secondary; green = chroma; blue = 0d;
            }
            else if (position < 3d)
            {
                red = 0d; green = chroma; blue = secondary;
            }
            else if (position < 4d)
            {
                red = 0d; green = secondary; blue = chroma;
            }
            else if (position < 5d)
            {
                red = secondary; green = 0d; blue = chroma;
            }
            else
            {
                red = chroma; green = 0d; blue = secondary;
            }

            double offset = value - chroma;
            return Color.FromRgb(
                ToColorByte(red + offset),
                ToColorByte(green + offset),
                ToColorByte(blue + offset));
        }

        private static byte ToColorByte(double component)
        {
            double bounded = Math.Max(0d, Math.Min(1d, component));
            return (byte)Math.Round(bounded * 255d, MidpointRounding.AwayFromZero);
        }
    }
}
