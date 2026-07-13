using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace LitNexus.Core.Workspace
{
    /// <summary>
    /// All filesystem locations inside one explicitly selected workspace root.
    /// This type deliberately has no concept of an environment-variable override,
    /// a process working directory, or a globally active workspace.
    /// </summary>
    public sealed class WorkspacePaths
    {
        public WorkspacePaths(string explicitRoot)
        {
            if (string.IsNullOrWhiteSpace(explicitRoot))
            {
                throw new ArgumentException("必须显式提供项目文件夹。", nameof(explicitRoot));
            }

            RootDirectory = Path.GetFullPath(explicitRoot);
        }

        public string RootDirectory { get; private set; }

        public string ConfigPath
        {
            get { return Path.Combine(RootDirectory, "litnexus.toml"); }
        }

        public string DatabasePath
        {
            get { return Path.Combine(RootDirectory, "litnexus.db"); }
        }

        public string DownloadsDirectory
        {
            get { return Path.Combine(RootDirectory, "downloads"); }
        }

        public string MergedDownloadsDirectory
        {
            get { return Path.Combine(DownloadsDirectory, "_merged"); }
        }

        public string ExportsDirectory
        {
            get { return Path.Combine(RootDirectory, "exports"); }
        }

        /// <summary>Pre-TOML compatibility input only; new projects do not write it.</summary>
        public string JournalsFile
        {
            get { return Path.Combine(RootDirectory, "journals.txt"); }
        }

        /// <summary>Pre-TOML compatibility input only; new projects do not write it.</summary>
        public string KeywordsFile
        {
            get { return Path.Combine(RootDirectory, "keywords.txt"); }
        }

        /// <summary>Pre-TOML compatibility input only; new projects do not write it.</summary>
        public string KeywordsDirectory
        {
            get { return Path.Combine(RootDirectory, "keywords"); }
        }

        public bool IsInitialized
        {
            get { return File.Exists(ConfigPath); }
        }

        /// <summary>
        /// The root keywords.txt followed by all keyword/*.txt files in stable
        /// ordinal order. If none exist, the conventional root path is returned
        /// so compatibility readers can simply test it for existence.
        /// </summary>
        public IReadOnlyList<string> LegacyKeywordFiles
        {
            get
            {
                var files = new List<string>();
                if (File.Exists(KeywordsFile))
                {
                    files.Add(KeywordsFile);
                }

                if (Directory.Exists(KeywordsDirectory))
                {
                    files.AddRange(Directory.GetFiles(KeywordsDirectory, "*.txt", SearchOption.TopDirectoryOnly)
                        .OrderBy(path => path, StringComparer.Ordinal));
                }

                if (files.Count == 0)
                {
                    files.Add(KeywordsFile);
                }

                return files;
            }
        }

        public static WorkspacePaths ForRoot(string explicitRoot)
        {
            return new WorkspacePaths(explicitRoot);
        }

        /// <summary>
        /// Creates only directories that are part of the workspace layout. It
        /// never creates an implicit user-wide state file or chooses a project.
        /// </summary>
        public void EnsureDirectories()
        {
            Directory.CreateDirectory(RootDirectory);
            Directory.CreateDirectory(DownloadsDirectory);
            Directory.CreateDirectory(MergedDownloadsDirectory);
            Directory.CreateDirectory(ExportsDirectory);
        }
    }

    public sealed class WorkspaceException : Exception
    {
        public WorkspaceException(string message)
            : base(message)
        {
        }
    }

    /// <summary>
    /// Explicit workspace creation/opening. The host may persist a recent-project
    /// list through <see cref="LocalWorkspaceStateStore"/>, but this layer never
    /// reads it to decide what project to open.
    /// </summary>
    public static class WorkspaceStore
    {
        public static WorkspacePaths Create(string explicitRoot, bool overwriteConfig = false)
        {
            WorkspacePaths workspace = WorkspacePaths.ForRoot(explicitRoot);
            workspace.EnsureDirectories();
            if (overwriteConfig || !workspace.IsInitialized)
            {
                ConfigStore.Save(LitNexus.Core.Domain.AppConfig.CreateDefault(), workspace);
            }

            return workspace;
        }

        public static WorkspacePaths Open(string explicitRoot)
        {
            WorkspacePaths workspace = WorkspacePaths.ForRoot(explicitRoot);
            if (!workspace.IsInitialized)
            {
                throw new WorkspaceException(
                    "工作区未初始化：" + workspace.RootDirectory + "（缺少 litnexus.toml）。");
            }

            // A valid legacy/Mac workspace may predate one of the conventional
            // support directories. Opening it may add only empty layout
            // directories; it never rewrites TOML or SQLite data.
            workspace.EnsureDirectories();
            return workspace;
        }
    }
}
