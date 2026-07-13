using System;
using System.Collections.Generic;
using System.Linq;

namespace LitNexus.Core.Persistence
{
    /// <summary>
    /// A serializable-in-spirit projection of one current AI question.  The
    /// database intentionally does not own TOML configuration types: callers
    /// map their current AppConfig into this small contract at the boundary.
    /// </summary>
    public sealed class QuestionSchemaDefinition
    {
        public QuestionSchemaDefinition(
            string id,
            string nickname,
            string text,
            bool archived = false,
            bool classifyEnabled = true,
            long? classifyAfterRowId = null)
        {
            SqlIdentifier.Require(id, nameof(id));
            Id = id;
            Nickname = nickname ?? string.Empty;
            Text = text ?? string.Empty;
            Archived = archived;
            ClassifyEnabled = classifyEnabled;
            ClassifyAfterRowId = classifyAfterRowId;
        }

        public string Id { get; private set; }
        public string Nickname { get; private set; }
        public string Text { get; private set; }
        public bool Archived { get; private set; }
        public bool ClassifyEnabled { get; private set; }
        public long? ClassifyAfterRowId { get; private set; }
    }

    /// <summary>
    /// Columns that are configuration-driven in the current v2 transition
    /// schema.  <see cref="SynchronizeQuestionMetadata"/> is deliberately
    /// false for an empty/default open: opening an existing database must never
    /// erase its self-describing question metadata merely because TOML was not
    /// loaded yet.
    /// </summary>
    public sealed class DatabaseSchemaDefinition
    {
        public DatabaseSchemaDefinition(
            IEnumerable<QuestionSchemaDefinition> questions,
            IEnumerable<string> customColumns,
            bool synchronizeQuestionMetadata = true)
        {
            Questions = (questions ?? Enumerable.Empty<QuestionSchemaDefinition>()).ToArray();
            CustomColumns = (customColumns ?? Enumerable.Empty<string>()).ToArray();
            SynchronizeQuestionMetadata = synchronizeQuestionMetadata;
        }

        public IReadOnlyList<QuestionSchemaDefinition> Questions { get; private set; }
        public IReadOnlyList<string> CustomColumns { get; private set; }
        public bool SynchronizeQuestionMetadata { get; private set; }

        public static DatabaseSchemaDefinition Empty
        {
            get
            {
                return new DatabaseSchemaDefinition(
                    Enumerable.Empty<QuestionSchemaDefinition>(),
                    Enumerable.Empty<string>(),
                    synchronizeQuestionMetadata: false);
            }
        }
    }
}
