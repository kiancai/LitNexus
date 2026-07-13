using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using LitNexus.Core.Persistence;

namespace LitNexus.Core.ImportExport
{
    /// <summary>Severity reported while checking a human-review CSV before it can write to SQLite.</summary>
    public enum ReviewImportSeverity
    {
        Warning,
        Error,
    }

    /// <summary>
    /// Stable machine-readable categories for the review-import report.  The WPF
    /// client can localize the accompanying message without parsing it.
    /// </summary>
    public enum ReviewImportIssueKind
    {
        MissingRequiredColumn,
        MissingWritableColumns,
        DuplicateHeader,
        MissingEpmcId,
        DuplicateEpmcId,
        InvalidInclude,
        TruncatedRow,
        UnknownEpmcId,
        ProtectedExistingValue,
    }

    public sealed class ReviewImportIssue
    {
        public ReviewImportIssue(ReviewImportSeverity severity, ReviewImportIssueKind kind, int line, string? epmcId, string message)
        {
            Severity = severity;
            Kind = kind;
            Line = line;
            EpmcId = epmcId;
            Message = message ?? string.Empty;
        }

        /// <summary>Header is line 1; file-level errors also use line 1.</summary>
        public int Line { get; private set; }
        public ReviewImportSeverity Severity { get; private set; }
        public ReviewImportIssueKind Kind { get; private set; }
        public string? EpmcId { get; private set; }
        public string Message { get; private set; }
    }

    /// <summary>
    /// Immutable result of inspecting a review CSV.  An empty update field means
    /// "leave this database field alone", never "write NULL".
    /// </summary>
    public sealed class ReviewedCsvImportPlan
    {
        public ReviewedCsvImportPlan(
            string csvPath,
            bool allowOverwrite,
            IEnumerable<string> headers,
            IEnumerable<string> missingExpectedColumns,
            IEnumerable<string> ignoredColumns,
            int totalRows,
            int emptyRows,
            int candidateRows,
            int unchangedRows,
            int unknownRows,
            int conflictedRows,
            IEnumerable<ReviewedCsvUpdate> updates,
            IEnumerable<ReviewImportIssue> issues)
        {
            CsvPath = csvPath;
            AllowOverwrite = allowOverwrite;
            Headers = (headers ?? Enumerable.Empty<string>()).ToArray();
            MissingExpectedColumns = (missingExpectedColumns ?? Enumerable.Empty<string>()).ToArray();
            IgnoredColumns = (ignoredColumns ?? Enumerable.Empty<string>()).ToArray();
            TotalRows = totalRows;
            EmptyRows = emptyRows;
            CandidateRows = candidateRows;
            UnchangedRows = unchangedRows;
            UnknownRows = unknownRows;
            ConflictedRows = conflictedRows;
            Updates = (updates ?? Enumerable.Empty<ReviewedCsvUpdate>()).ToArray();
            Issues = (issues ?? Enumerable.Empty<ReviewImportIssue>()).ToArray();
        }

        public string CsvPath { get; private set; }
        public bool AllowOverwrite { get; private set; }
        public IReadOnlyList<string> Headers { get; private set; }
        public IReadOnlyList<string> MissingExpectedColumns { get; private set; }
        public IReadOnlyList<string> IgnoredColumns { get; private set; }
        public int TotalRows { get; private set; }
        public int EmptyRows { get; private set; }
        public int CandidateRows { get; private set; }
        public int UnchangedRows { get; private set; }
        public int UnknownRows { get; private set; }
        public int ConflictedRows { get; private set; }
        public IReadOnlyList<ReviewedCsvUpdate> Updates { get; private set; }
        public IReadOnlyList<ReviewImportIssue> Issues { get; private set; }

        public int ErrorCount
        {
            get { return Issues.Count(issue => issue.Severity == ReviewImportSeverity.Error); }
        }

        public int WarningCount
        {
            get { return Issues.Count(issue => issue.Severity == ReviewImportSeverity.Warning); }
        }

        public bool CanApply
        {
            get { return ErrorCount == 0; }
        }

        public bool HasChanges
        {
            get { return Updates.Count > 0; }
        }

