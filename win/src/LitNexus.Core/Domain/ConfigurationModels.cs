using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace LitNexus.Core.Domain
{
    /// <summary>
    /// The complete, portable configuration stored in a workspace's litnexus.toml.
    /// Device-local choices (for example light/dark/system appearance) deliberately
    /// do not belong here.
    /// </summary>
    public sealed class AppConfig
    {
        [JsonPropertyName("download")]
        public DownloadConfig Download { get; set; } = new DownloadConfig();

        [JsonPropertyName("ai")]
        public AIConfig AI { get; set; } = new AIConfig();

        [JsonPropertyName("translate")]
        public TranslateConfig Translate { get; set; } = new TranslateConfig();

        [JsonPropertyName("classify")]
        public ClassifyConfig Classify { get; set; } = new ClassifyConfig();

        [JsonPropertyName("schema")]
        public SchemaConfig Schema { get; set; } = new SchemaConfig();

        [JsonPropertyName("export")]
        public ExportConfig Export { get; set; } = new ExportConfig();

        [JsonPropertyName("theme")]
        public ThemeConfig Theme { get; set; } = new ThemeConfig();

        /// <summary>
        /// Convenience aliases for application and self-test code. They are not
        /// TOML members: the on-disk shape remains [ai].profiles / [ai].active.
        /// </summary>
        [JsonIgnore]
        public IList<AIProfile> AiProfiles
        {
            get { return AI.Profiles; }
            set { AI.Profiles = value == null ? new List<AIProfile>() : new List<AIProfile>(value); }
        }

        [JsonIgnore]
        public string ActiveAiId
        {
            get { return AI.Active; }
            set { AI.Active = value ?? string.Empty; }
        }

        [JsonIgnore]
        public AIProfile? ActiveProfile
        {
            get
            {
                AIProfile? selected = AI.Profiles.FirstOrDefault(
                    profile => string.Equals(profile.Id, AI.Active, StringComparison.Ordinal));
                return selected ?? AI.Profiles.FirstOrDefault();
            }
        }

        public static AppConfig CreateDefault()
        {
            return new AppConfig();
        }

        /// <summary>
        /// Makes a hand-edited or legacy TOML safe to use while preserving its
        /// intent. This deliberately does not erase unknown historic data from
        /// the database; it only normalizes project configuration values.
        /// </summary>
        public void Normalize()
        {
            Download = Download ?? new DownloadConfig();
            AI = AI ?? new AIConfig();
            Translate = Translate ?? new TranslateConfig();
            Classify = Classify ?? new ClassifyConfig();
            Schema = Schema ?? new SchemaConfig();
            Export = Export ?? new ExportConfig();
            Theme = Theme ?? new ThemeConfig();

            Download.Journals = Download.Journals ?? new List<string>();
            Download.Keywords = Download.Keywords ?? new List<string>();
            AI.Profiles = AI.Profiles ?? new List<AIProfile>();
            Classify.Questions = Classify.Questions ?? new List<Question>();
            Export.ExcludeColumns = Export.ExcludeColumns ?? new List<string>();

            foreach (AIProfile profile in AI.Profiles)
            {
                profile.Normalize();
            }

            foreach (Question question in Classify.Questions)
            {
                question.Normalize();
            }

            if (string.IsNullOrWhiteSpace(AI.Active) && AI.Profiles.Count > 0)
            {
                AI.Active = AI.Profiles[0].Id;
            }

            Classify.NormalizeQuestionIdAllocator();
            Schema.NormalizeCustomColumns();
            Theme.Normalize();
        }
    }

    public sealed class DownloadConfig
    {
        [JsonPropertyName("days")]
        public int Days { get; set; } = 30;

        [JsonPropertyName("page_size")]
        public int PageSize { get; set; } = 1000;

        [JsonPropertyName("request_delay")]
        public double RequestDelay { get; set; } = 0.5d;

        /// <summary>One journal name or a comment/blank line per element.</summary>
        [JsonPropertyName("journals")]
        public List<string> Journals { get; set; } = ConfigDefaults.CreateJournalLines();

        /// <summary>One Europe PMC expression or a comment/blank line per element.</summary>
        [JsonPropertyName("keywords")]
        public List<string> Keywords { get; set; } = ConfigDefaults.CreateKeywordLines();
    }

    /// <summary>
    /// Named AI connection profiles. No profile is bundled with the application;
    /// users choose and persist their own endpoint/model combination.
    /// </summary>
    public sealed class AIConfig
    {
        [JsonPropertyName("active")]
        public string Active { get; set; } = string.Empty;

        [JsonPropertyName("profiles")]
        public List<AIProfile> Profiles { get; set; } = new List<AIProfile>();
    }

    public sealed class AIProfile
    {
        [JsonPropertyName("id")]
        public string Id { get; set; } = Guid.NewGuid().ToString("D");

        [JsonPropertyName("name")]
        public string Name { get; set; } = "新方案";

        [JsonPropertyName("base_url")]
        public string BaseUrl { get; set; } = string.Empty;

        [JsonPropertyName("model")]
        public string Model { get; set; } = string.Empty;

        [JsonPropertyName("api_key")]
        public string ApiKey { get; set; } = string.Empty;

        [JsonPropertyName("extra_params")]
        public string ExtraParams { get; set; } = string.Empty;

        [JsonIgnore]
        public bool IsComplete
        {
            get
            {
                return !string.IsNullOrWhiteSpace(BaseUrl)
                    && !string.IsNullOrWhiteSpace(Model);
            }
        }

        public void Normalize()
        {
            Id = string.IsNullOrWhiteSpace(Id) ? Guid.NewGuid().ToString("D") : Id;
            Name = Name ?? string.Empty;
            BaseUrl = BaseUrl ?? string.Empty;
            Model = Model ?? string.Empty;
            ApiKey = ApiKey ?? string.Empty;
            ExtraParams = ExtraParams ?? string.Empty;
        }
    }

    public sealed class TranslateConfig
    {
        [JsonPropertyName("batch_size")]
        public int BatchSize { get; set; } = 30;

        [JsonPropertyName("concurrency")]
        public int Concurrency { get; set; } = 20;

        [JsonPropertyName("translate_abstract")]
        public bool TranslateAbstract { get; set; } = true;

        [JsonPropertyName("abstract_batch_size")]
        public int AbstractBatchSize { get; set; } = 10;
    }

    public enum QuestionCoverage
    {
        AllArticles,
        FutureArticles,
    }

    /// <summary>
    /// A stable, user-editable AI classification question. The Id is internal and
    /// never reused; Nickname is the human-facing/export label.
    /// </summary>
    public sealed class Question
    {
        [JsonPropertyName("id")]
        public string Id { get; set; } = string.Empty;

        [JsonPropertyName("nickname")]
        public string Nickname { get; set; } = string.Empty;

        [JsonPropertyName("text")]
        public string Text { get; set; } = string.Empty;

        [JsonPropertyName("classify")]
        public bool Classify { get; set; } = true;

        [JsonPropertyName("export")]
        public bool Export { get; set; } = true;

        [JsonPropertyName("archived")]
        public bool Archived { get; set; }

        /// <summary>
        /// A null boundary means all historical and future articles. A non-null
        /// rowid only applies to articles merged after that rowid frontier.
        /// </summary>
        [JsonPropertyName("classify_after_rowid")]
        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
        public long? ClassifyAfterRowId { get; set; }

        [JsonIgnore]
        public string DisplayName
        {
            get
            {
                return string.IsNullOrWhiteSpace(Nickname) ? Id : Nickname;
            }
        }

        [JsonIgnore]
        public bool IsActiveForClassification
        {
            get { return Classify && !Archived; }
        }

        [JsonIgnore]
        public bool IsCurrent
        {
            get { return !Archived; }
        }

        [JsonIgnore]
        public QuestionCoverage Coverage
        {
            get { return ClassifyAfterRowId.HasValue ? QuestionCoverage.FutureArticles : QuestionCoverage.AllArticles; }
        }

        [JsonIgnore]
        public bool AppliesToHistoricalArticles
        {
            get { return !ClassifyAfterRowId.HasValue; }
        }

        [JsonIgnore]
        public long? ClassificationScopeKey
        {
            get { return ClassifyAfterRowId; }
        }

        public void Normalize()
        {
            Id = Id ?? string.Empty;
            Nickname = Nickname ?? string.Empty;
            Text = Text ?? string.Empty;
            if (ClassifyAfterRowId.HasValue && ClassifyAfterRowId.Value < 0)
            {
                ClassifyAfterRowId = null;
            }
        }
    }

    public sealed class ClassifyConfig
    {
        [JsonPropertyName("max_workers")]
        public int MaxWorkers { get; set; } = 20;

        [JsonPropertyName("batch_size")]
        public int BatchSize { get; set; } = 15;

        [JsonPropertyName("max_attempts")]
        public int MaxAttempts { get; set; } = 3;

        [JsonPropertyName("questions")]
        public List<Question> Questions { get; set; } = ConfigDefaults.CreateQuestions();

        /// <summary>
        /// Persistent q&lt;N&gt; high-water mark, not the current number of questions.
        /// It must never move backwards when a question is archived or deleted.
        /// </summary>
        [JsonPropertyName("next_question_number")]
        public long NextQuestionNumber { get; set; } = 3;

        [JsonIgnore]
        public long NormalizedNextQuestionNumber
        {
            get
            {
                long maximumExisting = 0;
                foreach (Question question in Questions ?? Enumerable.Empty<Question>())
                {
                    long parsed;
                    if (question != null && TryParseQuestionNumber(question.Id, out parsed) && parsed > maximumExisting)
                    {
                        maximumExisting = parsed;
                    }
                }

                if (maximumExisting == long.MaxValue)
                {
                    throw new InvalidOperationException("问题 ID 已达到可分配的最大值。");
                }

                long floor = maximumExisting + 1;
                return Math.Max(1L, Math.Max(NextQuestionNumber, floor));
            }
        }

        [JsonIgnore]
        public string NextQuestionId
        {
            get { return "q" + NormalizedNextQuestionNumber.ToString(CultureInfo.InvariantCulture); }
        }

        public string AllocateQuestionId()
        {
            long next = NormalizedNextQuestionNumber;
            if (next == long.MaxValue)
            {
                throw new InvalidOperationException("问题 ID 已达到可分配的最大值。");
            }

            NextQuestionNumber = next + 1;
            return "q" + next.ToString(CultureInfo.InvariantCulture);
        }

        public void NormalizeQuestionIdAllocator()
        {
            NextQuestionNumber = NormalizedNextQuestionNumber;
        }

        private static bool TryParseQuestionNumber(string? id, out long number)
        {
            number = 0;
            if (id == null || id.Length < 2 || id[0] != 'q')
            {
                return false;
            }

            return long.TryParse(id.Substring(1), NumberStyles.None, CultureInfo.InvariantCulture, out number)
                && number >= 1;
        }
    }

    public sealed class SchemaConfig
    {
        public static readonly IReadOnlyList<string> RequiredReviewColumns = new[] { "include", "tags" };

        private static readonly HashSet<string> ReservedColumns = new HashSet<string>(StringComparer.Ordinal)
        {
            "epmc_id", "pmid", "doi", "source", "pmcid", "title", "abstract", "pub_year",
            "author_string", "journal_title", "first_publication_date", "query_search_term",
            "journal_info_json", "keyword_list_json", "title_zh", "abstract_zh",
        };

        private static readonly Regex IdentifierPattern = new Regex(
            "^[A-Za-z_][A-Za-z0-9_]*$", RegexOptions.CultureInvariant);

        [JsonPropertyName("custom_columns")]
        public List<string> CustomColumns { get; set; } = new List<string>(RequiredReviewColumns);

        public static List<string> NormalizeAnnotationColumns(IEnumerable<string>? values)
        {
            var result = new List<string>(RequiredReviewColumns);
            var seen = new HashSet<string>(result, StringComparer.Ordinal);

            if (values == null)
            {
                return result;
            }

            foreach (string rawValue in values)
            {
                string column = (rawValue ?? string.Empty).Trim();
                if (!IdentifierPattern.IsMatch(column)
                    || ReservedColumns.Contains(column)
                    || column.EndsWith("_ans", StringComparison.Ordinal)
                    || column.EndsWith("_rea", StringComparison.Ordinal)
                    || !seen.Add(column))
                {
                    continue;
                }

                result.Add(column);
            }

            return result;
        }

        public void NormalizeCustomColumns()
        {
            CustomColumns = NormalizeAnnotationColumns(CustomColumns);
        }
    }

    public sealed class ExportConfig
    {
        [JsonPropertyName("filter")]
        public string Filter { get; set; } = "pending";

        [JsonPropertyName("exclude_columns")]
        public List<string> ExcludeColumns { get; set; } = new List<string>
        {
            "journal_info_json",
            "keyword_list_json",
        };
    }

    public sealed class ThemeConfig
    {
        /// <summary>
        /// Null means the LitNexus default teal. A project persists only a hue;
        /// clients derive suitable light/dark contrast from it locally.
        /// </summary>
        [JsonPropertyName("accent_hue")]
        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
        public double? AccentHue { get; set; }

        public static double? NormalizeAccentHue(double? hue)
        {
            if (!hue.HasValue || double.IsNaN(hue.Value) || double.IsInfinity(hue.Value)
                || hue.Value < 0d || hue.Value > 1d)
            {
                return null;
            }

            return hue.Value == 1d ? 0d : hue;
        }

        public void Normalize()
        {
            AccentHue = NormalizeAccentHue(AccentHue);
        }
    }

    internal static class ConfigDefaults
    {
        public static List<string> CreateJournalLines()
        {
            return new List<string>
            {
                "# 每行一个期刊名，需与 Europe PMC 中的名称完全一致；# 开头为注释、空行忽略。",
                "# 下面是示例，请按需增删：",
                "Nature",
                "Bioinformatics",
                "Genome Biology",
                "Nucleic Acids Research",
            };
        }

        public static List<string> CreateKeywordLines()
        {
            return new List<string>
            {
                "# 每行一个 Europe PMC 检索式，支持布尔语法（AND/OR/NOT）与引号短语；# 开头为注释。",
                "# 下面是示例，请按需增删：",
                "(microbiome OR microbiota) AND \"machine learning\"",
                "\"single cell\" AND (deep learning OR neural network)",
            };
        }

        public static List<Question> CreateQuestions()
        {
            return new List<Question>
            {
                new Question
                {
                    Id = "q1",
                    Nickname = "生物医学领域",
                    Text = "请判断本文是否属于'计算生物学、生物信息学、生物医学'或相关交叉领域。若文章属于以下任一类型，请回答'是'：(1) 涉及组学数据（基因/蛋白/代谢等）的分析或实验研究；(2) 涉及生物算法、模型、软件工具或数据库的开发与应用；(3) 对上述相关领域的综述、系统评价、进展总结或观点展望。仅当文章是纯粹的临床护理个案、社会学调查、或完全不涉及生物医学背景的纯数学/计算机理论时，才回答'否'。",
                },
                new Question
                {
                    Id = "q2",
                    Nickname = "核心方向",
                    Text = "请判断本文是否属于以下任一核心关注领域（命中任意一项即回答'是'）：(a) 微生物组学（Microbiome）；(b) 生物基础模型与生成式AI；(c) 生物医学机器学习应用；(d) 病毒与病原体计算；(e) 生物信息核心工具。若均不属于，回答'否'。",
                },
            };
        }
    }
}
