using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using Microsoft.Data.Sqlite;

namespace LitNexus.Core.Persistence
{
    /// <summary>
    /// Stable review states used by the Data page and CSV export.  The SQL
    /// predicates deliberately mirror the Mac client: pending means a literal
    /// <c>NULL</c> <c>include</c> value, while only lowercase <c>yes</c> and
    /// <c>no</c> are treated as final review decisions.
    /// </summary>
    public enum ArticleExportScope
    {
        All,
        Pending,
        Included,
        Excluded,
    }

    /// <summary>
    /// A compact, point-in-time summary of the human-review state in
    /// <c>articles</c>. The four counts are intentionally exposed separately:
    /// malformed legacy <c>include</c> values are not silently folded into one
    /// of the three recognized review states.
    /// </summary>
    public sealed class ArticleStatusSummary
    {
        public ArticleStatusSummary(int total, int pending, int included, int excluded)
        {
            Total = total;
            Pending = pending;
            Included = included;
            Excluded = excluded;
        }

        /// <summary>All rows currently in <c>articles</c>.</summary>
        public int Total { get; private set; }

        /// <summary>Rows whose <c>include</c> is SQL <c>NULL</c>.</summary>
        public int Pending { get; private set; }

        /// <summary>Rows whose <c>include</c> is exactly <c>yes</c>.</summary>
        public int Included { get; private set; }

        /// <summary>Rows whose <c>include</c> is exactly <c>no</c>.</summary>
        public int Excluded { get; private set; }

        /// <summary>Rows with a recognized final human-review decision.</summary>
        public int Reviewed
        {
            get { return checked(Included + Excluded); }
        }
    }

    /// <summary>
    /// Caller-owned choices for a one-way article CSV export. The required
    /// review columns (<c>epmc_id</c>, <c>include</c>, <c>tags</c>) cannot be
    /// excluded or renamed, so the exported file remains suitable for the
    /// cross-platform manual-review import contract.
    /// </summary>
    public sealed class ArticleCsvExportRequest
    {
        private readonly HashSet<string> _excludedColumns;
        private readonly Dictionary<string, string> _headerMap;

        public ArticleCsvExportRequest(
            ArticleExportScope scope,
            string outputPath,
            IEnumerable<string>? excludedColumns = null,
            IReadOnlyDictionary<string, string>? headerMap = null)
        {
            if (!Enum.IsDefined(typeof(ArticleExportScope), scope))
            {
                throw new ArgumentOutOfRangeException(nameof(scope));
            }

            if (string.IsNullOrWhiteSpace(outputPath))
            {
                throw new ArgumentException("必须提供 CSV 导出路径。", nameof(outputPath));
            }

            Scope = scope;
            OutputPath = Path.GetFullPath(outputPath);
            _excludedColumns = new HashSet<string>(StringComparer.Ordinal);
            foreach (string column in excludedColumns ?? Enumerable.Empty<string>())
            {
                if (!string.IsNullOrWhiteSpace(column))
                {
                    _excludedColumns.Add(column);
                }
            }

            _headerMap = new Dictionary<string, string>(StringComparer.Ordinal);
            if (headerMap != null)
            {
                foreach (KeyValuePair<string, string> pair in headerMap)
                {
                    if (!string.IsNullOrWhiteSpace(pair.Key) && !string.IsNullOrWhiteSpace(pair.Value))
                    {
                        _headerMap[pair.Key] = pair.Value;
                    }
                }
            }
        }

        /// <summary>Review state predicate to apply before writing CSV.</summary>
        public ArticleExportScope Scope { get; private set; }

        /// <summary>Absolute destination path selected by the caller.</summary>
        public string OutputPath { get; private set; }

        /// <summary>
        /// Optional internal article columns to hide. Required review columns
        /// stay present even when this collection contains their names.
        /// </summary>
        public IReadOnlyCollection<string> ExcludedColumns
        {
            get { return _excludedColumns; }
        }

        /// <summary>
        /// Human-readable headings for non-required columns, keyed by the
        /// current SQLite column name. Unknown keys are ignored.
        /// </summary>
        public IReadOnlyDictionary<string, string> HeaderMap
        {
            get { return _headerMap; }
        }
    }