        public int PlannedIncludeUpdates
        {
            get { return Updates.Count(update => update.Include != null); }
        }

        public int PlannedTagUpdates
        {
            get { return Updates.Count(update => update.Tags != null); }
        }
    }

    public sealed class ReviewedCsvImportResult
    {
        public ReviewedCsvImportResult(ReviewedCsvImportPlan plan, ReviewWriteOutcome outcome)
        {
            Plan = plan ?? throw new ArgumentNullException(nameof(plan));
            Outcome = outcome ?? throw new ArgumentNullException(nameof(outcome));
        }

        public ReviewedCsvImportPlan Plan { get; private set; }
        public ReviewWriteOutcome Outcome { get; private set; }
        public int UpdatedRows { get { return Outcome.UpdatedRows; } }
        public int UpdatedFields { get { return Outcome.UpdatedFields; } }
        public int UnmatchedAtWrite { get { return Outcome.UnmatchedRows; } }
        public int ProtectedAtWrite { get { return Outcome.ProtectedRows; } }
    }

    /// <summary>Thrown only by Execute when a fresh preflight contains an error.</summary>
    public sealed class ReviewedCsvImportException : Exception
    {
        public ReviewedCsvImportException(ReviewedCsvImportPlan plan)
            : base("复筛 CSV 预检发现 " + (plan == null ? 0 : plan.ErrorCount) + " 个错误；请修正后再导入。")
        {
            Plan = plan ?? throw new ArgumentNullException(nameof(plan));
        }

        public ReviewedCsvImportPlan Plan { get; private set; }
    }

    /// <summary>
    /// Cross-platform CSV contract for manual review import.  It intentionally
    /// uses only stable <c>epmc_id</c> matching and only writes <c>include</c>
    /// and <c>tags</c>; all other exported fields are read-only context.
    /// </summary>
    public static class ReviewedCsvImporter
    {
        private static readonly string[] ExpectedColumns = { "epmc_id", "include", "tags" };

        /// <summary>
        /// Read and validate a CSV without changing the database.  It is safe to
        /// call this on selection, then call <see cref="Execute"/> only after the
        /// user reviews the returned report.
        /// </summary>
        public static ReviewedCsvImportPlan Preflight(LitNexusDatabase database, string csvPath, bool allowOverwrite = false)
        {
            if (database == null)
            {
                throw new ArgumentNullException(nameof(database));
            }

            if (string.IsNullOrWhiteSpace(csvPath))
            {
                throw new ArgumentException("必须提供复筛 CSV 路径。", nameof(csvPath));
            }

            string fullPath = Path.GetFullPath(csvPath);
            string text = File.ReadAllText(fullPath, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true));
            if (text.Length > 0 && text[0] == '\uFEFF')
            {
                text = text.Substring(1);
            }

            IReadOnlyList<IReadOnlyList<string>> parsed = ParseCsv(text);
            if (parsed.Count == 0)
            {
                var emptyIssue = new ReviewImportIssue(
                    ReviewImportSeverity.Error,
                    ReviewImportIssueKind.MissingRequiredColumn,
                    1,
                    null,
                    "CSV 为空，缺少表头与 epmc_id 列。");
                return new ReviewedCsvImportPlan(
                    fullPath,
                    allowOverwrite,
                    Enumerable.Empty<string>(),
                    ExpectedColumns,
                    Enumerable.Empty<string>(),
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    Enumerable.Empty<ReviewedCsvUpdate>(),
                    new[] { emptyIssue });
            }

            IReadOnlyList<string> rawHeader = parsed[0];
            var normalizedHeaders = rawHeader.Select(NormalizeHeader).ToArray();
            var positions = new Dictionary<string, int>(StringComparer.Ordinal);
            var issues = new List<ReviewImportIssue>();
            for (int index = 0; index < normalizedHeaders.Length; index++)
            {
                string name = normalizedHeaders[index];
                if (name.Length == 0)
                {
                    continue;
                }

                if (positions.ContainsKey(name))
                {
                    issues.Add(new ReviewImportIssue(
                        ReviewImportSeverity.Error,
                        ReviewImportIssueKind.DuplicateHeader,
                        1,
                        null,
                        "CSV 表头「" + rawHeader[index] + "」重复；请只保留一列。"));
                }
                else
                {
                    positions.Add(name, index);
                }
            }

