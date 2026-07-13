using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using LitNexus.Core.Domain;
using LitNexus.Core.ImportExport;
using LitNexus.Core.Persistence;
using LitNexus.Core.Workspace;
using Microsoft.Win32;

namespace LitNexus.Desktop.Controls
{
    /// <summary>
    /// A notification that the visible export range changed. The control does
    /// not mutate <see cref="WorkspaceSession.Config"/>: hosts may explicitly
    /// persist <see cref="Filter"/> if they want this choice remembered in
    /// <c>export.filter</c>.
    /// </summary>
    public sealed class DataPanelExportFilterChangedEventArgs : EventArgs
    {
        public DataPanelExportFilterChangedEventArgs(ArticleExportScope scope)
        {
            Scope = scope;
            Filter = DataPanel.ToConfigFilter(scope);
        }

        /// <summary>The typed scope chosen in the Data page.</summary>
        public ArticleExportScope Scope { get; private set; }

        /// <summary>The portable TOML value: all, pending, included, or excluded.</summary>
        public string Filter { get; private set; }
    }

    /// <summary>
    /// A complete, caller-owned export-column snapshot. It deliberately
    /// includes exclusions the current Data page does not render (for example
    /// a future field or a historical question column), so toggling one visible
    /// checkbox can never silently discard another client's preference.
    /// </summary>
    public sealed class DataPanelExportColumnsChangedEventArgs : EventArgs
    {
        public DataPanelExportColumnsChangedEventArgs(IEnumerable<string> excludeColumns)
        {
            if (excludeColumns == null)
            {
                throw new ArgumentNullException(nameof(excludeColumns));
            }

            ExcludeColumns = excludeColumns
                .Where(column => !string.IsNullOrWhiteSpace(column))
                .Select(column => column.Trim())
                .Distinct(StringComparer.Ordinal)
                .ToArray();
        }

        /// <summary>
        /// Full portable <c>export.exclude_columns</c> replacement. The Data
        /// panel never applies it to a <see cref="WorkspaceSession"/> itself;
        /// the host decides whether and when to save it.
        /// </summary>
        public IReadOnlyList<string> ExcludeColumns { get; private set; }
    }

    /// <summary>Raised after a CSV export has safely completed.</summary>
    public sealed class DataPanelExportCompletedEventArgs : EventArgs
    {
        public DataPanelExportCompletedEventArgs(ArticleCsvExportResult result)
        {
            Result = result ?? throw new ArgumentNullException(nameof(result));
        }

        public ArticleCsvExportResult Result { get; private set; }
    }

    /// <summary>Raised after the non-mutating first phase of review CSV import.</summary>
    public sealed class DataPanelReviewImportPreflightEventArgs : EventArgs
    {
        public DataPanelReviewImportPreflightEventArgs(ReviewedCsvImportPlan plan)
        {
            Plan = plan ?? throw new ArgumentNullException(nameof(plan));
        }

        public ReviewedCsvImportPlan Plan { get; private set; }
    }

    /// <summary>Raised only after the user confirmed and the coordinator wrote successfully.</summary>
    public sealed class DataPanelReviewImportCompletedEventArgs : EventArgs
    {
        public DataPanelReviewImportCompletedEventArgs(ConfirmedReviewedCsvImportResult result)
        {
            Result = result ?? throw new ArgumentNullException(nameof(result));
        }

        public ConfirmedReviewedCsvImportResult Result { get; private set; }
    }

    /// <summary>
    /// Data-page UI for one explicitly opened workspace. It owns no workspace
    /// discovery and never writes portable configuration implicitly. Its only
    /// write path is the Core review-import coordinator, which preflights again
    /// and creates a SQLite-consistent backup before a non-empty update.
    /// </summary>
    public partial class DataPanel : UserControl
    {
        private static readonly string[] BaseExportColumns =
        {
            "epmc_id",
            "pmid",
            "doi",
            "source",
            "pmcid",
            "title",
            "abstract",
            "pub_year",
            "author_string",
            "journal_title",
            "first_publication_date",
            "query_search_term",
            "journal_info_json",
            "keyword_list_json",
            "title_zh",
            "abstract_zh",
        };

        private static readonly IReadOnlyDictionary<string, string> ExportColumnLabels =
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                { "epmc_id", "EPMC ID" },
                { "pmid", "PMID" },
                { "doi", "DOI" },
                { "source", "来源(MED/PPR)" },
                { "pmcid", "PMCID" },
                { "title", "标题(原文)" },
                { "abstract", "摘要(原文)" },
                { "pub_year", "年份" },
                { "author_string", "作者" },
                { "journal_title", "期刊" },
                { "first_publication_date", "首发日期" },
                { "query_search_term", "命中检索式" },
                { "journal_info_json", "期刊信息(JSON)" },
                { "keyword_list_json", "关键词(JSON)" },
                { "title_zh", "标题(译文)" },
                { "abstract_zh", "摘要(译文)" },
                { "include", "复筛纳入(include)" },
                { "tags", "标签(tags)" },
            };

