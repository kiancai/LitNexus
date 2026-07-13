using System;
using LitNexus.Core.Domain;
using LitNexus.Core.Persistence;

namespace LitNexus.Core.Workspace
{
    /// <summary>
    /// Owns one explicitly opened LitNexus workspace: its portable paths,
    /// loaded TOML configuration, current dynamic-schema projection, and one
    /// live SQLite connection. It is not a global active-project singleton and
    /// is not thread-safe; UI/pipeline coordination belongs to a later layer.
    /// </summary>
    public sealed class WorkspaceSession : IDisposable
    {
        private readonly LitNexusDatabase _database;
        private bool _disposed;

        private WorkspaceSession(
            WorkspacePaths paths,
            AppConfig config,
            DatabaseSchemaDefinition databaseSchema,
            LitNexusDatabase database)
        {
            Paths = paths;
            Config = config;
            DatabaseSchema = databaseSchema;
            _database = database;
        }

        /// <summary>Portable file and directory locations for this workspace.</summary>
        public WorkspacePaths Paths { get; private set; }

        /// <summary>
        /// In-memory configuration loaded from this workspace's
        /// <c>litnexus.toml</c>. After editing it, call <see cref="SaveConfig"/>
        /// so TOML and additive dynamic database columns remain synchronized.
        /// </summary>
        public AppConfig Config { get; private set; }

        /// <summary>
        /// Current projection of <see cref="Config"/> used to open/synchronize
        /// the dynamic SQLite schema.
        /// </summary>
        public DatabaseSchemaDefinition DatabaseSchema { get; private set; }

        /// <summary>
        /// Open SQLite database for this session. It becomes unusable together
        /// with the session after <see cref="Dispose"/>.
        /// </summary>
        public LitNexusDatabase Database
        {
            get
            {
                ThrowIfDisposed();
                return _database;
            }
        }

        /// <summary>Whether this session has already released its SQLite handle.</summary>
        public bool IsDisposed
        {
            get { return _disposed; }
        }

        /// <summary>
        /// Creates a workspace at one explicitly selected root, writes a default
        /// TOML only when needed, then loads that TOML and opens the database.
        /// No current-project state or environment variable participates.
        /// </summary>
        /// <param name="explicitRoot">Folder chosen by the user.</param>
        /// <param name="overwriteConfig">Whether an existing TOML may be replaced by defaults.</param>
        public static WorkspaceSession Create(string explicitRoot, bool overwriteConfig = false)
        {
            WorkspacePaths paths = WorkspaceStore.Create(explicitRoot, overwriteConfig);
            return OpenWorkspace(paths);
        }

        /// <summary>
        /// Opens an already initialized workspace at one explicit root. The
        /// caller may read <see cref="LocalWorkspaceStateStore"/> to populate a
        /// chooser, but this method never resolves or opens a remembered path.
        /// </summary>
        /// <param name="explicitRoot">Folder the user explicitly chose to open.</param>
        public static WorkspaceSession Open(string explicitRoot)
        {
            WorkspacePaths paths = WorkspaceStore.Open(explicitRoot);
            return OpenWorkspace(paths);
        }

        /// <summary>
        /// Records this already opened workspace in an explicitly supplied
        /// device-local state store. The update only writes AppData JSON and
        /// never puts an absolute path into <c>litnexus.toml</c>.
        /// </summary>
        /// <param name="localStateStore">The local store chosen by the host.</param>
        public void RememberAsCurrent(LocalWorkspaceStateStore localStateStore)
        {
            ThrowIfDisposed();
            if (localStateStore == null)
            {
                throw new ArgumentNullException(nameof(localStateStore));
            }

            localStateStore.RememberOpenedWorkspace(Paths.RootDirectory);
        }

        /// <summary>
        /// Reloads TOML from disk and applies any missing, additive dynamic
        /// columns and question metadata before replacing the in-memory config.
        /// It never drops historical columns merely because a question was
        /// removed from the currently visible configuration.
        /// </summary>
        public void ReloadConfig()
        {
            ThrowIfDisposed();
            AppConfig reloaded = ConfigStore.Load(Paths);
            DatabaseSchemaDefinition schema = AppConfigDatabaseSchemaMapper.ToDatabaseSchema(reloaded);
            _database.EnsureDynamicSchema(schema);
            Config = reloaded;
            DatabaseSchema = schema;
        }

        /// <summary>
        /// Saves the current in-memory configuration and then applies its
        /// non-destructive schema additions to the open database. A database
        /// failure leaves the saved TOML intact; the next successful open will
        /// retry the additive schema synchronization.
        /// </summary>
        public void SaveConfig()
        {
            ThrowIfDisposed();
            DatabaseSchemaDefinition schema = AppConfigDatabaseSchemaMapper.ToDatabaseSchema(Config);
            ConfigStore.Save(Config, Paths);
            _database.EnsureDynamicSchema(schema);
            DatabaseSchema = schema;
        }

        /// <summary>
        /// Replaces the current configuration as one validated save operation.
        /// The replacement is normalized and mapped before it is persisted, so
        /// an invalid question identifier cannot be written by this API.
        /// </summary>
        /// <param name="replacement">New project configuration to persist.</param>
        public void ReplaceConfig(AppConfig replacement)
        {
            ThrowIfDisposed();
            if (replacement == null)
            {
                throw new ArgumentNullException(nameof(replacement));
            }

            DatabaseSchemaDefinition schema = AppConfigDatabaseSchemaMapper.ToDatabaseSchema(replacement);
            ConfigStore.Save(replacement, Paths);
            _database.EnsureDynamicSchema(schema);
            Config = replacement;
            DatabaseSchema = schema;
        }

        /// <summary>
        /// Releases the session's SQLite connection. It is safe to call more
        /// than once, and is required before moving, backing up by raw file copy,
        /// or reopening the workspace from another process.
        /// </summary>
        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            _database.Dispose();
        }

        private static WorkspaceSession OpenWorkspace(WorkspacePaths paths)
        {
            AppConfig config = ConfigStore.Load(paths);
            DatabaseSchemaDefinition schema = AppConfigDatabaseSchemaMapper.ToDatabaseSchema(config);
            LitNexusDatabase database = LitNexusDatabase.Open(paths.DatabasePath, schema);
            return new WorkspaceSession(paths, config, schema, database);
        }

        private void ThrowIfDisposed()
        {
            if (_disposed)
            {
                throw new ObjectDisposedException(nameof(WorkspaceSession));
            }
        }
    }
}
