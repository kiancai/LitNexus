using System;
using LitNexus.Core.Workspace;

namespace LitNexus.Core.ImportExport
{
    /// <summary>
    /// Result of the explicit second phase of manual-review import. The backup
    /// is null only when the newly checked CSV had no actual writes to make.
    /// </summary>
    public sealed class ConfirmedReviewedCsvImportResult
    {
        public ConfirmedReviewedCsvImportResult(
            ReviewedCsvImportResult importResult,
            WorkspaceDatabaseBackupResult? automaticBackup)
        {
            ImportResult = importResult ?? throw new ArgumentNullException(nameof(importResult));
            AutomaticBackup = automaticBackup;
        }

        /// <summary>Fresh import report produced immediately before the write.</summary>
        public ReviewedCsvImportResult ImportResult { get; private set; }

        /// <summary>
        /// Latest-only <c>litnexus.db.bak</c> snapshot taken before a non-empty
        /// import transaction, or null for a no-op confirmation.
        /// </summary>
        public WorkspaceDatabaseBackupResult? AutomaticBackup { get; private set; }
    }

    /// <summary>
    /// Enforces the two-step manual-review workflow at the Core boundary:
    /// choose/preflight first; then, after a UI confirmation, re-preflight,
    /// create an SQLite-consistent automatic backup only when required, and
    /// execute the transaction. Presentation code should not hand-roll this
    /// sequence because it is easy to accidentally write before validation or
    /// forget that a live WAL database cannot be safely file-copied.
    /// </summary>
    public static class ReviewedCsvImportCoordinator
    {
        /// <summary>Performs the non-mutating first phase shown to the user.</summary>
        public static ReviewedCsvImportPlan Prepare(
            WorkspaceSession session,
            string csvPath,
            bool allowOverwrite = false)
        {
            if (session == null)
            {
                throw new ArgumentNullException(nameof(session));
            }

            if (session.IsDisposed)
            {
                throw new ObjectDisposedException(nameof(session));
            }

            return ReviewedCsvImporter.Preflight(session.Database, csvPath, allowOverwrite);
        }

        /// <summary>
        /// Performs the explicit confirmed phase. It never trusts a previously
        /// displayed plan: the CSV is checked once before the backup decision
        /// and once more by <see cref="ReviewedCsvImporter.Execute"/> before
        /// the write. Errors leave both database and backup untouched.
        /// </summary>
        public static ConfirmedReviewedCsvImportResult Confirm(
            WorkspaceSession session,
            string csvPath,
            bool allowOverwrite = false)
        {
            if (session == null)
            {
                throw new ArgumentNullException(nameof(session));
            }

            if (session.IsDisposed)
            {
                throw new ObjectDisposedException(nameof(session));
            }

            ReviewedCsvImportPlan plan = ReviewedCsvImporter.Preflight(
                session.Database,
                csvPath,
                allowOverwrite);
            if (!plan.CanApply)
            {
                throw new ReviewedCsvImportException(plan);
            }

            WorkspaceDatabaseBackupResult? backup = null;
            if (plan.HasChanges)
            {
                backup = WorkspaceDatabaseBackupService.CreateAutomaticBackup(session.Paths, session.Database);
            }

            ReviewedCsvImportResult result = ReviewedCsvImporter.Execute(
                session.Database,
                csvPath,
                allowOverwrite);
            return new ConfirmedReviewedCsvImportResult(result, backup);
        }
    }
}
