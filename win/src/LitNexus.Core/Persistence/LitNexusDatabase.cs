using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using Microsoft.Data.Sqlite;

namespace LitNexus.Core.Persistence
{
    /// <summary>
    /// Current portable article fields.  Dynamic question and annotation columns
    /// are added only after the TOML configuration has been loaded.
    /// </summary>
    public sealed class ArticleRecord
    {
        public ArticleRecord(string epmcId)
        {
            if (string.IsNullOrWhiteSpace(epmcId))
            {
                throw new ArgumentException("文章必须有 epmc_id。", nameof(epmcId));
            }

            EpmcId = epmcId;
        }

        public string EpmcId { get; private set; }
        public string? Pmid { get; set; }
        public string? Doi { get; set; }
        public string? Source { get; set; }
        public string? Pmcid { get; set; }
        public string? Title { get; set; }
        public string? Abstract { get; set; }
        public int? PublicationYear { get; set; }
        public string? AuthorString { get; set; }
        public string? JournalTitle { get; set; }
        public string? FirstPublicationDate { get; set; }
        public string? QuerySearchTerm { get; set; }
        public string? JournalInfoJson { get; set; }
        public string? KeywordListJson { get; set; }
        public string? TitleZh { get; set; }
        public string? AbstractZh { get; set; }
    }

    /// <summary>Existing human annotations retrieved by the stable epmc_id key.</summary>
    public sealed class ReviewValues
    {
        public ReviewValues(string? include, string? tags)
        {
            Include = include;
            Tags = tags;
        }

        public string? Include { get; private set; }
        public string? Tags { get; private set; }
    }

