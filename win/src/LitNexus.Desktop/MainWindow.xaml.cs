using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using LitNexus.Desktop.Controls;
using LitNexus.Core.Workspace;

namespace LitNexus.Desktop
{
    /// <summary>
    /// WPF shell for one desktop process. Persistent workspace handling lives in
    /// WorkspaceSession/LocalWorkspaceStateStore; this type only presents their
    /// explicit open/create/switch flow and owns the current session lifetime.
    /// </summary>
    public partial class MainWindow : Window
    {
        private enum WorkspacePage
        {
            Run,
            Data,
            Statistics,
            Settings
        }

        private LocalWorkspaceStateStore? _localStateStore;
        private WorkspaceSession? _workspaceSession;
        private WorkspacePage _currentPage = WorkspacePage.Run;
        private bool _startupHandled;

        public MainWindow()
        {
            InitializeComponent();
            SettingsPanel.SaveRequested += OnSettingsSaveRequested;
            DataPanel.ExportFilterChanged += OnDataExportFilterChanged;
            DataPanel.ExportColumnsChanged += OnDataExportColumnsChanged;
            DataPanel.ExportCompleted += OnDataExportCompleted;
            DataPanel.ReviewImportCompleted += OnDataReviewImportCompleted;
            SelectPage(WorkspacePage.Run);
            try
            {
                _localStateStore = LocalWorkspaceStateStore.ForCurrentUser();
            }
            catch (Exception exception)
            {
                SetNoWorkspacePresentation("无法准备本机项目记录：" + exception.Message);
            }

            Loaded += OnWindowLoaded;
            Closed += OnWindowClosed;
        }

        private void OnWindowLoaded(object sender, RoutedEventArgs e)
        {
            if (_startupHandled)
            {
                return;
            }

            _startupHandled = true;
            RestoreCurrentWorkspaceOrChoose();
        }

        private void OnWindowClosed(object? sender, EventArgs e)
        {
            SettingsPanel.SaveRequested -= OnSettingsSaveRequested;
            DataPanel.ExportFilterChanged -= OnDataExportFilterChanged;
            DataPanel.ExportColumnsChanged -= OnDataExportColumnsChanged;
            DataPanel.ExportCompleted -= OnDataExportCompleted;
            DataPanel.ReviewImportCompleted -= OnDataReviewImportCompleted;
            _workspaceSession?.Dispose();
            _workspaceSession = null;
        }

        private void OnNavigationClick(object sender, RoutedEventArgs e)
        {
            ToggleButton? button = sender as ToggleButton;
            string? pageName = button?.Tag as string;

            if (String.Equals(pageName, "Data", StringComparison.Ordinal))
            {
                SelectPage(WorkspacePage.Data);
            }
            else if (String.Equals(pageName, "Statistics", StringComparison.Ordinal))
            {
                SelectPage(WorkspacePage.Statistics);
            }
            else if (String.Equals(pageName, "Settings", StringComparison.Ordinal))
            {
                SelectPage(WorkspacePage.Settings);
            }
            else
            {
                SelectPage(WorkspacePage.Run);
            }
        }

