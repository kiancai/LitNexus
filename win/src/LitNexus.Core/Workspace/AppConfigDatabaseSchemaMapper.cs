using System;
using System.Collections.Generic;
using LitNexus.Core.Domain;
using LitNexus.Core.Persistence;

namespace LitNexus.Core.Workspace
{
    /// <summary>
    /// Raised when a portable <see cref="AppConfig"/> cannot safely describe the
    /// dynamic SQLite schema required by the current workspace.
    /// </summary>
    public sealed class WorkspaceSchemaException : Exception
    {
        /// <summary>Initializes an exception with a user-facing explanation.</summary>
        public WorkspaceSchemaException(string message)
            : base(message)
        {
        }
    }

    /// <summary>
    /// Keeps the TOML domain model separate from the SQLite persistence model.
    /// Every workspace session goes through this boundary after loading
    /// <c>litnexus.toml</c>, before opening <c>litnexus.db</c>.
    /// </summary>
    public static class AppConfigDatabaseSchemaMapper
    {
        /// <summary>
        /// Projects the current configuration into the non-destructive dynamic
        /// schema contract. Archived and disabled questions are intentionally
        /// included: their historic answer columns and metadata must remain
        /// available even though future pipeline runs skip them.
        /// </summary>
        /// <param name="config">Configuration loaded from one explicit workspace.</param>
        /// <returns>A schema definition suitable for <see cref="LitNexusDatabase.Open"/>.</returns>
        /// <exception cref="ArgumentNullException"><paramref name="config"/> is null.</exception>
        /// <exception cref="WorkspaceSchemaException">
        /// A question id is invalid or is duplicated, so it cannot be mapped to
        /// an unambiguous SQLite column pair.
        /// </exception>
        public static DatabaseSchemaDefinition ToDatabaseSchema(AppConfig config)
        {
            if (config == null)
            {
                throw new ArgumentNullException(nameof(config));
            }

            // ConfigStore already normalizes loaded TOML. Calling it here as
            // well makes this boundary safe for future settings pages that pass
            // an in-memory AppConfig directly.
            config.Normalize();

            var questions = new List<QuestionSchemaDefinition>();
            var seenQuestionIds = new HashSet<string>(StringComparer.Ordinal);
            for (int index = 0; index < config.Classify.Questions.Count; index++)
            {
                Question? question = config.Classify.Questions[index];
                if (question == null)
                {
                    throw new WorkspaceSchemaException(
                        "分类问题列表中第 " + (index + 1) + " 项为空，无法建立数据库结构。");
                }

                if (!SqlIdentifier.IsValid(question.Id))
                {
                    throw new WorkspaceSchemaException(
                        "分类问题「" + (question.DisplayName ?? string.Empty)
                        + "」的稳定 ID「" + (question.Id ?? string.Empty)
                        + "」无效；ID 只能使用字母、数字和下划线，且不能以数字开头。");
                }

                if (!seenQuestionIds.Add(question.Id))
                {
                    throw new WorkspaceSchemaException(
                        "分类问题 ID「" + question.Id + "」重复，无法映射为唯一的数据库列。");
                }

                questions.Add(new QuestionSchemaDefinition(
                    question.Id,
                    question.Nickname,
                    question.Text,
                    question.Archived,
                    question.Classify,
                    question.ClassifyAfterRowId));
            }

            // NormalizeCustomColumns keeps include/tags first and rejects both
            // article fact columns and question-shaped names. Do not read or
            // infer any schema information from a process-wide setting.
            List<string> customColumns = SchemaConfig.NormalizeAnnotationColumns(
                config.Schema.CustomColumns);
            return new DatabaseSchemaDefinition(questions, customColumns);
        }
    }
}