    /// <summary>One preflight-approved human annotation change. Null means no write.</summary>
    public sealed class ReviewedCsvUpdate
    {
        public ReviewedCsvUpdate(int line, string epmcId, string? include, string? tags)
        {
            if (line < 1)
            {
                throw new ArgumentOutOfRangeException(nameof(line));
            }

            if (string.IsNullOrWhiteSpace(epmcId))
            {
                throw new ArgumentException("复筛更新必须有 epmc_id。", nameof(epmcId));
            }

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

    public sealed class ReviewWriteOutcome
    {
        public ReviewWriteOutcome(int updatedRows, int updatedFields, int unmatchedRows, int protectedRows)
        {
            UpdatedRows = updatedRows;
            UpdatedFields = updatedFields;
            UnmatchedRows = unmatchedRows;
            ProtectedRows = protectedRows;
        }

        public int UpdatedRows { get; private set; }
        public int UpdatedFields { get; private set; }
        public int UnmatchedRows { get; private set; }
        public int ProtectedRows { get; private set; }
    }

    /// <summary>Runtime verification for SQLite features required by the Mac v2 database contract.</summary>
    public sealed class SqliteFeatureReport
    {
        public SqliteFeatureReport(string version, string journalMode, string backupPath)
        {
            Version = version;
            JournalMode = journalMode;
            BackupPath = backupPath;
        }

        public string Version { get; private set; }
        public string JournalMode { get; private set; }
        public string BackupPath { get; private set; }
    }

    /// <summary>
    /// SQLite v2 workspace store.  Open order is intentionally explicit:
    /// load TOML first, then open this database, then call EnsureDynamicSchema.
    /// PRAGMA user_version alone never says dynamic problem columns are present.
    /// </summary>
    public sealed partial class LitNexusDatabase : IDisposable
    {
        public const int SchemaVersion = 2;

        private readonly SqliteConnection _connection;
        private bool _disposed;

        private LitNexusDatabase(string path, SqliteConnection connection)
        {
            Path = path;
            _connection = connection;
        }

        public string Path { get; private set; }

        public static LitNexusDatabase Open(string databasePath, DatabaseSchemaDefinition schema)
        {
            if (string.IsNullOrWhiteSpace(databasePath))
            {
                throw new ArgumentException("必须提供 litnexus.db 路径。", nameof(databasePath));
            }

            string fullPath = System.IO.Path.GetFullPath(databasePath);
            string? parent = System.IO.Path.GetDirectoryName(fullPath);
            if (string.IsNullOrEmpty(parent))
            {
                throw new DatabaseException("无法确定数据库所在目录：" + fullPath);
            }

            Directory.CreateDirectory(parent);
            var builder = new SqliteConnectionStringBuilder
            {
                DataSource = fullPath,
                Mode = SqliteOpenMode.ReadWriteCreate,
                Cache = SqliteCacheMode.Default,
                // A workspace is represented by one long-lived store object.
                // Avoid keeping a pooled native handle alive after Dispose: it
                // would leave the .db locked for a subsequent backup, move, or
                // clean workspace shutdown on Windows.
                Pooling = false,
            };

            var connection = new SqliteConnection(builder.ToString());
            try
            {
                connection.Open();
                var database = new LitNexusDatabase(fullPath, connection);
                database.ExecuteNonQuery("PRAGMA journal_mode=WAL");
                database.ExecuteNonQuery("PRAGMA foreign_keys=ON");
                database.EnsureCoreSchema();
                database.EnsureDynamicSchema(schema ?? DatabaseSchemaDefinition.Empty);
                return database;
            }
            catch (Exception exception)
            {
                connection.Dispose();
                throw new DatabaseException("无法打开或初始化数据库：" + fullPath, exception);
            }
        }

        public void EnsureDynamicSchema(DatabaseSchemaDefinition schema)
        {
            ThrowIfDisposed();
            if (schema == null)
            {
                throw new ArgumentNullException(nameof(schema));
            }

            EnsureCoreSchema();
            var existing = new HashSet<string>(GetTableColumns("articles"), StringComparer.Ordinal);

            var dynamicColumns = new List<string> { "include", "tags" };
            foreach (QuestionSchemaDefinition question in schema.Questions)
            {
                dynamicColumns.Add(question.Id + "_ans");
                dynamicColumns.Add(question.Id + "_rea");
            }

            foreach (string column in schema.CustomColumns)
            {
                if (SqlIdentifier.IsValid(column) && !dynamicColumns.Contains(column, StringComparer.Ordinal))
                {
                    dynamicColumns.Add(column);
                }
            }

            foreach (string column in dynamicColumns)
            {
                if (!SqlIdentifier.IsValid(column))
                {
                    continue;
                }

                if (existing.Add(column))
                {
                    ExecuteNonQuery("ALTER TABLE articles ADD COLUMN " + SqlIdentifier.Quote(column) + " TEXT");
                }
            }

            ExecuteNonQuery("CREATE INDEX IF NOT EXISTS idx_include ON articles(include)");
            foreach (QuestionSchemaDefinition question in schema.Questions)
            {
                string answerColumn = question.Id + "_ans";
                if (SqlIdentifier.IsValid(answerColumn))
                {
                    ExecuteNonQuery("CREATE INDEX IF NOT EXISTS " + SqlIdentifier.Quote("idx_" + answerColumn)
                        + " ON articles(" + SqlIdentifier.Quote(answerColumn) + ")");
                }
            }

            EnsureQuestionMetadataTable();
            if (schema.SynchronizeQuestionMetadata)
            {
                SynchronizeQuestionMetadata(schema.Questions);
            }

            ExecuteNonQuery(@"CREATE TABLE IF NOT EXISTS article_terms (
                epmc_id TEXT NOT NULL,
                term TEXT NOT NULL,
                kind TEXT NOT NULL,
                PRIMARY KEY (epmc_id, term)
            )");
            ExecuteNonQuery("CREATE INDEX IF NOT EXISTS idx_terms_term ON article_terms(term)");
        }

        public IReadOnlyList<string> GetArticleColumns()
        {
            return GetTableColumns("articles");
        }

        public bool HasArticleColumn(string column)
        {
            return GetArticleColumns().Contains(column, StringComparer.Ordinal);
        }

        public int ArticleCount
        {
            get { return checked((int)ExecuteScalarInt64("SELECT COUNT(*) FROM articles")); }
        }

        public string SqliteVersion
        {
            get { return ExecuteScalarString("SELECT sqlite_version()") ?? string.Empty; }
        }

        public string JournalMode
        {
            get { return ExecuteScalarString("PRAGMA journal_mode") ?? string.Empty; }
        }

        public bool InsertArticle(ArticleRecord record)
        {
            if (record == null)
            {
                throw new ArgumentNullException(nameof(record));
            }

            const string sql = @"INSERT OR IGNORE INTO articles (
                epmc_id, pmid, doi, source, pmcid, title, abstract, pub_year,
                author_string, journal_title, first_publication_date, query_search_term,
                journal_info_json, keyword_list_json, title_zh, abstract_zh
            ) VALUES (
                $epmc_id, $pmid, $doi, $source, $pmcid, $title, $abstract, $pub_year,
                $author_string, $journal_title, $first_publication_date, $query_search_term,
                $journal_info_json, $keyword_list_json, $title_zh, $abstract_zh
            )";

            using (SqliteCommand command = CreateCommand(sql))
            {
                Add(command, "$epmc_id", record.EpmcId);
                Add(command, "$pmid", record.Pmid);
                Add(command, "$doi", record.Doi);
                Add(command, "$source", record.Source);
                Add(command, "$pmcid", record.Pmcid);
                Add(command, "$title", record.Title);
                Add(command, "$abstract", record.Abstract);
                Add(command, "$pub_year", record.PublicationYear);
                Add(command, "$author_string", record.AuthorString);
                Add(command, "$journal_title", record.JournalTitle);
                Add(command, "$first_publication_date", record.FirstPublicationDate);
                Add(command, "$query_search_term", record.QuerySearchTerm);
                Add(command, "$journal_info_json", record.JournalInfoJson);
                Add(command, "$keyword_list_json", record.KeywordListJson);
                Add(command, "$title_zh", record.TitleZh);
                Add(command, "$abstract_zh", record.AbstractZh);
                return command.ExecuteNonQuery() > 0;
            }
        }

        public IDictionary<string, ReviewValues> GetReviewValues(IEnumerable<string> epmcIds)
        {
            if (epmcIds == null)
            {
                throw new ArgumentNullException(nameof(epmcIds));
            }

            var ids = epmcIds.Where(id => !string.IsNullOrWhiteSpace(id))
                .Distinct(StringComparer.Ordinal).ToArray();
            var values = new Dictionary<string, ReviewValues>(StringComparer.Ordinal);
            const int chunkSize = 900;
            for (int start = 0; start < ids.Length; start += chunkSize)
            {
                string[] chunk = ids.Skip(start).Take(chunkSize).ToArray();
                if (chunk.Length == 0)
                {
                    continue;
                }

                using (SqliteCommand command = CreateCommand("SELECT epmc_id, include, tags FROM articles WHERE epmc_id IN ("
                    + string.Join(", ", chunk.Select((_, index) => "$id" + index.ToString(CultureInfo.InvariantCulture))) + ")"))
                {
                    for (int index = 0; index < chunk.Length; index++)
                    {
                        Add(command, "$id" + index.ToString(CultureInfo.InvariantCulture), chunk[index]);
                    }

                    using (SqliteDataReader reader = command.ExecuteReader())
                    {
                        while (reader.Read())
                        {
                            string id = reader.GetString(0);
                            values[id] = new ReviewValues(ReadNullableString(reader, 1), ReadNullableString(reader, 2));
                        }
                    }
                }
            }

            return values;
        }

        public ReviewWriteOutcome ApplyReviewedCsvUpdates(IEnumerable<ReviewedCsvUpdate> updates, bool allowOverwrite)
        {
            if (updates == null)
            {
                throw new ArgumentNullException(nameof(updates));
            }

            ReviewedCsvUpdate[] requested = updates.Where(update => update != null).ToArray();
            if (requested.Length == 0)
            {
                return new ReviewWriteOutcome(0, 0, 0, 0);
            }

            IDictionary<string, ReviewValues> current = GetReviewValues(requested.Select(update => update.EpmcId));
            var updatedIds = new HashSet<string>(StringComparer.Ordinal);
            var protectedIds = new HashSet<string>(StringComparer.Ordinal);
            var unmatchedIds = new HashSet<string>(StringComparer.Ordinal);
            var updatedFields = 0;

            using (SqliteTransaction transaction = _connection.BeginTransaction())
            {
                try
                {
                    foreach (ReviewedCsvUpdate update in requested)
                    {
                        if (!current.ContainsKey(update.EpmcId))
                        {
                            unmatchedIds.Add(update.EpmcId);
                            continue;
                        }

                        if (update.Include != null)
                        {
                            int changed = UpdateReviewValue("include", update.Include, update.EpmcId, allowOverwrite, transaction);
                            if (changed > 0)
                            {
                                updatedIds.Add(update.EpmcId);
                                updatedFields++;
                            }
                            else if (!allowOverwrite)
                            {
                                protectedIds.Add(update.EpmcId);
                            }
                        }

                        if (update.Tags != null)
                        {
                            int changed = UpdateReviewValue("tags", update.Tags, update.EpmcId, allowOverwrite, transaction);
                            if (changed > 0)
                            {
                                updatedIds.Add(update.EpmcId);
                                updatedFields++;
                            }
                            else if (!allowOverwrite)
                            {
                                protectedIds.Add(update.EpmcId);
                            }
                        }
                    }

                    transaction.Commit();
                }
                catch
                {
                    transaction.Rollback();
                    throw;
                }
            }

            return new ReviewWriteOutcome(updatedIds.Count, updatedFields, unmatchedIds.Count, protectedIds.Count);
        }

        public void BackupTo(string backupPath)
        {
            if (string.IsNullOrWhiteSpace(backupPath))
            {
                throw new ArgumentException("必须提供备份路径。", nameof(backupPath));
            }

            string fullPath = System.IO.Path.GetFullPath(backupPath);
            if (File.Exists(fullPath))
            {
                throw new DatabaseException("备份目标已存在，拒绝覆盖：" + fullPath);
            }

            string? parent = System.IO.Path.GetDirectoryName(fullPath);
            if (string.IsNullOrEmpty(parent))
            {
                throw new DatabaseException("无法确定备份目录：" + fullPath);
            }

            Directory.CreateDirectory(parent);
            using (SqliteCommand command = CreateCommand("VACUUM INTO $backup"))
            {
                Add(command, "$backup", fullPath);
                command.ExecuteNonQuery();
            }
        }

        public SqliteFeatureReport ProbeRequiredFeatures(string backupPath)
        {
            const string left = "__litnexus_feature_left";
            const string right = "__litnexus_feature_right";
            ExecuteNonQuery("DROP TABLE IF EXISTS " + SqlIdentifier.Quote(left));
            ExecuteNonQuery("DROP TABLE IF EXISTS " + SqlIdentifier.Quote(right));
            try
            {
                ExecuteNonQuery("CREATE TABLE " + SqlIdentifier.Quote(left) + " (id INTEGER PRIMARY KEY, value TEXT, obsolete TEXT)");
                ExecuteNonQuery("CREATE TABLE " + SqlIdentifier.Quote(right) + " (id INTEGER PRIMARY KEY, value TEXT)");
                ExecuteNonQuery("INSERT INTO " + SqlIdentifier.Quote(left) + " (id, value, obsolete) VALUES (1, 'before', 'remove')");
                ExecuteNonQuery("INSERT INTO " + SqlIdentifier.Quote(right) + " (id, value) VALUES (1, 'after')");
                ExecuteNonQuery("UPDATE " + SqlIdentifier.Quote(left) + " SET value = source.value FROM "
                    + SqlIdentifier.Quote(right) + " AS source WHERE " + SqlIdentifier.Quote(left) + ".id = source.id");
                string? changed = ExecuteScalarString("SELECT value FROM " + SqlIdentifier.Quote(left) + " WHERE id = 1");
                if (!string.Equals(changed, "after", StringComparison.Ordinal))
                {
                    throw new DatabaseException("SQLite UPDATE FROM 未产生预期结果。");
                }

                ExecuteNonQuery("ALTER TABLE " + SqlIdentifier.Quote(left) + " DROP COLUMN obsolete");
                if (GetTableColumns(left).Contains("obsolete", StringComparer.Ordinal))
                {
                    throw new DatabaseException("SQLite DROP COLUMN 未移除测试列。");
                }

                BackupTo(backupPath);
                if (!File.Exists(backupPath))
                {
                    throw new DatabaseException("SQLite VACUUM INTO 未生成备份文件。");
                }

                return new SqliteFeatureReport(SqliteVersion, JournalMode, backupPath);
            }
            finally
            {
                ExecuteNonQuery("DROP TABLE IF EXISTS " + SqlIdentifier.Quote(left));
                ExecuteNonQuery("DROP TABLE IF EXISTS " + SqlIdentifier.Quote(right));
            }
        }

        public string? GetArticleText(string epmcId, string column)
        {
            SqlIdentifier.Require(column, nameof(column));
            using (SqliteCommand command = CreateCommand("SELECT " + SqlIdentifier.Quote(column)
                + " FROM articles WHERE epmc_id = $id"))
            {
                Add(command, "$id", epmcId);
                object? result = command.ExecuteScalar();
                return result == null || result == DBNull.Value ? null : Convert.ToString(result, CultureInfo.InvariantCulture);
            }
        }

        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            _connection.Dispose();
        }