            string[] missing = ExpectedColumns.Where(name => !positions.ContainsKey(name)).ToArray();
            if (missing.Contains("epmc_id", StringComparer.Ordinal))
            {
                issues.Add(new ReviewImportIssue(
                    ReviewImportSeverity.Error,
                    ReviewImportIssueKind.MissingRequiredColumn,
                    1,
                    null,
                    "CSV 缺少必需列 epmc_id，无法精确匹配文章。"));
            }

            if (!positions.ContainsKey("include") && !positions.ContainsKey("tags"))
            {
                issues.Add(new ReviewImportIssue(
                    ReviewImportSeverity.Error,
                    ReviewImportIssueKind.MissingWritableColumns,
                    1,
                    null,
                    "CSV 至少需要 include 或 tags 其中一列，才有可导入的复筛标注。"));
            }

            string[] ignoredColumns = rawHeader.Where((value, index) =>
                normalizedHeaders[index].Length > 0 && !ExpectedColumns.Contains(normalizedHeaders[index], StringComparer.Ordinal)).ToArray();

            var candidates = new List<Candidate>();
            var seenIds = new Dictionary<string, int>(StringComparer.Ordinal);
            int emptyRows = 0;
            int candidateRows = 0;
            int unchangedRows = 0;

            for (int offset = 1; offset < parsed.Count; offset++)
            {
                IReadOnlyList<string> fields = parsed[offset];
                int line = offset + 1;
                if (fields.All(value => string.IsNullOrWhiteSpace(value)))
                {
                    emptyRows++;
                    continue;
                }

                CsvCell idCell = GetCell(fields, positions, "epmc_id");
                CsvCell includeCell = GetCell(fields, positions, "include");
                CsvCell tagsCell = GetCell(fields, positions, "tags");
                if (idCell.Truncated || includeCell.Truncated || tagsCell.Truncated)
                {
                    issues.Add(new ReviewImportIssue(
                        ReviewImportSeverity.Warning,
                        ReviewImportIssueKind.TruncatedRow,
                        line,
                        null,
                        "这一行比表头短，缺失的字段会按空白处理，不会写回数据库。"));
                }

                string? requestedInclude = NonBlank(includeCell.Value);
                string? requestedTags = NonBlank(tagsCell.Value);
                string? epmcId = NonBlank(idCell.Value);

                // Extra reading-only rows are deliberately tolerated.  They only
                // become an error when they actually request a database write.
                if (epmcId == null)
                {
                    if (requestedInclude == null && requestedTags == null)
                    {
                        unchangedRows++;
                        continue;
                    }

                    issues.Add(new ReviewImportIssue(
                        ReviewImportSeverity.Error,
                        ReviewImportIssueKind.MissingEpmcId,
                        line,
                        null,
                        "该行缺少 epmc_id，无法安全匹配文章。"));
                    continue;
                }

                string? canonicalInclude = CanonicalInclude(includeCell.Value);
                if (requestedInclude != null && canonicalInclude == null)
                {
                    issues.Add(new ReviewImportIssue(
                        ReviewImportSeverity.Error,
                        ReviewImportIssueKind.InvalidInclude,
                        line,
                        epmcId,
                        "include 只能填写 yes 或 no（忽略大小写与首尾空格）；当前值为「" + requestedInclude + "」。"));
                    continue;
                }

                if (canonicalInclude == null && requestedTags == null)
                {
                    unchangedRows++;
                    continue;
                }

                int earlierLine;
                if (seenIds.TryGetValue(epmcId, out earlierLine))
                {
                    issues.Add(new ReviewImportIssue(
                        ReviewImportSeverity.Error,
                        ReviewImportIssueKind.DuplicateEpmcId,
                        line,
                        epmcId,
                        "epmc_id「" + epmcId + "」与第 " + earlierLine + " 行重复；请每篇文章只保留一行。"));
                    continue;
                }

                seenIds.Add(epmcId, line);
                candidateRows++;
                candidates.Add(new Candidate(line, epmcId, canonicalInclude, requestedTags));
            }

