using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using Forms = System.Windows.Forms;
using LitNexus.Core.Workspace;

namespace LitNexus.Desktop
{
    /// <summary>
    /// Explicit project chooser. It presents local history but never opens a
    /// remembered path by itself; MainWindow owns the actual Core session.
    /// </summary>
    public partial class WorkspaceChooserWindow : Window
    {
        /// <summary>Folder selected by the user when DialogResult is true.</summary>
        public string? SelectedWorkspaceRoot { get; private set; }

        public WorkspaceChooserWindow(
            LocalWorkspaceStateStore localStateStore,
            string? initialPath = null,
            string? message = null)
        {
            if (localStateStore == null)
            {
                throw new ArgumentNullException(nameof(localStateStore));
            }

            InitializeComponent();
            WorkspacePathText.Text = string.IsNullOrWhiteSpace(initialPath)
                ? DefaultWorkspacePath()
                : initialPath;

            try
            {
                IReadOnlyList<string> recent = localStateStore.ListRecentWorkspacePaths();
                RecentItemsControl.ItemsSource = recent;
                RecentSection.Visibility = recent.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
            }
            catch (LocalWorkspaceStateException exception)
            {
                RecentSection.Visibility = Visibility.Collapsed;
                SetMessage("无法读取本机最近项目：" + exception.Message);
            }

            string visibleMessage = message ?? string.Empty;
            if (visibleMessage.Length > 0)
            {
                SetMessage(visibleMessage);
            }
        }

        private void OnBrowseClick(object sender, RoutedEventArgs e)
        {
            using (var dialog = new Forms.FolderBrowserDialog())
            {
                dialog.Description = "选择 LitNexus 项目文件夹";
                if (Directory.Exists(WorkspacePathText.Text))
                {
                    dialog.SelectedPath = WorkspacePathText.Text;
                }

                if (dialog.ShowDialog() == Forms.DialogResult.OK && !string.IsNullOrWhiteSpace(dialog.SelectedPath))
                {
                    WorkspacePathText.Text = dialog.SelectedPath;
                    MessageText.Visibility = Visibility.Collapsed;
                }
            }
        }

        private void OnRecentClick(object sender, RoutedEventArgs e)
        {
            var button = sender as Button;
            string? path = button?.Tag as string;
            if (string.IsNullOrWhiteSpace(path))
            {
                return;
            }

            WorkspacePathText.Text = path;
            MessageText.Visibility = Visibility.Collapsed;
        }

        private void OnOpenClick(object sender, RoutedEventArgs e)
        {
            string rawPath = WorkspacePathText.Text ?? string.Empty;
            if (string.IsNullOrWhiteSpace(rawPath))
            {
                SetMessage("请先选择或输入项目文件夹。");
                return;
            }

            try
            {
                SelectedWorkspaceRoot = Path.GetFullPath(rawPath.Trim());
                DialogResult = true;
            }
            catch (Exception exception) when (
                exception is ArgumentException || exception is NotSupportedException || exception is PathTooLongException)
            {
                SetMessage("项目路径无效：" + exception.Message);
            }
        }

        private void OnCancelClick(object sender, RoutedEventArgs e)
        {
            DialogResult = false;
        }

        private void SetMessage(string message)
        {
            MessageText.Text = message;
            MessageText.Visibility = Visibility.Visible;
        }

        private static string DefaultWorkspacePath()
        {
            string documents = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
            string baseDirectory = string.IsNullOrWhiteSpace(documents)
                ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)
                : documents;
            return Path.Combine(baseDirectory, "文献项目");
        }
    }
}