        private void EnsureCoreSchema()
        {
            if (!TableExists("articles"))
            {
                ExecuteNonQuery(@"CREATE TABLE IF NOT EXISTS articles (
                    epmc_id TEXT PRIMARY KEY,
                    pmid TEXT,
                    doi TEXT,
                    source TEXT,
                    pmcid TEXT,
                    title TEXT,
                    abstract TEXT,
                    pub_year INTEGER,
                    author_string TEXT,
                    journal_title TEXT,
                    first_publication_date TEXT,
                    query_search_term TEXT,
                    journal_info_json TEXT,
                    keyword_list_json TEXT,
                    title_zh TEXT,
                    abstract_zh TEXT,
                    CONSTRAINT uq_pmid UNIQUE (pmid),
                    CONSTRAINT uq_doi UNIQUE (doi)
                )");
                ExecuteNonQuery("CREATE INDEX IF NOT EXISTS idx_pub_year ON articles(pub_year)");
                ExecuteNonQuery("CREATE INDEX IF NOT EXISTS idx_journal ON articles(journal_title)");
            }

            if (UserVersion < SchemaVersion)
            {
                ExecuteNonQuery("PRAGMA user_version = " + SchemaVersion.ToString(CultureInfo.InvariantCulture));
            }
        }

        private void EnsureQuestionMetadataTable()
        {
            ExecuteNonQuery(@"CREATE TABLE IF NOT EXISTS litnexus_questions (
                id TEXT PRIMARY KEY,
                nickname TEXT,
                text TEXT,
                archived INTEGER NOT NULL DEFAULT 0,
                classify_enabled INTEGER NOT NULL DEFAULT 1,
                classify_after_rowid INTEGER
            )");
            var existing = new HashSet<string>(GetTableColumns("litnexus_questions"), StringComparer.Ordinal);
            if (!existing.Contains("archived"))
            {
                ExecuteNonQuery("ALTER TABLE litnexus_questions ADD COLUMN archived INTEGER NOT NULL DEFAULT 0");
            }

            if (!existing.Contains("classify_enabled"))
            {
                ExecuteNonQuery("ALTER TABLE litnexus_questions ADD COLUMN classify_enabled INTEGER NOT NULL DEFAULT 1");
            }

            if (!existing.Contains("classify_after_rowid"))
            {
                ExecuteNonQuery("ALTER TABLE litnexus_questions ADD COLUMN classify_after_rowid INTEGER");
            }
        }