        private static readonly HashSet<string> RequiredReviewExportColumns =
            new HashSet<string>(new[] { "epmc_id", "include", "tags" }, StringComparer.Ordinal);

        private WorkspaceSession? _session;
        private ArticleExportScope _selectedScope = ArticleExportScope.Pending;
        private readonly List<string> _exportExcludedColumns = new List<string>();
        private readonly HashSet<string> _visibleExportColumns = new HashSet<string>(StringComparer.Ordinal);
        private bool _isLoading;

        public DataPanel()
        {
            InitializeComponent();
            SetActionsEnabled(false);
            SetStatus(ExportStatusText, "打开项目后即可导出人工复筛 CSV。", isError: false);
            SetStatus(ImportStatusText, "选择 CSV 后会先检查，不会立即写入数据库。", isError: false);
            SetScopeButtons(ArticleExportScope.Pending);
        }

        /// <summary>
        /// Raised when the user changes the visible export scope. The panel
        /// intentionally does not call SaveConfig or ReplaceConfig; a host that
        /// wants persistence must do it explicitly from this event.
        /// </summary>
        public event EventHandler<DataPanelExportFilterChangedEventArgs>? ExportFilterChanged;

        /// <summary>
        /// Raised with the complete requested <c>export.exclude_columns</c>
        /// state whenever a visible, optional export field is toggled. This
        /// control never mutates or saves <see cref="WorkspaceSession.Config"/>.
        /// </summary>
        public event EventHandler<DataPanelExportColumnsChangedEventArgs>? ExportColumnsChanged;

        /// <summary>Raised after a CSV was written (or an empty range was safely reported).</summary>
        public event EventHandler<DataPanelExportCompletedEventArgs>? ExportCompleted;

        /// <summary>Raised after every successful, non-mutating review CSV preflight.</summary>
        public event EventHandler<DataPanelReviewImportPreflightEventArgs>? ReviewImportPreflightCompleted;

        /// <summary>Raised after a user-confirmed review import completed.</summary>
        public event EventHandler<DataPanelReviewImportCompletedEventArgs>? ReviewImportCompleted;

        /// <summary>True when a non-disposed workspace session is currently loaded.</summary>
        public bool HasLoadedSession
        {
            get { return _session != null && !_session.IsDisposed; }
        }

        /// <summary>The current, non-persisted export choice.</summary>
        public ArticleExportScope SelectedScope
        {
            get { return _selectedScope; }
        }

        /// <summary>
        /// Connects the panel to a session the host already opened. The config's
        /// <c>export.filter</c> determines the initial selection, but loading
        /// it never changes the session or persists a fallback value.
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

            _session = session;
            _isLoading = true;
            try
            {
                SetScopeButtons(ParseConfigFilter(session.Config.Export.Filter));
                LoadExportColumnChoices(session.Config);
                RefreshStatusSummary();
            }
            finally
            {
                _isLoading = false;
            }