            IDictionary<string, ReviewValues> storedValues = database.GetReviewValues(candidates.Select(candidate => candidate.EpmcId));
            var updates = new List<ReviewedCsvUpdate>();
            int unknownRows = 0;
            int conflictedRows = 0;

            foreach (Candidate candidate in candidates)
            {
                ReviewValues stored;
                if (!storedValues.TryGetValue(candidate.EpmcId, out stored))
                {
                    unknownRows++;
                    issues.Add(new ReviewImportIssue(
                        ReviewImportSeverity.Warning,
                        ReviewImportIssueKind.UnknownEpmcId,
                        candidate.Line,
                        candidate.EpmcId,
                        "epmc_id「" + candidate.EpmcId + "」不在当前项目数据库中，已跳过。"));
                    continue;
                }

                string? includeToWrite = null;
                string? tagsToWrite = null;
                bool rowConflicted = false;

                if (candidate.Include != null)
                {
                    string? existing = NonBlank(stored.Include);
                    if (existing == null || EquivalentInclude(candidate.Include, existing))
                    {
                        if (existing == null)
                        {
                            includeToWrite = candidate.Include;
                        }
                    }
                    else if (allowOverwrite)
                    {
                        includeToWrite = candidate.Include;
                    }
                    else
                    {
                        rowConflicted = true;
                        issues.Add(new ReviewImportIssue(
                            ReviewImportSeverity.Warning,
                            ReviewImportIssueKind.ProtectedExistingValue,
                            candidate.Line,
                            candidate.EpmcId,
                            "epmc_id「" + candidate.EpmcId + "」已有 include 标注，默认不会覆盖。"));
                    }
                }

                if (candidate.Tags != null)
                {
                    string? existing = NonBlank(stored.Tags);
                    if (existing == null || string.Equals(existing, candidate.Tags, StringComparison.Ordinal))
                    {
                        if (existing == null)
                        {
                            tagsToWrite = candidate.Tags;
                        }
                    }
                    else if (allowOverwrite)
                    {
                        tagsToWrite = candidate.Tags;
                    }
                    else
                    {
                        rowConflicted = true;
                        issues.Add(new ReviewImportIssue(
                            ReviewImportSeverity.Warning,
                            ReviewImportIssueKind.ProtectedExistingValue,
                            candidate.Line,
                            candidate.EpmcId,
                            "epmc_id「" + candidate.EpmcId + "」已有 tags 标注，默认不会覆盖。"));
                    }
                }

                if (rowConflicted)
                {
                    conflictedRows++;
                }

                if (includeToWrite != null || tagsToWrite != null)
                {
                    updates.Add(new ReviewedCsvUpdate(candidate.Line, candidate.EpmcId, includeToWrite, tagsToWrite));
                }
                else if (!rowConflicted)
                {
                    unchangedRows++;
                }
            }

            return new ReviewedCsvImportPlan(
                fullPath,
                allowOverwrite,
                rawHeader,
                missing,
                ignoredColumns,
                Math.Max(0, parsed.Count - 1),
                emptyRows,
                candidateRows,
                unchangedRows,
                unknownRows,
                conflictedRows,
                updates,
                issues);
        }

        /// <summary>
        /// Run a new preflight immediately before the transaction.  This avoids
        /// blindly trusting a report that has become stale after the user edited
        /// the CSV or another process changed the workspace.
        /// </summary>
        public static ReviewedCsvImportResult Execute(LitNexusDatabase database, string csvPath, bool allowOverwrite = false)
        {
            ReviewedCsvImportPlan plan = Preflight(database, csvPath, allowOverwrite);
            if (!plan.CanApply)
            {
                throw new ReviewedCsvImportException(plan);
            }

            ReviewWriteOutcome outcome = plan.HasChanges
                ? database.ApplyReviewedCsvUpdates(plan.Updates, allowOverwrite)
                : new ReviewWriteOutcome(0, 0, 0, 0);
            return new ReviewedCsvImportResult(plan, outcome);
        }