        private void SynchronizeQuestionMetadata(IEnumerable<QuestionSchemaDefinition> questions)
        {
            using (SqliteTransaction transaction = _connection.BeginTransaction())
            {
                try
                {
                    using (SqliteCommand delete = CreateCommand("DELETE FROM litnexus_questions", transaction))
                    {
                        delete.ExecuteNonQuery();
                    }

                    foreach (QuestionSchemaDefinition question in questions)
                    {
                        using (SqliteCommand insert = CreateCommand(@"INSERT INTO litnexus_questions
                            (id, nickname, text, archived, classify_enabled, classify_after_rowid)
                            VALUES ($id, $nickname, $text, $archived, $classify_enabled, $classify_after_rowid)", transaction))
                        {
                            Add(insert, "$id", question.Id);
                            Add(insert, "$nickname", question.Nickname);
                            Add(insert, "$text", question.Text);
                            Add(insert, "$archived", question.Archived ? 1 : 0);
                            Add(insert, "$classify_enabled", question.ClassifyEnabled ? 1 : 0);
                            Add(insert, "$classify_after_rowid", question.ClassifyAfterRowId);
                            insert.ExecuteNonQuery();
                        }
                    }

                    transaction.Commit();
                }
                catch
                {
                    transaction.Rollback();
                    throw;
                }
            }
        }

        private long UserVersion
        {
            get { return ExecuteScalarInt64("PRAGMA user_version"); }
        }

        private bool TableExists(string table)
        {
            using (SqliteCommand command = CreateCommand("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = $name"))
            {
                Add(command, "$name", table);
                return Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture) > 0;
            }
        }

        private IReadOnlyList<string> GetTableColumns(string table)
        {
            SqlIdentifier.Require(table, nameof(table));
            var columns = new List<string>();
            using (SqliteCommand command = CreateCommand("PRAGMA table_info(" + SqlIdentifier.Quote(table) + ")"))
            using (SqliteDataReader reader = command.ExecuteReader())
            {
                while (reader.Read())
                {
                    columns.Add(reader.GetString(1));
                }
            }

            return columns;
        }

        private int UpdateReviewValue(string column, string value, string epmcId, bool allowOverwrite, SqliteTransaction transaction)
        {
            string sql = allowOverwrite
                ? "UPDATE articles SET " + SqlIdentifier.Quote(column) + " = $value WHERE epmc_id = $id"
                : "UPDATE articles SET " + SqlIdentifier.Quote(column) + " = $value WHERE epmc_id = $id"
                  + " AND (" + SqlIdentifier.Quote(column) + " IS NULL OR TRIM(" + SqlIdentifier.Quote(column) + ") = '')";
            using (SqliteCommand command = CreateCommand(sql, transaction))
            {
                Add(command, "$value", value);
                Add(command, "$id", epmcId);
                return command.ExecuteNonQuery();
            }
        }

        private int ExecuteNonQuery(string sql)
        {
            ThrowIfDisposed();
            using (SqliteCommand command = CreateCommand(sql))
            {
                return command.ExecuteNonQuery();
            }
        }

        private long ExecuteScalarInt64(string sql)
        {
            ThrowIfDisposed();
            using (SqliteCommand command = CreateCommand(sql))
            {
                object? result = command.ExecuteScalar();
                return result == null || result == DBNull.Value ? 0L : Convert.ToInt64(result, CultureInfo.InvariantCulture);
            }
        }

        private string? ExecuteScalarString(string sql)
        {
            ThrowIfDisposed();
            using (SqliteCommand command = CreateCommand(sql))
            {
                object? result = command.ExecuteScalar();
                return result == null || result == DBNull.Value ? null : Convert.ToString(result, CultureInfo.InvariantCulture);
            }
        }

        private SqliteCommand CreateCommand(string sql, SqliteTransaction? transaction = null)
        {
            var command = _connection.CreateCommand();
            command.CommandText = sql;
            command.Transaction = transaction;
            return command;
        }

        private static void Add(SqliteCommand command, string name, object? value)
        {
            command.Parameters.AddWithValue(name, value ?? DBNull.Value);
        }

        private static string? ReadNullableString(SqliteDataReader reader, int ordinal)
        {
            return reader.IsDBNull(ordinal) ? null : reader.GetString(ordinal);
        }

        private void ThrowIfDisposed()
        {
            if (_disposed)
            {
                throw new ObjectDisposedException(nameof(LitNexusDatabase));
            }
        }
    }
}