            SetActionsEnabled(true);
            SetStatus(
                ExportStatusText,
                "当前范围来自项目导出默认值；切换范围只影响这次页面操作，除非窗口显式保存。",
                isError: false);
            SetStatus(
                ImportStatusText,
                "选择 CSV 后会先检查，不会立即写入数据库。",
                isError: false);
        }

        /// <summary>
        /// Removes the current session reference and disables actions. The host
        /// remains responsible for disposing its own WorkspaceSession.
        /// </summary>
        public void Clear()
        {
            _session = null;
            _isLoading = true;
            try
            {
                SetScopeButtons(ArticleExportScope.Pending);
                ClearExportColumnChoices();
                SetCountTexts(null);
            }
            finally
            {
                _isLoading = false;
            }

            SetActionsEnabled(false);
            SetStatus(ExportStatusText, "打开项目后即可导出人工复筛 CSV。", isError: false);
            SetStatus(ImportStatusText, "选择 CSV 后会先检查，不会立即写入数据库。", isError: false);
        }

        /// <summary>Reloads the four review counts from the current database.</summary>
        public void RefreshStatusSummary()
        {
            WorkspaceSession session = RequireSession();
            ArticleStatusSummary summary = session.Database.GetArticleStatusSummary();
            SetCountTexts(summary);
        }

        /// <summary>
        /// Builds the exact request the Export button would use. This does not
        /// create directories or write a CSV, which keeps it useful for hosts
        /// that wish to show their own save destination UI later.
        /// </summary>
        public ArticleCsvExportRequest CreateDefaultExportRequest()
        {
            WorkspaceSession session = RequireSession();
            return new ArticleCsvExportRequest(
                _selectedScope,
                CreateDefaultExportPath(session),
                BuildExcludedColumns(session.Config, GetExportExcludedColumnsSnapshot()),
                BuildHumanReadableHeaders(session.Config));
        }

        /// <summary>
        /// Maps an internal typed scope to the stable portable TOML filter
        /// value. It is public so hosts can persist an explicit user decision
        /// without duplicating a string switch.
        /// </summary>
        public static string ToConfigFilter(ArticleExportScope scope)
        {
            switch (scope)
            {
                case ArticleExportScope.All:
                    return "all";
                case ArticleExportScope.Pending:
                    return "pending";
                case ArticleExportScope.Included:
                    return "included";
                case ArticleExportScope.Excluded:
                    return "excluded";
                default:
                    throw new ArgumentOutOfRangeException(nameof(scope));
            }
        }

        private void OnRefreshClick(object sender, RoutedEventArgs e)
        {
            try
            {
                RefreshStatusSummary();
                SetStatus(ExportStatusText, "已刷新当前项目的人工复筛状态。", isError: false);
            }
            catch (Exception exception)
            {
                SetStatus(ExportStatusText, "无法读取状态：" + exception.Message, isError: true);
            }
        }

        private void OnScopeClick(object sender, RoutedEventArgs e)
        {
            ToggleButton? clicked = sender as ToggleButton;
            ArticleExportScope scope;
            if (clicked == null || !TryParseScope(clicked.Tag as string, out scope))
            {
                return;
            }

            SetScopeButtons(scope);
            if (!_isLoading)
            {
                EventHandler<DataPanelExportFilterChangedEventArgs>? handler = ExportFilterChanged;
                if (handler != null)
                {
                    handler(this, new DataPanelExportFilterChangedEventArgs(scope));
                }
            }
        }

        private void OnExportColumnCheckChanged(object sender, RoutedEventArgs e)
        {
            CheckBox? checkBox = sender as CheckBox;
            if (checkBox == null)
            {
                return;
            }

            string column = checkBox.Tag as string ?? string.Empty;
            if (_isLoading || string.IsNullOrWhiteSpace(column) || RequiredReviewExportColumns.Contains(column))
            {
                return;
            }

            if (checkBox.IsChecked == true)
            {
                RemoveExportExcludedColumn(column);
            }
            else
            {
                AddExportExcludedColumn(column);
            }

            UpdateExportColumnsSummary();
            EventHandler<DataPanelExportColumnsChangedEventArgs>? handler = ExportColumnsChanged;
            if (handler != null)
            {
                handler(this, new DataPanelExportColumnsChangedEventArgs(GetExportExcludedColumnsSnapshot()));
            }
        }

        private void OnExportClick(object sender, RoutedEventArgs e)
        {
            try
            {
                WorkspaceSession session = RequireSession();
                System.Windows.Input.Mouse.OverrideCursor = System.Windows.Input.Cursors.Wait;
                ArticleCsvExportRequest request = CreateDefaultExportRequest();
                ArticleCsvExportResult result = session.Database.ExportArticlesCsv(request);
                if (result.FileCreated)
                {
                    SetStatus(
                        ExportStatusText,
                        "已导出 " + result.WrittenRows.ToString("N0", CultureInfo.CurrentCulture)
                        + " 篇文章到 “" + result.OutputPath + "”。",
                        isError: false);
                }
                else
                {
                    SetStatus(ExportStatusText, "当前范围没有文章；没有创建或覆盖任何 CSV 文件。", isError: false);
                }

                EventHandler<DataPanelExportCompletedEventArgs>? handler = ExportCompleted;
                if (handler != null)
                {
                    handler(this, new DataPanelExportCompletedEventArgs(result));
                }
            }
            catch (Exception exception)
            {
                SetStatus(ExportStatusText, "导出失败：" + exception.Message, isError: true);
            }
            finally
            {
                System.Windows.Input.Mouse.OverrideCursor = null;
            }
        }

        private void OnOpenExportsClick(object sender, RoutedEventArgs e)
        {
            try
            {
                WorkspaceSession session = RequireSession();
                Directory.CreateDirectory(session.Paths.ExportsDirectory);
                Process.Start(new ProcessStartInfo
                {
                    FileName = session.Paths.ExportsDirectory,
                    UseShellExecute = true,
                });
            }
            catch (Exception exception)
            {
                SetStatus(ExportStatusText, "无法打开导出目录：" + exception.Message, isError: true);
            }
        }

        private void OnChooseReviewCsvClick(object sender, RoutedEventArgs e)
        {
            WorkspaceSession? session = _session;
            if (session == null || session.IsDisposed)
            {
                SetStatus(ImportStatusText, "请先打开项目，再选择复筛 CSV。", isError: true);
                return;
            }

            var dialog = new OpenFileDialog
            {
                Title = "选择人工复筛 CSV",
                Filter = "CSV 文件 (*.csv)|*.csv|所有文件 (*.*)|*.*",
                CheckFileExists = true,
                CheckPathExists = true,
                Multiselect = false,
                RestoreDirectory = true,
            };
            if (dialog.ShowDialog(GetOwningWindow()) != true)
            {
                return;
            }

            try
            {
                ChooseReviewCsvButton.IsEnabled = false;
                System.Windows.Input.Mouse.OverrideCursor = System.Windows.Input.Cursors.Wait;
                ReviewedCsvImportPlan plan = ReviewedCsvImportCoordinator.Prepare(session, dialog.FileName, allowOverwrite: false);
                RaiseReviewPreflight(plan);

                var confirmation = new ReviewedCsvImportConfirmationDialog(
                    plan,
                    allowOverwrite =>
                    {
                        WorkspaceSession current = RequireSession();
                        ReviewedCsvImportPlan refreshed = ReviewedCsvImportCoordinator.Prepare(
                            current,
                            dialog.FileName,
                            allowOverwrite);
                        RaiseReviewPreflight(refreshed);
                        return refreshed;
                    })
                {
                    Owner = GetOwningWindow(),
                };

                // Preflight is complete. Keep the confirmation dialog fully
                // interactive instead of leaving a busy cursor over its
                // overwrite choice and issue list.
                System.Windows.Input.Mouse.OverrideCursor = null;
                bool? accepted = confirmation.ShowDialog();
                if (accepted != true || !confirmation.IsConfirmed)
                {
                    SetStatus(
                        ImportStatusText,
                        DescribePreflight(plan) + " 未写入数据库。",
                        isError: !plan.CanApply);
                    return;
                }

                System.Windows.Input.Mouse.OverrideCursor = System.Windows.Input.Cursors.Wait;
                ConfirmedReviewedCsvImportResult result = ReviewedCsvImportCoordinator.Confirm(
                    RequireSession(),
                    dialog.FileName,
                    confirmation.AllowOverwrite);
                RefreshStatusSummary();

                string backup = result.AutomaticBackup == null
                    ? string.Empty
                    : " 已自动备份为 “" + result.AutomaticBackup.BackupPath + "”。";
                SetStatus(
                    ImportStatusText,
                    "导入完成：更新 " + result.ImportResult.UpdatedRows.ToString("N0", CultureInfo.CurrentCulture)
                    + " 行 / " + result.ImportResult.UpdatedFields.ToString("N0", CultureInfo.CurrentCulture)
                    + " 项。" + backup,
                    isError: false);

                EventHandler<DataPanelReviewImportCompletedEventArgs>? handler = ReviewImportCompleted;
                if (handler != null)
                {
                    handler(this, new DataPanelReviewImportCompletedEventArgs(result));
                }
            }
            catch (ReviewedCsvImportException exception)
            {
                // The Core coordinator intentionally rechecks immediately
                // before writing. A changed file can therefore make a formerly
                // valid dialog stale; show the fresh report and leave DB intact.
                SetStatus(
                    ImportStatusText,
                    "确认前的复检发现 " + exception.Plan.ErrorCount.ToString(CultureInfo.CurrentCulture)
                    + " 个错误，未写入数据库。",
                    isError: true);
            }
            catch (Exception exception)
            {
                SetStatus(ImportStatusText, "无法检查或导入 CSV：" + exception.Message, isError: true);
            }
            finally
            {
                System.Windows.Input.Mouse.OverrideCursor = null;
                if (HasLoadedSession)
                {
                    ChooseReviewCsvButton.IsEnabled = true;
                }
            }
        }

        private void RaiseReviewPreflight(ReviewedCsvImportPlan plan)
        {
            EventHandler<DataPanelReviewImportPreflightEventArgs>? handler = ReviewImportPreflightCompleted;
            if (handler != null)
            {
                handler(this, new DataPanelReviewImportPreflightEventArgs(plan));
            }
        }

        private WorkspaceSession RequireSession()
        {
            WorkspaceSession? session = _session;
            if (session == null)
            {
                throw new InvalidOperationException("当前没有打开项目。请先选择项目文件夹。");
            }

            if (session.IsDisposed)
            {
                throw new ObjectDisposedException(nameof(WorkspaceSession));
            }

            return session;
        }

        private void SetActionsEnabled(bool isEnabled)
        {
            ExportButton.IsEnabled = isEnabled;
            OpenExportsButton.IsEnabled = isEnabled;
            ChooseReviewCsvButton.IsEnabled = isEnabled;
            AllScopeButton.IsEnabled = isEnabled;
            PendingScopeButton.IsEnabled = isEnabled;
            IncludedScopeButton.IsEnabled = isEnabled;
            ExcludedScopeButton.IsEnabled = isEnabled;
            ExportColumnsExpander.IsEnabled = isEnabled;
        }

        private void SetScopeButtons(ArticleExportScope scope)
        {
            _selectedScope = scope;
            AllScopeButton.IsChecked = scope == ArticleExportScope.All;
            PendingScopeButton.IsChecked = scope == ArticleExportScope.Pending;
            IncludedScopeButton.IsChecked = scope == ArticleExportScope.Included;
            ExcludedScopeButton.IsChecked = scope == ArticleExportScope.Excluded;
        }

        /// <summary>
        /// Builds the same optional-column list as the Mac Data page: stable
        /// article fields followed by configured human annotation fields. AI
        /// question answer/reason columns are intentionally absent because each
        /// question owns its own export switch in the configuration page.
        /// </summary>
        private void LoadExportColumnChoices(AppConfig config)
        {
            _exportExcludedColumns.Clear();
            foreach (string column in config.Export.ExcludeColumns ?? Enumerable.Empty<string>())
            {
                AddExportExcludedColumn(column);
            }

            ExportColumnsPanel.Children.Clear();
            _visibleExportColumns.Clear();

            foreach (ExportColumnChoice choice in GetExportColumnChoices(config))
            {
                _visibleExportColumns.Add(choice.Column);
                var checkBox = new CheckBox
                {
                    Content = choice.Label,
                    Tag = choice.Column,
                    IsChecked = choice.IsRequired || !ContainsExportExcludedColumn(choice.Column),
                    IsEnabled = !choice.IsRequired,
                    Style = FindResource("ExportColumnCheckBoxStyle") as Style,
                    ToolTip = choice.IsRequired
                        ? "人工复筛 CSV 必须保留这一列。"
                        : "控制该列是否写入导出 CSV。",
                };

                if (!choice.IsRequired)
                {
                    checkBox.Checked += OnExportColumnCheckChanged;
                    checkBox.Unchecked += OnExportColumnCheckChanged;
                }

                ExportColumnsPanel.Children.Add(checkBox);
            }

            UpdateExportColumnsSummary();
        }

        private void ClearExportColumnChoices()
        {
            _exportExcludedColumns.Clear();
            _visibleExportColumns.Clear();
            ExportColumnsPanel.Children.Clear();
            ExportColumnsSummaryText.Text = "打开项目后可选择";
        }

        private static IEnumerable<ExportColumnChoice> GetExportColumnChoices(AppConfig config)
        {
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (string column in BaseExportColumns
                .Concat(SchemaConfig.RequiredReviewColumns)
                .Concat(config.Schema.CustomColumns ?? Enumerable.Empty<string>()))
            {
                if (string.IsNullOrWhiteSpace(column)
                    || IsQuestionAnswerOrReasonColumn(column)
                    || !seen.Add(column))
                {
                    continue;
                }

                string label;
                if (!ExportColumnLabels.TryGetValue(column, out label))
                {
                    label = column;
                }

                yield return new ExportColumnChoice(column, label, RequiredReviewExportColumns.Contains(column));
            }
        }

        private static bool IsQuestionAnswerOrReasonColumn(string column)
        {
            return column.EndsWith("_ans", StringComparison.Ordinal)
                || column.EndsWith("_rea", StringComparison.Ordinal);
        }

        private bool ContainsExportExcludedColumn(string column)
        {
            return _exportExcludedColumns.Any(item => string.Equals(item, column, StringComparison.Ordinal));
        }

        private void AddExportExcludedColumn(string? rawColumn)
        {
            string column = (rawColumn ?? string.Empty).Trim();
            if (!string.IsNullOrWhiteSpace(column) && !ContainsExportExcludedColumn(column))
            {
                _exportExcludedColumns.Add(column);
            }
        }

        private void RemoveExportExcludedColumn(string column)
        {
            _exportExcludedColumns.RemoveAll(item => string.Equals(item, column, StringComparison.Ordinal));
        }

        private IReadOnlyList<string> GetExportExcludedColumnsSnapshot()
        {
            // Required review fields must survive every CSV export even if a
            // hand-edited/legacy config listed them as excluded. All unknown
            // and currently invisible entries remain untouched and ordered.
            return _exportExcludedColumns
                .Where(column => !RequiredReviewExportColumns.Contains(column))
                .Distinct(StringComparer.Ordinal)
                .ToArray();
        }

        private void UpdateExportColumnsSummary()
        {
            int exported = _visibleExportColumns.Count(column => RequiredReviewExportColumns.Contains(column)
                || !ContainsExportExcludedColumn(column));
            ExportColumnsSummaryText.Text = exported.ToString(CultureInfo.CurrentCulture)
                + " / " + _visibleExportColumns.Count.ToString(CultureInfo.CurrentCulture) + " 列写入";
        }

        private void SetCountTexts(ArticleStatusSummary? summary)
        {
            string total = summary == null ? "—" : summary.Total.ToString("N0", CultureInfo.CurrentCulture);
            string pending = summary == null ? "—" : summary.Pending.ToString("N0", CultureInfo.CurrentCulture);
            string included = summary == null ? "—" : summary.Included.ToString("N0", CultureInfo.CurrentCulture);
            string excluded = summary == null ? "—" : summary.Excluded.ToString("N0", CultureInfo.CurrentCulture);
            TotalCountText.Text = total;
            PendingCountText.Text = pending;
            IncludedCountText.Text = included;
            ExcludedCountText.Text = excluded;
            AllScopeCountText.Text = total;
            PendingScopeCountText.Text = pending;
            IncludedScopeCountText.Text = included;
            ExcludedScopeCountText.Text = excluded;
        }

        private static ArticleExportScope ParseConfigFilter(string? filter)
        {
            ArticleExportScope scope;
            return TryParseScope(filter, out scope) ? scope : ArticleExportScope.Pending;
        }

        private static bool TryParseScope(string? value, out ArticleExportScope scope)
        {
            switch ((value ?? string.Empty).Trim().ToLowerInvariant())
            {
                case "all":
                    scope = ArticleExportScope.All;
                    return true;
                case "pending":
                    scope = ArticleExportScope.Pending;
                    return true;
                case "included":
                    scope = ArticleExportScope.Included;
                    return true;
                case "excluded":
                    scope = ArticleExportScope.Excluded;
                    return true;
                default:
                    scope = ArticleExportScope.Pending;
                    return false;
            }
        }

        private static string CreateDefaultExportPath(WorkspaceSession session)
        {
            string stamp = DateTime.UtcNow.ToString("yyyyMMdd_HHmmss_fff'Z'", CultureInfo.InvariantCulture);
            return Path.Combine(session.Paths.ExportsDirectory, "articles_" + stamp + ".csv");
        }

        private static IReadOnlyCollection<string> BuildExcludedColumns(
            AppConfig config,
            IEnumerable<string> currentExcludeColumns)
        {
            var excluded = new HashSet<string>(
                (currentExcludeColumns ?? Enumerable.Empty<string>())
                    .Where(column => !string.IsNullOrWhiteSpace(column)),
                StringComparer.Ordinal);

            foreach (Question question in config.Classify?.Questions ?? Enumerable.Empty<Question>())
            {
                if (question == null || string.IsNullOrWhiteSpace(question.Id))
                {
                    continue;
                }

                if (question.Archived || !question.Export)
                {
                    excluded.Add(question.Id + "_ans");
                    excluded.Add(question.Id + "_rea");
                }
            }

            // ArticleCsvExportRequest also protects these, but keeping them out
            // of the request makes the invariant obvious at this UI boundary.
            excluded.Remove("epmc_id");
            excluded.Remove("include");
            excluded.Remove("tags");
            return excluded;
        }

        private static IReadOnlyDictionary<string, string> BuildHumanReadableHeaders(AppConfig config)
        {
            var headings = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (Question question in config.Classify?.Questions ?? Enumerable.Empty<Question>())
            {
                if (question == null || question.Archived || !question.Export || string.IsNullOrWhiteSpace(question.Id))
                {
                    continue;
                }

                string displayName = string.IsNullOrWhiteSpace(question.DisplayName)
                    ? question.Id
                    : question.DisplayName;
                headings[question.Id + "_ans"] = displayName + " · 答案";
                headings[question.Id + "_rea"] = displayName + " · 理由";
            }

            return headings;
        }

        private static string DescribePreflight(ReviewedCsvImportPlan plan)
        {
            if (!plan.CanApply)
            {
                return "预检发现 " + plan.ErrorCount.ToString(CultureInfo.CurrentCulture) + " 个错误。";
            }

            return "已完成预检：可更新 " + plan.Updates.Count.ToString(CultureInfo.CurrentCulture)
                + " 行，" + plan.WarningCount.ToString(CultureInfo.CurrentCulture) + " 条提示。";
        }

        private Window? GetOwningWindow()
        {
            return Window.GetWindow(this);
        }

        private void SetStatus(TextBlock target, string message, bool isError)
        {
            target.Text = message ?? string.Empty;
            target.Foreground = FindResource(isError ? "ErrorBrush" : "MutedBrush") as Brush
                ?? new SolidColorBrush(isError ? Color.FromRgb(0xB4, 0x23, 0x18) : Color.FromRgb(0x71, 0x81, 0x7C));
        }

        private sealed class ExportColumnChoice
        {
            public ExportColumnChoice(string column, string label, bool isRequired)
            {
                Column = column;
                Label = label;
                IsRequired = isRequired;
            }

            public string Column { get; private set; }

            public string Label { get; private set; }

            public bool IsRequired { get; private set; }
        }
    }

    /// <summary>
    /// Modal second-step review CSV dialog. It can recalculate the non-mutating
    /// plan when "allow overwrite" changes, but it never writes itself; the
    /// caller must still invoke ReviewedCsvImportCoordinator.Confirm only after
    /// <see cref="IsConfirmed"/> becomes true.
    /// </summary>
    internal sealed class ReviewedCsvImportConfirmationDialog : Window
    {
        private readonly Func<bool, ReviewedCsvImportPlan> _refreshPlan;
        private readonly CheckBox _allowOverwriteCheckBox;
        private readonly TextBlock _summaryText;
        private readonly TextBlock _issueHeadingText;
        private readonly ListBox _issuesList;
        private readonly TextBlock _refreshErrorText;
        private readonly Button _confirmButton;
        private bool _isInitializing;
        private ReviewedCsvImportPlan _plan;

        public ReviewedCsvImportConfirmationDialog(
            ReviewedCsvImportPlan plan,
            Func<bool, ReviewedCsvImportPlan> refreshPlan)
        {
            _plan = plan ?? throw new ArgumentNullException(nameof(plan));
            _refreshPlan = refreshPlan ?? throw new ArgumentNullException(nameof(refreshPlan));
            Title = "确认导入复筛结果";
            Width = 650;
            Height = 570;
            MinWidth = 540;
            MinHeight = 430;
            WindowStartupLocation = WindowStartupLocation.CenterOwner;
            ResizeMode = ResizeMode.CanResize;
            Background = new SolidColorBrush(Color.FromRgb(0xFB, 0xFC, 0xFB));

            var root = new Grid
            {
                Margin = new Thickness(24),
            };
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1d, GridUnitType.Star) });
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

            var titlePanel = new StackPanel();
            titlePanel.Children.Add(new TextBlock
            {
                Text = "确认导入复筛结果",
                FontSize = 20,
                FontWeight = FontWeights.SemiBold,
                Foreground = new SolidColorBrush(Color.FromRgb(0x1D, 0x30, 0x2C)),
            });
            titlePanel.Children.Add(new TextBlock
            {
                Text = "只会按 epmc_id 写入 include 与 tags；其余 CSV 列不会覆盖数据库。",
                Margin = new Thickness(0, 6, 0, 0),
                FontSize = 13,
                Foreground = new SolidColorBrush(Color.FromRgb(0x71, 0x81, 0x7C)),
                TextWrapping = TextWrapping.Wrap,
            });
            Grid.SetRow(titlePanel, 0);
            root.Children.Add(titlePanel);

            var summaryBorder = new Border
            {
                Margin = new Thickness(0, 18, 0, 0),
                Padding = new Thickness(15, 13, 15, 13),
                Background = new SolidColorBrush(Color.FromRgb(0xF8, 0xFB, 0xFA)),
                BorderBrush = new SolidColorBrush(Color.FromRgb(0xDC, 0xE7, 0xE3)),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(10),
            };
            _summaryText = new TextBlock
            {
                FontSize = 13,
                LineHeight = 20,
                Foreground = new SolidColorBrush(Color.FromRgb(0x1D, 0x30, 0x2C)),
                TextWrapping = TextWrapping.Wrap,
            };
            summaryBorder.Child = _summaryText;
            Grid.SetRow(summaryBorder, 1);
            root.Children.Add(summaryBorder);

            var choicesPanel = new StackPanel
            {
                Margin = new Thickness(0, 14, 0, 0),
            };
            _allowOverwriteCheckBox = new CheckBox
            {
                Content = "允许覆盖数据库中已有的 include 或 tags 标注",
                FontSize = 13,
                Foreground = new SolidColorBrush(Color.FromRgb(0x1D, 0x30, 0x2C)),
                ToolTip = "默认只填补空值。勾选后会重新预检；确认时仍会再次检查。",
            };
            _allowOverwriteCheckBox.Checked += OnAllowOverwriteChanged;
            _allowOverwriteCheckBox.Unchecked += OnAllowOverwriteChanged;
            choicesPanel.Children.Add(_allowOverwriteCheckBox);
            _refreshErrorText = new TextBlock
            {
                Margin = new Thickness(23, 5, 0, 0),
                FontSize = 12,
                Foreground = new SolidColorBrush(Color.FromRgb(0xB4, 0x23, 0x18)),
                TextWrapping = TextWrapping.Wrap,
                Visibility = Visibility.Collapsed,
            };
            choicesPanel.Children.Add(_refreshErrorText);
            Grid.SetRow(choicesPanel, 2);
            root.Children.Add(choicesPanel);

            var issuePanel = new Grid
            {
                Margin = new Thickness(0, 16, 0, 0),
            };
            issuePanel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            issuePanel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1d, GridUnitType.Star) });
            _issueHeadingText = new TextBlock
            {
                FontSize = 13,
                FontWeight = FontWeights.SemiBold,
                Foreground = new SolidColorBrush(Color.FromRgb(0x1D, 0x30, 0x2C)),
            };
            Grid.SetRow(_issueHeadingText, 0);
            issuePanel.Children.Add(_issueHeadingText);
            _issuesList = new ListBox
            {
                Margin = new Thickness(0, 8, 0, 0),
                BorderBrush = new SolidColorBrush(Color.FromRgb(0xDC, 0xE7, 0xE3)),
                BorderThickness = new Thickness(1),
                Background = Brushes.White,
                FontSize = 12,
                Foreground = new SolidColorBrush(Color.FromRgb(0x3D, 0x4D, 0x48)),
                Padding = new Thickness(5),
            };
            Grid.SetRow(_issuesList, 1);
            issuePanel.Children.Add(_issuesList);
            Grid.SetRow(issuePanel, 3);
            root.Children.Add(issuePanel);

            var buttons = new StackPanel
            {
                Margin = new Thickness(0, 18, 0, 0),
                Orientation = Orientation.Horizontal,
                HorizontalAlignment = HorizontalAlignment.Right,
            };
            var cancelButton = CreateDialogButton("取消", isPrimary: false);
            cancelButton.IsCancel = true;
            cancelButton.Click += (sender, args) =>
            {
                DialogResult = false;
                Close();
            };
            _confirmButton = CreateDialogButton("确认导入", isPrimary: true);
            _confirmButton.Margin = new Thickness(9, 0, 0, 0);
            _confirmButton.IsDefault = true;
            _confirmButton.Click += OnConfirmClick;
            buttons.Children.Add(cancelButton);
            buttons.Children.Add(_confirmButton);
            Grid.SetRow(buttons, 4);
            root.Children.Add(buttons);

            Content = root;
            _isInitializing = true;
            try
            {
                RenderPlan(_plan);
            }
            finally
            {
                _isInitializing = false;
            }
        }

        public bool IsConfirmed { get; private set; }

        public bool AllowOverwrite
        {
            get { return _allowOverwriteCheckBox.IsChecked == true; }
        }

        private void OnAllowOverwriteChanged(object sender, RoutedEventArgs e)
        {
            if (_isInitializing)
            {
                return;
            }

            try
            {
                ReviewedCsvImportPlan refreshed = _refreshPlan(AllowOverwrite);
                _plan = refreshed;
                _refreshErrorText.Visibility = Visibility.Collapsed;
                RenderPlan(refreshed);
            }
            catch (Exception exception)
            {
                _refreshErrorText.Text = "无法按当前覆盖选项重新检查 CSV：" + exception.Message;
                _refreshErrorText.Visibility = Visibility.Visible;
                _confirmButton.IsEnabled = false;
            }
        }

        private void OnConfirmClick(object sender, RoutedEventArgs e)
        {
            if (!_plan.CanApply)
            {
                return;
            }

            IsConfirmed = true;
            DialogResult = true;
            Close();
        }

        private void RenderPlan(ReviewedCsvImportPlan plan)
        {
            string fileName = Path.GetFileName(plan.CsvPath);
            _summaryText.Text = "文件：" + fileName + Environment.NewLine
                + "候选行 " + plan.CandidateRows.ToString("N0", CultureInfo.CurrentCulture)
                + " · 可更新 " + plan.Updates.Count.ToString("N0", CultureInfo.CurrentCulture)
                + " 行（include " + plan.PlannedIncludeUpdates.ToString("N0", CultureInfo.CurrentCulture)
                + " 项，tags " + plan.PlannedTagUpdates.ToString("N0", CultureInfo.CurrentCulture) + " 项）"
                + Environment.NewLine
                + "空行 " + plan.EmptyRows.ToString("N0", CultureInfo.CurrentCulture)
                + " · 未变化 " + plan.UnchangedRows.ToString("N0", CultureInfo.CurrentCulture)
                + " · 未匹配 " + plan.UnknownRows.ToString("N0", CultureInfo.CurrentCulture)
                + " · 覆盖冲突 " + plan.ConflictedRows.ToString("N0", CultureInfo.CurrentCulture);

            _issueHeadingText.Text = plan.ErrorCount > 0
                ? "发现 " + plan.ErrorCount.ToString(CultureInfo.CurrentCulture) + " 个错误，必须修正后才能导入"
                : "检查完成：" + plan.WarningCount.ToString(CultureInfo.CurrentCulture) + " 条提示";
            _issueHeadingText.Foreground = new SolidColorBrush(plan.ErrorCount > 0
                ? Color.FromRgb(0xB4, 0x23, 0x18)
                : Color.FromRgb(0x1D, 0x30, 0x2C));

            _issuesList.Items.Clear();
            const int visibleIssueLimit = 120;
            foreach (ReviewImportIssue issue in plan.Issues.Take(visibleIssueLimit))
            {
                string prefix = issue.Severity == ReviewImportSeverity.Error ? "错误" : "提示";
                _issuesList.Items.Add(prefix + " · 第 " + issue.Line.ToString(CultureInfo.CurrentCulture)
                    + " 行 · " + issue.Message);
            }

            if (plan.Issues.Count == 0)
            {
                _issuesList.Items.Add("没有格式问题。确认后会在实际写入前再次检查，并在有变更时自动备份数据库。");
            }
            else if (plan.Issues.Count > visibleIssueLimit)
            {
                _issuesList.Items.Add("还有 " + (plan.Issues.Count - visibleIssueLimit).ToString(CultureInfo.CurrentCulture)
                    + " 条提示未在此展开；请先处理 CSV 中的错误。 ");
            }

            _confirmButton.IsEnabled = plan.CanApply;
            _confirmButton.Content = plan.CanApply
                ? (plan.HasChanges ? "确认导入" : "确认（没有可写变更）")
                : "请先修复错误";
        }

        private static Button CreateDialogButton(string text, bool isPrimary)
        {
            var button = new Button
            {
                Content = text,
                Padding = new Thickness(15, 8, 15, 8),
                FontSize = 13,
                FontWeight = FontWeights.SemiBold,
                Cursor = System.Windows.Input.Cursors.Hand,
                Background = isPrimary
                    ? new SolidColorBrush(Color.FromRgb(0x10, 0x9A, 0x8D))
                    : Brushes.White,
                Foreground = isPrimary
                    ? Brushes.White
                    : new SolidColorBrush(Color.FromRgb(0x1D, 0x30, 0x2C)),
                BorderBrush = isPrimary
                    ? new SolidColorBrush(Color.FromRgb(0x10, 0x9A, 0x8D))
                    : new SolidColorBrush(Color.FromRgb(0xDC, 0xE7, 0xE3)),
                BorderThickness = new Thickness(1),
            };
            return button;
        }
    }
}