    /// <summary>Result of a streaming RFC4180 CSV export.</summary>
    public sealed class ArticleCsvExportResult
    {
        public ArticleCsvExportResult(
            string outputPath,
            ArticleExportScope scope,
            IEnumerable<string> columns,
            int writtenRows,
            bool fileCreated)
        {
            OutputPath = outputPath;
            Scope = scope;
            Columns = (columns ?? Enumerable.Empty<string>()).ToArray();
            WrittenRows = writtenRows;
            FileCreated = fileCreated;
        }

        /// <summary>Requested destination. It is untouched when no rows match.</summary>
        public string OutputPath { get; private set; }

        /// <summary>Scope applied to the database query.</summary>
        public ArticleExportScope Scope { get; private set; }

        /// <summary>Actual SQLite columns written, in database column order.</summary>
        public IReadOnlyList<string> Columns { get; private set; }

        /// <summary>Number of article rows written, excluding the header.</summary>
        public int WrittenRows { get; private set; }

        /// <summary>
        /// False when the selected range is empty. In that case no file is
        /// created, replaced, or deleted at <see cref="OutputPath"/>.
        /// </summary>
        public bool FileCreated { get; private set; }
    }

    /// <summary>
    /// Read-only Data-page operations built on the current SQLite article
    /// schema. This partial keeps SQL ownership in <see cref="LitNexusDatabase"/>
    /// rather than exposing a generic query API to the WPF layer.
    /// </summary>
    public sealed partial class LitNexusDatabase
    {
        private static readonly string[] RequiredReviewExportColumns =
        {
            "epmc_id",
            "include",
            "tags",
        };

        /// <summary>
        /// Counts all, pending, included, and excluded articles in one SQL
        /// snapshot. Pending is strictly <c>include IS NULL</c>, matching the
        /// Mac export and statistics contract.
        /// </summary>
        public ArticleStatusSummary GetArticleStatusSummary()
        {
            ThrowIfDisposed();
            EnsureReviewColumnsExist();
            const string sql = @"SELECT
                COUNT(*),
                COALESCE(SUM(CASE WHEN include IS NULL THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN include = 'yes' THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN include = 'no' THEN 1 ELSE 0 END), 0)
                FROM articles";

            using (SqliteCommand command = CreateCommand(sql))
            using (SqliteDataReader reader = command.ExecuteReader())
            {
                if (!reader.Read())
                {
                    return new ArticleStatusSummary(0, 0, 0, 0);
                }

                return new ArticleStatusSummary(
                    ToCheckedInt(reader.GetValue(0)),
                    ToCheckedInt(reader.GetValue(1)),
                    ToCheckedInt(reader.GetValue(2)),
                    ToCheckedInt(reader.GetValue(3)));
            }
        }

