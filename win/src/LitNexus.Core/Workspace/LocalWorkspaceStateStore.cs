using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace LitNexus.Core.Workspace
{
    /// <summary>
    /// Failure while reading or writing this device's optional workspace history.
    /// It never indicates that a portable LitNexus workspace itself is invalid.
    /// </summary>
    public sealed class LocalWorkspaceStateException : Exception
    {
        /// <summary>Initializes an exception with a user-facing explanation.</summary>
        public LocalWorkspaceStateException(string message)
            : base(message)
        {
        }

        /// <summary>Initializes an exception with its underlying I/O or JSON failure.</summary>
        public LocalWorkspaceStateException(string message, Exception innerException)
            : base(message, innerException)
        {
        }
    }

    /// <summary>
    /// Device-local project chooser state. Paths in this object are deliberately
    /// allowed to be stale: a disconnected drive or moved project should remain
    /// visible as a recent choice rather than being silently forgotten.
    /// </summary>
    public sealed class LocalWorkspaceState
    {
        /// <summary>The current JSON format revision.</summary>
        public const int CurrentFormatVersion = 1;

        /// <summary>JSON format revision for forward-compatible local state.</summary>
        [JsonPropertyName("version")]
        public int Version { get; set; } = CurrentFormatVersion;

        /// <summary>
        /// Last successfully opened workspace root on this device, or null when
        /// the chooser has no current project. This is never copied into TOML.
        /// </summary>
        [JsonPropertyName("current_workspace")]
        public string? CurrentWorkspacePath { get; set; }

        /// <summary>
        /// Most-recent-first workspace roots remembered on this device. Entries
        /// are only suggestions for the project chooser; they are not opened
        /// implicitly by Core.
        /// </summary>
        [JsonPropertyName("recent_workspaces")]
        public List<string> RecentWorkspacePaths { get; set; } = new List<string>();

        internal void Normalize(int maximumRecent)
        {
            if (maximumRecent < 1)
            {
                throw new ArgumentOutOfRangeException(nameof(maximumRecent));
            }

            Version = CurrentFormatVersion;
            RecentWorkspacePaths = RecentWorkspacePaths ?? new List<string>();

            string? normalizedCurrent;
            bool hasCurrent = TryNormalizeStoredPath(CurrentWorkspacePath, out normalizedCurrent);
            var normalizedRecent = new List<string>();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            if (hasCurrent && normalizedCurrent != null)
            {
                normalizedRecent.Add(normalizedCurrent);
                seen.Add(normalizedCurrent);
            }

            foreach (string? candidate in RecentWorkspacePaths)
            {
                string? normalized;
                if (!TryNormalizeStoredPath(candidate, out normalized)
                    || normalized == null
                    || !seen.Add(normalized))
                {
                    continue;
                }

                normalizedRecent.Add(normalized);
                if (normalizedRecent.Count == maximumRecent)
                {
                    break;
                }
            }

            CurrentWorkspacePath = hasCurrent ? normalizedCurrent : null;
            RecentWorkspacePaths = normalizedRecent;
        }

        private static bool TryNormalizeStoredPath(string? value, out string? normalized)
        {
            normalized = null;
            string rawPath = value ?? string.Empty;
            if (string.IsNullOrWhiteSpace(rawPath))
            {
                return false;
            }

            try
            {
                normalized = Path.GetFullPath(rawPath.Trim());
                return true;
            }
            catch (ArgumentException)
            {
                return false;
            }
            catch (NotSupportedException)
            {
                return false;
            }
            catch (PathTooLongException)
            {
                return false;
            }
        }
    }

    /// <summary>
    /// JSON persistence for the current/recent workspace chooser on one Windows
    /// device. The default path is <c>%LOCALAPPDATA%\LitNexus\state.json</c>.
    /// This store does not decide which project to open and never writes a path
    /// into a workspace's portable <c>litnexus.toml</c>.
    /// </summary>
    public sealed class LocalWorkspaceStateStore
    {
        /// <summary>Maximum number of recent workspace roots retained by default.</summary>
        public const int DefaultMaximumRecentWorkspaces = 10;

        private static readonly JsonSerializerOptions JsonOptions = new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
            WriteIndented = true,
        };

        private readonly object _syncRoot = new object();

        /// <summary>
        /// Creates a state store at one explicit JSON path. Tests and alternate
        /// hosts can use this overload to avoid touching the user's AppData.
        /// </summary>
        /// <param name="stateFilePath">Absolute or relative path to state.json.</param>
        /// <param name="maximumRecentWorkspaces">Number of entries to retain.</param>
        public LocalWorkspaceStateStore(
            string stateFilePath,
            int maximumRecentWorkspaces = DefaultMaximumRecentWorkspaces)
        {
            if (string.IsNullOrWhiteSpace(stateFilePath))
            {
                throw new ArgumentException("必须提供本机项目状态文件路径。", nameof(stateFilePath));
            }

            if (maximumRecentWorkspaces < 1)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(maximumRecentWorkspaces), "最近项目数量至少为 1。");
            }

            StateFilePath = Path.GetFullPath(stateFilePath);
            MaximumRecentWorkspaces = maximumRecentWorkspaces;
        }

        /// <summary>JSON state-file path for this device-local store.</summary>
        public string StateFilePath { get; private set; }

        /// <summary>Maximum number of recent roots retained after each write.</summary>
        public int MaximumRecentWorkspaces { get; private set; }

        /// <summary>
        /// Gets the standard state store for the current Windows account using
        /// the operating system's LocalApplicationData folder, not an
        /// environment-variable workspace override.
        /// </summary>
        public static LocalWorkspaceStateStore ForCurrentUser()
        {
            string appData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (string.IsNullOrWhiteSpace(appData))
            {
                throw new LocalWorkspaceStateException("无法确定当前用户的 LocalAppData 目录。");
            }

            return new LocalWorkspaceStateStore(
                Path.Combine(appData, "LitNexus", "state.json"));
        }

        /// <summary>
        /// Reads the current chooser state. A missing file is a valid fresh-install
        /// state. Invalid individual paths are ignored while valid stale paths
        /// remain available to the project chooser.
        /// </summary>
        public LocalWorkspaceState Load()
        {
            lock (_syncRoot)
            {
                return LoadUnsafe();
            }
        }

        /// <summary>
        /// Replaces the local state after normalization and writes it atomically.
        /// This only changes the AppData JSON file, never a workspace file.
        /// </summary>
        public void Save(LocalWorkspaceState state)
        {
            if (state == null)
            {
                throw new ArgumentNullException(nameof(state));
            }

            lock (_syncRoot)
            {
                SaveUnsafe(state);
            }
        }

        /// <summary>
        /// Marks one explicitly selected workspace as the current project and
        /// moves it to the top of the local recent-project list.
        /// </summary>
        public void RememberOpenedWorkspace(string explicitWorkspaceRoot)
        {
            string root = NormalizeExplicitWorkspaceRoot(explicitWorkspaceRoot);
            lock (_syncRoot)
            {
                LocalWorkspaceState state = LoadUnsafe();
                state.CurrentWorkspacePath = root;
                state.RecentWorkspacePaths = new[] { root }
                    .Concat(state.RecentWorkspacePaths ?? Enumerable.Empty<string>())
                    .ToList();
                SaveUnsafe(state);
            }
        }

        /// <summary>
        /// Clears only the current-project pointer. Existing recent entries are
        /// retained so the chooser can still offer them to the user.
        /// </summary>
        public void ClearCurrentWorkspace()
        {
            lock (_syncRoot)
            {
                LocalWorkspaceState state = LoadUnsafe();
                state.CurrentWorkspacePath = null;
                SaveUnsafe(state);
            }
        }

        /// <summary>
        /// Removes one root from local chooser history. If it is current, the
        /// current-project pointer is cleared rather than silently selecting a
        /// different recent workspace.
        /// </summary>
        public void ForgetWorkspace(string explicitWorkspaceRoot)
        {
            string root = NormalizeExplicitWorkspaceRoot(explicitWorkspaceRoot);
            lock (_syncRoot)
            {
                LocalWorkspaceState state = LoadUnsafe();
                state.RecentWorkspacePaths = (state.RecentWorkspacePaths ?? new List<string>())
                    .Where(path => !string.Equals(path, root, StringComparison.OrdinalIgnoreCase))
                    .ToList();
                if (string.Equals(state.CurrentWorkspacePath, root, StringComparison.OrdinalIgnoreCase))
                {
                    state.CurrentWorkspacePath = null;
                }

                SaveUnsafe(state);
            }
        }

        /// <summary>
        /// Returns recent workspace roots in most-recent-first order. Callers
        /// must present a user choice and pass the chosen root explicitly to
        /// <see cref="WorkspaceSession.Open(string)"/>.
        /// </summary>
        public IReadOnlyList<string> ListRecentWorkspacePaths()
        {
            return Load().RecentWorkspacePaths.ToArray();
        }

        private LocalWorkspaceState LoadUnsafe()
        {
            if (!File.Exists(StateFilePath))
            {
                return new LocalWorkspaceState();
            }

            try
            {
                string content = File.ReadAllText(StateFilePath, Encoding.UTF8);
                LocalWorkspaceState? state = JsonSerializer.Deserialize<LocalWorkspaceState>(content, JsonOptions);
                if (state == null)
                {
                    throw new LocalWorkspaceStateException("本机项目状态文件没有可读取的 JSON 内容。");
                }

                state.Normalize(MaximumRecentWorkspaces);
                return state;
            }
            catch (LocalWorkspaceStateException)
            {
                throw;
            }
            catch (Exception exception)
            {
                throw new LocalWorkspaceStateException(
                    "无法读取本机项目状态文件：" + StateFilePath, exception);
            }
        }

        private void SaveUnsafe(LocalWorkspaceState state)
        {
            state.Normalize(MaximumRecentWorkspaces);
            string? directory = Path.GetDirectoryName(StateFilePath);
            if (string.IsNullOrEmpty(directory))
            {
                throw new LocalWorkspaceStateException("无法确定本机项目状态文件目录：" + StateFilePath);
            }

            try
            {
                Directory.CreateDirectory(directory);
                string content = JsonSerializer.Serialize(state, JsonOptions);
                WriteAtomically(StateFilePath, content);
            }
            catch (LocalWorkspaceStateException)
            {
                throw;
            }
            catch (Exception exception)
            {
                throw new LocalWorkspaceStateException(
                    "无法保存本机项目状态文件：" + StateFilePath, exception);
            }
        }

        private static string NormalizeExplicitWorkspaceRoot(string explicitWorkspaceRoot)
        {
            if (string.IsNullOrWhiteSpace(explicitWorkspaceRoot))
            {
                throw new ArgumentException("必须显式提供项目文件夹。", nameof(explicitWorkspaceRoot));
            }

            return Path.GetFullPath(explicitWorkspaceRoot.Trim());
        }

        private static void WriteAtomically(string destination, string content)
        {
            string temporary = destination + ".tmp-" + Guid.NewGuid().ToString("N");
            try
            {
                File.WriteAllText(temporary, content, new UTF8Encoding(false));
                if (!File.Exists(destination))
                {
                    File.Move(temporary, destination);
                    return;
                }

                // Retaining the last readable local state is safer than a
                // delete-then-move fallback should replacement fail.
                File.Replace(temporary, destination, null);
            }
            finally
            {
                if (File.Exists(temporary))
                {
                    File.Delete(temporary);
                }
            }
        }
    }
}
