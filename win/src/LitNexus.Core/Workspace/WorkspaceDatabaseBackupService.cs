using System;
using System.IO;
using LitNexus.Core.Persistence;

namespace LitNexus.Core.Workspace
{
    /// <summary>
    /// Result of the automatic, latest-only database snapshot taken before a
    /// write operation such as confirmed manual-review CSV import.
    /// </summary>
    public sealed class WorkspaceDatabaseBackupResult
    {
        public WorkspaceDatabaseBackupResult(string backupPath, DateTime createdAtUtc)
        {
            BackupPath = backupPath;
            CreatedAtUtc = createdAtUtc;
        }

        /// <summary>
        /// Absolute path of the standalone SQLite snapshot. It is always the
        /// portable workspace-root file <c>litnexus.db.bak</c>.
        /// </summary>
        public string BackupPath { get; private set; }

        /// <summary>UTC timestamp after the snapshot was safely promoted.</summary>
        public DateTime CreatedAtUtc { get; private set; }
    }

    /// <summary>
    /// Creates the automatic latest-only SQLite snapshot used before a
    /// destructive or review-writing operation. This deliberately does not
    /// copy the main database file: a live LitNexus database uses WAL, so the
    /// snapshot is produced through <see cref="LitNexusDatabase.BackupTo"/>
    /// (<c>VACUUM INTO</c>) and can be opened independently.
    ///
    /// User-requested database exports belong to a future, distinct operation.
    /// They may use <c>exports/</c> and unique names. The automatic safety
    /// snapshot instead replaces only <c>litnexus.db.bak</c> at the workspace
    /// root, preserving the conventional cross-platform recovery location.
    /// </summary>
    public static class WorkspaceDatabaseBackupService
    {
        /// <summary>
        /// Safely replaces the workspace's latest automatic backup with a
        /// current SQLite snapshot. The previous backup remains intact until
        /// <c>VACUUM INTO</c> has succeeded into a unique sibling temporary
        /// file, then the new snapshot is atomically promoted on Windows.
        /// </summary>
        public static WorkspaceDatabaseBackupResult CreateAutomaticBackup(
            WorkspacePaths workspace,
            LitNexusDatabase database)
        {
            if (workspace == null)
            {
                throw new ArgumentNullException(nameof(workspace));
            }

            if (database == null)
            {
                throw new ArgumentNullException(nameof(database));
            }

            string root = Path.GetFullPath(workspace.RootDirectory);
            Directory.CreateDirectory(root);
            string backupPath = Path.Combine(root, "litnexus.db.bak");
            string temporaryPath = Path.Combine(
                root,
                ".litnexus.db.bak." + Guid.NewGuid().ToString("N") + ".tmp");

            try
            {
                database.BackupTo(temporaryPath);
                PromoteTemporaryBackup(temporaryPath, backupPath);
                return new WorkspaceDatabaseBackupResult(backupPath, DateTime.UtcNow);
            }
            finally
            {
                if (File.Exists(temporaryPath))
                {
                    File.Delete(temporaryPath);
                }
            }
        }

        private static void PromoteTemporaryBackup(string temporaryPath, string backupPath)
        {
            if (File.Exists(backupPath))
            {
                File.Replace(temporaryPath, backupPath, destinationBackupFileName: null);
            }
            else
            {
                File.Move(temporaryPath, backupPath);
            }
        }
    }
}