        /// <summary>
        /// Streams the selected current article columns to a UTF-8-with-BOM,
        /// CRLF, RFC4180 CSV. <c>epmc_id</c>, <c>include</c>, and <c>tags</c>
        /// are always present and retain their machine-readable headings; all
        /// other headings may be mapped by the caller. Empty ranges do not
        /// produce or overwrite a file.
        /// </summary>
        /// <param name="request">Scope, destination, optional exclusions, and heading map.</param>
        public ArticleCsvExportResult ExportArticlesCsv(ArticleCsvExportRequest request)
        {
            if (request == null)
            {
                throw new ArgumentNullException(nameof(request));
            }

            ThrowIfDisposed();
            IReadOnlyList<string> sourceColumns = GetArticleColumns();
            EnsureRequiredExportColumnsExist(sourceColumns);
            string[] columns = sourceColumns
                .Where(column => RequiredReviewExportColumns.Contains(column, StringComparer.Ordinal)
                    || !request.ExcludedColumns.Contains(column))
                .ToArray();
            string columnSql = string.Join(", ", columns.Select(SqlIdentifier.Quote));
            string sql = "SELECT " + columnSql + " FROM articles WHERE " + GetExportWhereClause(request.Scope)
                + " ORDER BY pub_year DESC";

            using (SqliteCommand command = CreateCommand(sql))
            using (SqliteDataReader reader = command.ExecuteReader())
            {
                if (!reader.Read())
                {
                    return new ArticleCsvExportResult(request.OutputPath, request.Scope, columns, 0, fileCreated: false);
                }

                string outputDirectory = System.IO.Path.GetDirectoryName(request.OutputPath) ?? string.Empty;
                if (string.IsNullOrEmpty(outputDirectory))
                {
                    throw new DatabaseException("无法确定 CSV 导出目录：" + request.OutputPath);
                }

                Directory.CreateDirectory(outputDirectory);
                string temporaryPath = System.IO.Path.Combine(
                    outputDirectory,
                    "." + System.IO.Path.GetFileName(request.OutputPath) + "." + Guid.NewGuid().ToString("N") + ".tmp");
                var utf8WithBom = new UTF8Encoding(encoderShouldEmitUTF8Identifier: true);
                var headings = columns.Select(column => GetExportHeading(column, request.HeaderMap)).ToArray();
                var values = new string[columns.Length];
                var writtenRows = 0;

                try
                {
                    using (var stream = new FileStream(temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                    using (var writer = new StreamWriter(stream, utf8WithBom))
                    {
                        WriteCsvRecord(writer, headings);
                        do
                        {
                            for (int ordinal = 0; ordinal < columns.Length; ordinal++)
                            {
                                values[ordinal] = ReadCsvValue(reader, ordinal);
                            }

                            WriteCsvRecord(writer, values);
                            writtenRows++;
                        }
                        while (reader.Read());

                        writer.Flush();
                    }

                    PromoteTemporaryFile(temporaryPath, request.OutputPath);
                    return new ArticleCsvExportResult(request.OutputPath, request.Scope, columns, writtenRows, fileCreated: true);
                }
                finally
                {
                    if (File.Exists(temporaryPath))
                    {
                        File.Delete(temporaryPath);
                    }
                }
            }
        }

        private void EnsureReviewColumnsExist()
        {
            EnsureRequiredExportColumnsExist(GetArticleColumns());
        }

        private static void EnsureRequiredExportColumnsExist(IEnumerable<string> columns)
        {
            var available = new HashSet<string>(columns ?? Enumerable.Empty<string>(), StringComparer.Ordinal);
            string[] missing = RequiredReviewExportColumns.Where(column => !available.Contains(column)).ToArray();
            if (missing.Length > 0)
            {
                throw new DatabaseException(
                    "当前数据库缺少人工复筛列 " + string.Join("、", missing)
                    + "，无法统计或导出复筛 CSV。请先以当前项目配置打开并完成数据库架构同步。");
            }
        }

        private static string GetExportWhereClause(ArticleExportScope scope)
        {
            switch (scope)
            {
                case ArticleExportScope.All:
                    return "1=1";
                case ArticleExportScope.Pending:
                    return "include IS NULL";
                case ArticleExportScope.Included:
                    return "include = 'yes'";
                case ArticleExportScope.Excluded:
                    return "include = 'no'";
                default:
                    throw new ArgumentOutOfRangeException(nameof(scope));
            }
        }

        private static string GetExportHeading(string column, IReadOnlyDictionary<string, string> headerMap)
        {
            if (RequiredReviewExportColumns.Contains(column, StringComparer.Ordinal))
            {
                return column;
            }

            string heading;
            return headerMap != null && headerMap.TryGetValue(column, out heading) && !string.IsNullOrWhiteSpace(heading)
                ? heading
                : column;
        }

        private static void WriteCsvRecord(TextWriter writer, IEnumerable<string> fields)
        {
            bool first = true;
            foreach (string value in fields)
            {
                if (!first)
                {
                    writer.Write(',');
                }

                writer.Write(EscapeCsvField(value ?? string.Empty));
                first = false;
            }

            writer.Write("\r\n");
        }

        private static string EscapeCsvField(string value)
        {
            if (value.IndexOfAny(new[] { ',', '"', '\r', '\n' }) >= 0)
            {
                return "\"" + value.Replace("\"", "\"\"") + "\"";
            }

            return value;
        }

        private static string ReadCsvValue(SqliteDataReader reader, int ordinal)
        {
            if (reader.IsDBNull(ordinal))
            {
                return string.Empty;
            }

            object value = reader.GetValue(ordinal);
            return Convert.ToString(value, CultureInfo.InvariantCulture) ?? string.Empty;
        }

        private static int ToCheckedInt(object value)
        {
            return checked(Convert.ToInt32(value, CultureInfo.InvariantCulture));
        }

        private static void PromoteTemporaryFile(string temporaryPath, string outputPath)
        {
            if (File.Exists(outputPath))
            {
                // Temp and target are siblings, so File.Replace preserves the
                // prior export until the replacement has fully landed.
                File.Replace(temporaryPath, outputPath, destinationBackupFileName: null);
            }
            else
            {
                File.Move(temporaryPath, outputPath);
            }
        }
    }
}