        /// <summary>
        /// Portable, deliberately forgiving RFC4180-style parser.  Its behavior
        /// mirrors the Mac client: a quote only starts quoting at a field start;
        /// a stray quote otherwise remains literal so malformed input cannot eat
        /// a later row's annotations.
        /// </summary>
        public static IReadOnlyList<IReadOnlyList<string>> ParseCsv(string text)
        {
            if (text == null)
            {
                throw new ArgumentNullException(nameof(text));
            }

            var rows = new List<IReadOnlyList<string>>();
            var field = new StringBuilder();
            var row = new List<string>();
            bool inQuotes = false;
            bool fieldStart = true;
            int index = 0;
            while (index < text.Length)
            {
                char current = text[index];
                if (inQuotes)
                {
                    if (current == '"')
                    {
                        char? next = index + 1 < text.Length ? (char?)text[index + 1] : null;
                        if (next == '"')
                        {
                            field.Append('"');
                            index++;
                        }
                        else if (next == null || next == ',' || next == '\n' || next == '\r')
                        {
                            inQuotes = false;
                        }
                        else
                        {
                            field.Append('"');
                        }
                    }
                    else
                    {
                        field.Append(current);
                    }
                }
                else
                {
                    switch (current)
                    {
                        case '"':
                            if (fieldStart)
                            {
                                inQuotes = true;
                                fieldStart = false;
                            }
                            else
                            {
                                field.Append('"');
                            }

                            break;
                        case ',':
                            row.Add(field.ToString());
                            field.Clear();
                            fieldStart = true;
                            break;
                        case '\n':
                            row.Add(field.ToString());
                            field.Clear();
                            rows.Add(row.ToArray());
                            row = new List<string>();
                            fieldStart = true;
                            break;
                        case '\r':
                            // A following \n will close the row.  Standalone CR is
                            // intentionally ignored to match the Mac parser.
                            break;
                        default:
                            field.Append(current);
                            fieldStart = false;
                            break;
                    }
                }

                index++;
            }

            if (field.Length > 0 || row.Count > 0)
            {
                row.Add(field.ToString());
                rows.Add(row.ToArray());
            }

            return rows;
        }

        private static CsvCell GetCell(IReadOnlyList<string> fields, IDictionary<string, int> positions, string name)
        {
            int index;
            if (!positions.TryGetValue(name, out index))
            {
                return new CsvCell(null, false);
            }

            return index < fields.Count ? new CsvCell(fields[index], false) : new CsvCell(null, true);
        }

        private static string NormalizeHeader(string value)
        {
            return (value ?? string.Empty).Trim().ToLowerInvariant();
        }

        private static string? NonBlank(string? value)
        {
            if (value == null)
            {
                return null;
            }

            string trimmed = value.Trim();
            return trimmed.Length == 0 ? null : trimmed;
        }

        private static string? CanonicalInclude(string? value)
        {
            string? nonBlank = NonBlank(value);
            if (nonBlank == null)
            {
                return null;
            }

            if (string.Equals(nonBlank, "yes", StringComparison.OrdinalIgnoreCase))
            {
                return "yes";
            }

            if (string.Equals(nonBlank, "no", StringComparison.OrdinalIgnoreCase))
            {
                return "no";
            }

            return null;
        }

        private static bool EquivalentInclude(string imported, string stored)
        {
            string? canonicalStored = CanonicalInclude(stored);
            return canonicalStored != null && string.Equals(imported, canonicalStored, StringComparison.Ordinal);
        }

        private sealed class Candidate
        {
            public Candidate(int line, string epmcId, string? include, string? tags)
            {
                Line = line;
                EpmcId = epmcId;
                Include = include;
                Tags = tags;
            }

            public int Line { get; private set; }
            public string EpmcId { get; private set; }
            public string? Include { get; private set; }
            public string? Tags { get; private set; }
        }

        private sealed class CsvCell
        {
            public CsvCell(string? value, bool truncated)
            {
                Value = value;
                Truncated = truncated;
            }

            public string? Value { get; private set; }
            public bool Truncated { get; private set; }
        }
    }
}