        private void OnRevealProjectClick(object sender, RoutedEventArgs e)
        {
            WorkspaceSession? session = _workspaceSession;
            if (session == null || session.IsDisposed)
            {
                return;
            }

            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = session.Paths.RootDirectory,
                    UseShellExecute = true,
                });
            }
            catch (Exception exception)
            {
                MessageBox.Show(
                    this,
                    "无法打开项目目录：" + exception.Message,
                    "LitNexus",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }

        private void OnSwitchProjectClick(object sender, RoutedEventArgs e)
        {
            ShowWorkspaceChooser(_workspaceSession == null ? null : _workspaceSession.Paths.RootDirectory, null);
        }

        private void OnSettingsSaveRequested(object? sender, SettingsSaveRequestedEventArgs e)
        {
            WorkspaceSession? session = _workspaceSession;
            if (session == null || session.IsDisposed)
            {
                throw new InvalidOperationException("当前没有可保存配置的项目。请先打开项目。");
            }

            session.ReplaceConfig(e.Configuration);
            ApplyProjectAccent(session);
            SettingsPanel.Load(session);
            ProjectHintText.Text = "项目配置已保存；本机显示与项目数据仍保持分层。";
        }

        private void OnDataExportFilterChanged(object? sender, DataPanelExportFilterChangedEventArgs e)
        {
            WorkspaceSession? session = _workspaceSession;
            if (session == null || session.IsDisposed)
            {
                return;
            }

            try
            {
                // The Data panel intentionally only raises this choice. The
                // shell decides to mirror the established Mac behavior: scope
                // selection is a project preference and is auto-saved here.
                session.Config.Export.Filter = e.Filter;
                session.SaveConfig();
                ProjectHintText.Text = "已记住 CSV 导出范围：" + e.Filter + "。";
            }
            catch (Exception exception)
            {
                try
                {
                    session.ReloadConfig();
                    DataPanel.Load(session);
                }
                catch
                {
                    // The original save failure remains the actionable error;
                    // a failed recovery must not hide it.
                }

                MessageBox.Show(
                    this,
                    "无法保存导出范围：" + exception.Message,
                    "LitNexus",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }

        private void OnDataExportColumnsChanged(object? sender, DataPanelExportColumnsChangedEventArgs e)
        {
            WorkspaceSession? session = _workspaceSession;
            if (session == null || session.IsDisposed)
            {
                return;
            }

            try
            {
                // Column choices belong to the project, but the Data panel is
                // deliberately presentation-only. Saving here mirrors the Mac
                // contract without coupling the reusable control to a session.
                session.Config.Export.ExcludeColumns = new List<string>(e.ExcludeColumns);
                session.SaveConfig();
                ProjectHintText.Text = "已记住 CSV 导出列选择。";
            }
            catch (Exception exception)
            {
                try
                {
                    session.ReloadConfig();
                    DataPanel.Load(session);
                }
                catch
                {
                    // Preserve the original persistence error as the useful
                    // recovery signal if reopening the config also fails.
                }

                MessageBox.Show(
                    this,
                    "无法保存导出列选择：" + exception.Message,
                    "LitNexus",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }

        private void OnDataExportCompleted(object? sender, DataPanelExportCompletedEventArgs e)
        {
            ProjectHintText.Text = e.Result.FileCreated
                ? "已导出 " + e.Result.WrittenRows.ToString() + " 篇文章。"
                : "当前导出范围没有文章；没有创建 CSV。";
        }

        private void OnDataReviewImportCompleted(object? sender, DataPanelReviewImportCompletedEventArgs e)
        {
            ProjectHintText.Text = "已导入复筛结果：更新 "
                + e.Result.ImportResult.UpdatedRows.ToString()
                + " 行；自动备份位于 litnexus.db.bak。";
        }

        private void RestoreCurrentWorkspaceOrChoose()
        {
            LocalWorkspaceStateStore? stateStore = _localStateStore;
            if (stateStore == null)
            {
                MessageBox.Show(
                    this,
                    "无法使用本机项目记录。请检查 Windows LocalAppData 目录后重新启动。",
                    "LitNexus",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
                return;
            }

            string? rememberedPath = null;
            string? message = null;
            try
            {
                rememberedPath = stateStore.Load().CurrentWorkspacePath;
            }
            catch (LocalWorkspaceStateException exception)
            {
                message = "无法读取本机最近项目：" + exception.Message;
            }

            string activeWorkspacePath = rememberedPath ?? string.Empty;
            if (!string.IsNullOrWhiteSpace(activeWorkspacePath))
            {
                try
                {
                    AttachWorkspaceSession(WorkspaceSession.Open(activeWorkspacePath), rememberAsCurrent: false);
                    return;
                }
                catch (Exception exception)
                {
                    message = "上次打开的项目暂时无法打开：" + exception.Message;
                }
            }

            ShowWorkspaceChooser(rememberedPath, message);
        }

        /// <summary>
        /// Opens a chooser only in response to startup or an explicit switch.
        /// A saved path is merely pre-filled; the dialog/result makes the action
        /// explicit before a new workspace can be created.
        /// </summary>
        private void ShowWorkspaceChooser(string? initialPath, string? initialMessage)
        {
            LocalWorkspaceStateStore? stateStore = _localStateStore;
            if (stateStore == null)
            {
                return;
            }

            string? path = initialPath;
            string? message = initialMessage;
            while (true)
            {
                var chooser = new WorkspaceChooserWindow(stateStore, path, message)
                {
                    Owner = this,
                };
                bool? accepted = chooser.ShowDialog();
                string selectedWorkspacePath = chooser.SelectedWorkspaceRoot ?? string.Empty;
                if (accepted != true || string.IsNullOrWhiteSpace(selectedWorkspacePath))
                {
                    return;
                }

                path = selectedWorkspacePath;
                try
                {
                    // Create deliberately means "open if initialized, otherwise
                    // create defaults"—the same safe action exposed by Mac.
                    AttachWorkspaceSession(WorkspaceSession.Create(selectedWorkspacePath), rememberAsCurrent: true);
                    return;
                }
                catch (Exception exception)
                {
                    message = "无法打开或新建项目：" + exception.Message;
                }
            }
        }

        private void AttachWorkspaceSession(WorkspaceSession session, bool rememberAsCurrent)
        {
            if (session == null)
            {
                throw new ArgumentNullException(nameof(session));
            }

            WorkspaceSession? previous = _workspaceSession;
            _workspaceSession = session;
            try
            {
                if (rememberAsCurrent && _localStateStore != null)
                {
                    session.RememberAsCurrent(_localStateStore);
                }
            }
            catch (LocalWorkspaceStateException exception)
            {
                // Opening the project is still valid if only local history could
                // not be saved. Make that distinction visible rather than
                // closing a healthy workspace session.
                ProjectHintText.Text = "项目已打开，但无法更新本机最近项目：" + exception.Message;
            }

            previous?.Dispose();
            SetWorkspacePresentation(session);
            ApplyProjectAccent(session);
            SelectPage(_currentPage);
        }

        private void SetWorkspacePresentation(WorkspaceSession session)
        {
            string name = new DirectoryInfo(session.Paths.RootDirectory).Name;
            ProjectNameText.Text = string.IsNullOrWhiteSpace(name) ? session.Paths.RootDirectory : name;
            ProjectActionsPanel.Visibility = Visibility.Visible;
            ProjectHintText.Text = "本机已记住当前项目，可随时切换。";
            WorkspaceStatusText.Text = "项目已打开";
        }

        private void SetNoWorkspacePresentation(string hint)
        {
            ProjectNameText.Text = "未选择项目";
            ProjectActionsPanel.Visibility = Visibility.Collapsed;
            ProjectHintText.Text = hint;
            WorkspaceStatusText.Text = "未选择项目";
            ApplyProjectAccent(null);
            DataPanel.Clear();
        }

        private void SelectPage(WorkspacePage page)
        {
            _currentPage = page;
            switch (page)
            {
                case WorkspacePage.Data:
                    SetPageContent(
                        "▣",
                        "数据",
                        "查看、导出和导入复筛结果。",
                        "数据工作区尚未接入",
                        "Windows 端会先验证文章库、可变问题列与 CSV 复筛导入的兼容边界。",
                        "下一步：验证数据库迁移、备份与复筛写入。",
                        "数据功能会保持默认不覆盖既有人工标注的安全语义。");
                    break;

                case WorkspacePage.Statistics:
                    SetPageContent(
                        "▥",
                        "统计",
                        "从当前工作区查看基础分布与评估结果。",
                        "统计快照尚未接入",
                        "统计将建立在同一份 SQLite 数据上，并明确区分基础分布、提示词评估与期刊评估。",
                        "下一步：验证跨端统计口径和可持久化的页面偏好。",
                        "筛选、折叠和排序会在数据契约稳定后再逐步实现。");
                    break;

                case WorkspacePage.Settings:
                    SetPageContent(
                        "⚙",
                        "配置",
                        "管理项目的检索、分类、AI 与外观设置。",
                        "项目配置尚未接入",
                        "Windows 端会读取与 Mac 相同的 litnexus.toml，并保留本机显示偏好与项目配置的边界。",
                        "下一步：验证 TOML 往返、兼容回退与自动保存。",
                        "配置页面会按用途分组，避免把尚未实现的设置伪装成可用操作。");
                    break;

                default:
                    SetPageContent(
                        "▶",
                        "运行",
                        "处理下载、合并、翻译与分类。",
                        "运行工作区尚未接入",
                        "Windows 端正先验证与 Mac 项目相同的配置、SQLite 与复筛 CSV 契约。",
                        "下一步：建立并验证真实工作区的读取边界。",
                        "功能将按跨端契约逐页接入；这个基础壳不会修改项目数据。");
                    break;
            }

            ApplyWorkspaceContextToPage();
            UpdateFeaturePanels();
            SetNavigationState(RunNavigationButton, page == WorkspacePage.Run);
            SetNavigationState(DataNavigationButton, page == WorkspacePage.Data);
            SetNavigationState(StatisticsNavigationButton, page == WorkspacePage.Statistics);
            SetNavigationState(SettingsNavigationButton, page == WorkspacePage.Settings);
        }

        private void ApplyWorkspaceContextToPage()
        {
            WorkspaceSession? session = _workspaceSession;
            if (session == null || session.IsDisposed)
            {
                return;
            }

            string name = new DirectoryInfo(session.Paths.RootDirectory).Name;
            PrimaryCardTitleText.Text = "已连接项目，页面功能正在接入";
            PrimaryCardDescriptionText.Text = "当前项目「" + name
                + "」已通过 Windows 的工作区与数据库兼容检查。此页面暂不执行任何修改项目数据的操作。";
            PrimaryCardStatusText.Text = "项目位置：" + session.Paths.RootDirectory;
            SecondaryCardDescriptionText.Text = "项目配置、SQLite 数据库与本机最近项目记录已分层管理；下一步将把这个页面的实际功能接入同一会话。";
        }

        private void UpdateFeaturePanels()
        {
            WorkspaceSession? session = _workspaceSession;
            bool showSettings = _currentPage == WorkspacePage.Settings
                && session != null
                && !session.IsDisposed;
            bool showData = _currentPage == WorkspacePage.Data
                && session != null
                && !session.IsDisposed;

            PlaceholderContentPanel.Visibility = showSettings || showData ? Visibility.Collapsed : Visibility.Visible;
            SettingsPanel.Visibility = showSettings ? Visibility.Visible : Visibility.Collapsed;
            DataPanel.Visibility = showData ? Visibility.Visible : Visibility.Collapsed;
            if (showSettings && session != null)
            {
                SettingsPanel.Load(session);
            }

            if (showData && session != null)
            {
                DataPanel.Load(session);
            }
        }

        private void ApplyProjectAccent(WorkspaceSession? session)
        {
            double? hue = session == null ? null : session.Config.Theme.AccentHue;
            Color accent = hue.HasValue
                ? HsvToColor(hue.Value, 0.72d, 0.65d)
                : Color.FromRgb(0x10, 0x9A, 0x8D);
            SetResourceBrushColor("AccentBrush", accent);
            SetResourceBrushColor("AccentSoftBrush", Blend(Color.FromRgb(0xFF, 0xFF, 0xFF), accent, 0.14d));
            SetResourceBrushColor("AccentLineBrush", Blend(Color.FromRgb(0xFF, 0xFF, 0xFF), accent, 0.30d));
        }

        private void SetResourceBrushColor(string key, Color color)
        {
            SolidColorBrush? brush = Resources[key] as SolidColorBrush;
            if (brush != null && !brush.IsFrozen)
            {
                brush.Color = color;
            }
        }

        private static Color Blend(Color from, Color to, double amount)
        {
            double bounded = Math.Max(0d, Math.Min(1d, amount));
            return Color.FromRgb(
                ToColorByte(from.R + ((to.R - from.R) * bounded)),
                ToColorByte(from.G + ((to.G - from.G) * bounded)),
                ToColorByte(from.B + ((to.B - from.B) * bounded)));
        }

        private static Color HsvToColor(double hue, double saturation, double value)
        {
            double normalizedHue = hue - Math.Floor(hue);
            double chroma = value * saturation;
            double position = normalizedHue * 6d;
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
            return (byte)Math.Round(Math.Max(0d, Math.Min(1d, component)) * 255d, MidpointRounding.AwayFromZero);
        }

        private void SetPageContent(
            string glyph,
            string title,
            string subtitle,
            string primaryTitle,
            string primaryDescription,
            string primaryStatus,
            string secondaryDescription)
        {
            PageGlyphText.Text = glyph;
            PageTitleText.Text = title;
            PageSubtitleText.Text = subtitle;
            PrimaryCardTitleText.Text = primaryTitle;
            PrimaryCardDescriptionText.Text = primaryDescription;
            PrimaryCardStatusText.Text = primaryStatus;
            SecondaryCardTitleText.Text = "功能将按跨端契约逐页接入";
            SecondaryCardDescriptionText.Text = secondaryDescription;
            BreadcrumbText.Text = title;
            Title = "LitNexus — " + title;
        }

        private static void SetNavigationState(ToggleButton button, bool isSelected)
        {
            button.IsChecked = isSelected;
        }
    }
}
