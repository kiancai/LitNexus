using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using LitNexus.Core.Domain;
using LitNexus.Core.ImportExport;
using LitNexus.Core.Persistence;
using LitNexus.Core.Workspace;

namespace LitNexus.SelfTest
{
    /// <summary>
    /// Offline cross-platform contract checks.
    ///
    /// This executable deliberately has no UI or network dependency.  It uses a
    /// throwaway workspace and copied fixture inputs so it is safe to run over
    /// SSH, in CI, or next to a real LitNexus project.
    /// </summary>
    internal static class Program
    {
        private static int _passed;
        private static int _failed;

        private static int Main()
        {
            var temporaryRoot = Path.Combine(
                Path.GetTempPath(),
                "litnexus-win-selftest-" + Guid.NewGuid().ToString("N"));

            Console.WriteLine("LitNexus Windows Core self-test");
            Console.WriteLine("Temporary workspace: " + temporaryRoot);

            try
            {
                Directory.CreateDirectory(temporaryRoot);
                RunAll(temporaryRoot);
            }
            catch (Exception exception)
            {
                Fail("unhandled self-test exception", exception.ToString());
            }
            finally
            {
                try
                {
                    if (Directory.Exists(temporaryRoot))
                    {
                        Directory.Delete(temporaryRoot, true);
                    }
                }
                catch (Exception cleanupException)
                {
                    // A cleanup failure should be visible, but it must not hide a
                    // preceding assertion failure or leave the process successful.
                    Fail("temporary workspace cleanup", cleanupException.Message);
                }
            }

            Console.WriteLine();
            Console.WriteLine("Self-test complete: {0} passed, {1} failed.", _passed, _failed);
            return _failed == 0 ? 0 : 1;
        }

        private static void RunAll(string temporaryRoot)
        {
            // These groups are intentionally kept independent.  Each one creates
            // its own data where needed so a failure cannot corrupt a later check.
            RunGroup("fixture layout", VerifyFixtureLayout);
            RunGroup("configuration", () => VerifyConfigurationContracts(temporaryRoot));
            RunGroup("workspace session", () => VerifyWorkspaceSessionContracts(temporaryRoot));
            RunGroup("SQLite", () => VerifySqliteContracts(temporaryRoot));
            RunGroup("review CSV", () => VerifyReviewedCsvContracts(temporaryRoot));
            RunGroup("data page", () => VerifyDataPageContracts(temporaryRoot));
        }

        private static void RunGroup(string name, Action body)
        {
            try
            {
                body();
            }
            catch (Exception exception)
            {
                Fail(name + " group threw", exception.ToString());
            }
        }

        private static void VerifyFixtureLayout()
        {
            Assert(File.Exists(FixturePath("toml", "mac-compatible.toml")),
                "fixture: current workspace TOML is copied beside self-test");
            Assert(File.Exists(FixturePath("toml", "normalization.toml")),
                "fixture: hand-edited normalization TOML is copied beside self-test");
            Assert(File.Exists(FixturePath("toml", "invalid-hue.toml")),
                "fixture: invalid hue TOML is copied beside self-test");
            Assert(File.Exists(FixturePath("toml", "legacy-workspace", "litnexus.toml")),
                "fixture: legacy workspace TOML is copied beside self-test");
            Assert(File.Exists(FixturePath("csv", "review-valid.csv")),
                "fixture: valid review CSV is copied beside self-test");
            Assert(File.Exists(FixturePath("csv", "review-invalid-include.csv")),
                "fixture: invalid review CSV is copied beside self-test");
            Assert(File.Exists(FixturePath("csv", "review-duplicate-id.csv")),
                "fixture: duplicate-ID review CSV is copied beside self-test");
            Assert(File.Exists(FixturePath("csv", "review-missing-id.csv")),
                "fixture: missing-ID review CSV is copied beside self-test");
            Assert(File.Exists(FixturePath("csv", "review-no-id-column.csv")),
                "fixture: no-ID-column review CSV is copied beside self-test");
            Assert(File.Exists(FixturePath("csv", "review-tags-only.csv")),
                "fixture: tags-only review CSV is copied beside self-test");
            Assert(File.Exists(FixturePath("csv", "review-ignored-only.csv")),
                "fixture: read-only-only review CSV is copied beside self-test");
        }

        private static void VerifyConfigurationContracts(string temporaryRoot)
        {
            AppConfig defaults = AppConfig.CreateDefault();
            defaults.Normalize();

            Assert(defaults.Classify.Questions.Select(question => question.Id)
                    .SequenceEqual(new[] { "q1", "q2" }),
                "config defaults: stable q1/q2 questions");
            Assert(defaults.Schema.CustomColumns.SequenceEqual(new[] { "include", "tags" }),
                "config defaults: required review columns");
            Assert(!defaults.Theme.AccentHue.HasValue,
                "config defaults: project hue uses default teal");
            Assert(defaults.Download.Journals.Any(value => value == "Nature"),
                "config defaults: example journal remains available");
            Assert(defaults.Download.Keywords.Any(value => value.IndexOf("microbiome", StringComparison.OrdinalIgnoreCase) >= 0),
                "config defaults: example keyword remains available");

            defaults.Theme.AccentHue = 1d;
            defaults.Normalize();
            Assert(defaults.Theme.AccentHue == 0d,
                "theme normalization: hue 1 is persisted as hue 0");
            defaults.Theme.AccentHue = -0.01d;
            defaults.Normalize();
            Assert(!defaults.Theme.AccentHue.HasValue,
                "theme normalization: out-of-range hue falls back to default");

            List<string> normalizedColumns = SchemaConfig.NormalizeAnnotationColumns(new[]
            {
                " include ", "tags", "project_note", "epmc_id", "q1_ans", "bad column", "project_note",
            });
            Assert(normalizedColumns.SequenceEqual(new[] { "include", "tags", "project_note" }),
                "schema normalization: required columns stay first and invalid columns are rejected");

            var allocator = new ClassifyConfig
            {
                NextQuestionNumber = 2,
                Questions = new List<Question>
                {
                    new Question { Id = "q9", Text = "legacy question" },
                },
            };
            allocator.NormalizeQuestionIdAllocator();
            Assert(allocator.NextQuestionId == "q10",
                "question high-water: legacy q9 allocates q10 next");
            string allocated = allocator.AllocateQuestionId();
            Assert(allocated == "q10" && allocator.NextQuestionId == "q11",
                "question high-water: allocation advances and does not reuse IDs");

            var archived = new Question
            {
                Id = "q12",
                Text = "archived question",
                Classify = true,
                Archived = true,
                ClassifyAfterRowId = 42,
            };
            archived.Normalize();
            Assert(archived.Classify && !archived.IsActiveForClassification && !archived.IsCurrent,
                "question lifecycle: archive preserves classify preference but disables future work");
            Assert(archived.Coverage == QuestionCoverage.FutureArticles && !archived.AppliesToHistoricalArticles,
                "question lifecycle: rowid frontier means future articles only");

            WorkspacePaths workspace = WorkspaceStore.Create(Path.Combine(temporaryRoot, "workspace"));
            Assert(workspace.IsInitialized
                   && Directory.Exists(workspace.DownloadsDirectory)
                   && Directory.Exists(workspace.MergedDownloadsDirectory)
                   && Directory.Exists(workspace.ExportsDirectory),
                "workspace creation: config, downloads/_merged, and exports exist");
            Assert(WorkspaceStore.Open(workspace.RootDirectory).ConfigPath == workspace.ConfigPath,
                "workspace opening: only the explicit root is used");

            WorkspacePaths legacyLayout = WorkspacePaths.ForRoot(
                Path.Combine(temporaryRoot, "legacy-layout-workspace"));
            ConfigStore.Save(AppConfig.CreateDefault(), legacyLayout);
            WorkspacePaths openedLegacyLayout = WorkspaceStore.Open(legacyLayout.RootDirectory);
            Assert(Directory.Exists(openedLegacyLayout.DownloadsDirectory)
                   && Directory.Exists(openedLegacyLayout.MergedDownloadsDirectory)
                   && Directory.Exists(openedLegacyLayout.ExportsDirectory),
                "workspace opening: legacy project receives only missing layout directories");

            AppConfig persisted = ConfigStore.Load(workspace);
            persisted.Download.Days = 7;
            persisted.Download.Journals = new List<string> { "Nature", "# comment", "Cell" };
            persisted.Download.Keywords = new List<string> { "(a OR b) AND \"c d\"" };
            persisted.Theme.AccentHue = 0.71d;
            persisted.Classify.Questions[0].Archived = true;
            persisted.Classify.NextQuestionNumber = 12;
            ConfigStore.Save(persisted, workspace);

            AppConfig reloaded = ConfigStore.Load(workspace);
            Assert(reloaded.Download.Days == 7
                   && reloaded.Download.Journals.SequenceEqual(new[] { "Nature", "# comment", "Cell" })
                   && reloaded.Download.Keywords.SequenceEqual(new[] { "(a OR b) AND \"c d\"" }),
                "TOML round trip: download lists and quoted query remain exact");
            Assert(reloaded.Theme.AccentHue == 0.71d,
                "TOML round trip: project accent hue is portable");
            Assert(reloaded.Classify.Questions[0].Archived && reloaded.Classify.NextQuestionId == "q12",
                "TOML round trip: archive state and question high-water persist");

            WorkspacePaths explicitEmpty = WorkspaceStore.Create(
                Path.Combine(temporaryRoot, "explicit-empty-workspace"));
            File.WriteAllText(explicitEmpty.JournalsFile, "legacy journal\n");
            File.WriteAllText(explicitEmpty.KeywordsFile, "legacy keyword\n");
            AppConfig explicitEmptyConfig = AppConfig.CreateDefault();
            explicitEmptyConfig.Download.Journals = new List<string>();
            explicitEmptyConfig.Download.Keywords = new List<string>();
            ConfigStore.Save(explicitEmptyConfig, explicitEmpty);
            AppConfig explicitEmptyReloaded = ConfigStore.Load(explicitEmpty);
            Assert(explicitEmptyReloaded.Download.Journals.Count == 0
                   && explicitEmptyReloaded.Download.Keywords.Count == 0,
                "TOML contract: explicit empty lists do not silently fall back to legacy files");

            // Fixture-specific assertions are intentionally separate from the
            // temporary workspace, so the test catches compatibility regressions
            // against a hand-edited, cross-platform TOML sample.
            VerifyTomlFixtures();
        }

        private static void VerifyTomlFixtures()
        {
            AppConfig current = ConfigStore.Load(FixturePath("toml", "mac-compatible.toml"));
            Assert(current.Download.Days == 14
                   && current.Download.Journals.SequenceEqual(new[] { "Nature", "Bioinformatics" })
                   && current.Download.Keywords.Count == 2,
                "fixture TOML: Mac-compatible download values load");
            Assert(current.AI.Profiles.Count == 1 && current.ActiveAiId == "profile-primary"
                   && current.AI.Profiles[0].BaseUrl == "https://example.invalid/v1",
                "fixture TOML: named AI profile shape remains compatible");
            Assert(current.Classify.Questions.Select(question => question.Id).SequenceEqual(new[] { "q1", "q3" })
                   && current.Classify.Questions[1].Archived
                   && current.Classify.Questions[1].ClassifyAfterRowId == 882,
                "fixture TOML: archived future-only question remains self-describing");
            Assert(current.Theme.AccentHue == 0.42d,
                "fixture TOML: portable hue loads unchanged");

            AppConfig normalized = ConfigStore.Load(FixturePath("toml", "normalization.toml"));
            Assert(normalized.Classify.NextQuestionId == "q10",
                "fixture TOML: stale question high-water is raised above q9");
            Assert(normalized.Schema.CustomColumns.SequenceEqual(
                    new[] { "include", "tags", "review_note", "_private" }),
                "fixture TOML: annotation columns normalize without accepting facts or AI columns");
            Assert(normalized.Theme.AccentHue == 0d,
                "fixture TOML: hue one is canonicalized to zero");

            AppConfig invalidHue = ConfigStore.Load(FixturePath("toml", "invalid-hue.toml"));
            Assert(!invalidHue.Theme.AccentHue.HasValue,
                "fixture TOML: invalid hue falls back to default teal");

            AppConfig legacy = ConfigStore.Load(
                FixturePath("toml", "legacy-workspace", "litnexus.toml"));
            Assert(legacy.Download.Days == 21
                   && legacy.Download.Journals.SequenceEqual(new[] { "Nature", "Genome Biology" })
                   && legacy.Download.Keywords.Count == 2,
                "legacy workspace: missing TOML lists use documented files once");
            Assert(legacy.AI.Profiles.Count == 1
                   && legacy.AI.Profiles[0].Name == "默认"
                   && legacy.ActiveProfile != null
                   && legacy.ActiveProfile.Model == "legacy-model",
                "legacy workspace: old AI fields migrate to one active profile");
            Assert(legacy.Classify.Questions.All(question => !question.Archived)
                   && legacy.Classify.NextQuestionNumber >= 1,
                "legacy TOML: missing lifecycle fields normalize safely");
        }

        private static void VerifyWorkspaceSessionContracts(string temporaryRoot)
        {
            var mappingConfig = AppConfig.CreateDefault();
            mappingConfig.Classify.Questions.Add(new Question
            {
                Id = "q9",
                Nickname = "已归档问题",
                Text = "历史答案仍需保留吗？",
                Archived = true,
                Classify = false,
                ClassifyAfterRowId = 77,
            });
            mappingConfig.Schema.CustomColumns.Add("review_note");
            DatabaseSchemaDefinition mapped = AppConfigDatabaseSchemaMapper.ToDatabaseSchema(mappingConfig);
            QuestionSchemaDefinition mappedArchived = mapped.Questions.Single(question => question.Id == "q9");
            Assert(mapped.Questions.Count == 3
                   && mappedArchived.Archived
                   && !mappedArchived.ClassifyEnabled
                   && mappedArchived.ClassifyAfterRowId == 77
                   && mapped.CustomColumns.SequenceEqual(new[] { "include", "tags", "review_note" }),
                "workspace schema mapper: current, archived, and custom schema intent are preserved");

            var duplicateQuestionConfig = AppConfig.CreateDefault();
            duplicateQuestionConfig.Classify.Questions.Add(new Question
            {
                Id = "q1",
                Nickname = "重复问题",
                Text = "duplicate",
            });
            bool duplicateWasRejected = false;
            try
            {
                AppConfigDatabaseSchemaMapper.ToDatabaseSchema(duplicateQuestionConfig);
            }
            catch (WorkspaceSchemaException)
            {
                duplicateWasRejected = true;
            }

            Assert(duplicateWasRejected,
                "workspace schema mapper: duplicate stable question IDs are rejected before database open");

            string workspaceRoot = Path.Combine(temporaryRoot, "session-workspace");
            string statePath = Path.Combine(temporaryRoot, "local-state", "state.json");
            var localState = new LocalWorkspaceStateStore(statePath, maximumRecentWorkspaces: 3);
            WorkspaceSession session = WorkspaceSession.Create(workspaceRoot);
            try
            {
                Assert(session.Paths.RootDirectory == Path.GetFullPath(workspaceRoot)
                       && session.Config.Classify.Questions.Count == 2
                       && session.Database.HasArticleColumn("q1_ans"),
                    "workspace session: explicit create loads TOML and opens synchronized SQLite");

                session.Config.Classify.Questions.Add(new Question
                {
                    Id = "q9",
                    Nickname = "新问题",
                    Text = "新问题文本",
                    ClassifyAfterRowId = 12,
                });
                session.Config.Schema.CustomColumns.Add("session_note");
                session.SaveConfig();
                Assert(session.Database.HasArticleColumn("q9_ans")
                       && session.Database.HasArticleColumn("q9_rea")
                       && session.Database.HasArticleColumn("session_note"),
                    "workspace session: saving config adds only required dynamic columns");

                session.RememberAsCurrent(localState);
                LocalWorkspaceState remembered = localState.Load();
                Assert(File.Exists(statePath)
                       && remembered.CurrentWorkspacePath == session.Paths.RootDirectory
                       && remembered.RecentWorkspacePaths.SequenceEqual(new[] { session.Paths.RootDirectory })
                       && File.ReadAllText(session.Paths.ConfigPath).IndexOf(
                              session.Paths.RootDirectory, StringComparison.Ordinal) < 0,
                    "workspace session: local current/recent JSON is separate from portable TOML");
            }
            finally
            {
                session.Dispose();
            }

            bool disposedAccessWasBlocked = false;
            try
            {
                LitNexusDatabase ignored = session.Database;
            }
            catch (ObjectDisposedException)
            {
                disposedAccessWasBlocked = true;
            }

            Assert(session.IsDisposed && disposedAccessWasBlocked,
                "workspace session: dispose releases and blocks later database access");

            using (WorkspaceSession reopened = WorkspaceSession.Open(workspaceRoot))
            {
                Assert(reopened.Config.Classify.Questions.Any(question => question.Id == "q9")
                       && reopened.Database.HasArticleColumn("session_note"),
                    "workspace session: explicit reopen reloads TOML and preserves additive schema");
            }

            string secondWorkspaceRoot = Path.Combine(temporaryRoot, "second-session-workspace");
            using (WorkspaceSession secondSession = WorkspaceSession.Create(secondWorkspaceRoot))
            {
                secondSession.RememberAsCurrent(localState);
            }

            LocalWorkspaceState twoProjects = localState.Load();
            Assert(twoProjects.CurrentWorkspacePath == Path.GetFullPath(secondWorkspaceRoot)
                   && twoProjects.RecentWorkspacePaths.SequenceEqual(new[]
                   {
                       Path.GetFullPath(secondWorkspaceRoot),
                       Path.GetFullPath(workspaceRoot),
                   }),
                "local workspace state: current project leads a bounded recent list");

            localState.ForgetWorkspace(secondWorkspaceRoot);
            Assert(localState.Load().CurrentWorkspacePath == null
                   && localState.ListRecentWorkspacePaths().SequenceEqual(new[] { Path.GetFullPath(workspaceRoot) }),
                "local workspace state: forgetting current clears it without choosing another project");

            localState.RememberOpenedWorkspace(workspaceRoot);
            localState.ClearCurrentWorkspace();
            Assert(localState.Load().CurrentWorkspacePath == null
                   && localState.ListRecentWorkspacePaths().SequenceEqual(new[] { Path.GetFullPath(workspaceRoot) }),
                "local workspace state: clearing current retains chooser history");
        }

        private static void VerifySqliteContracts(string temporaryRoot)
        {
            string databasePath = Path.Combine(temporaryRoot, "sqlite-contract.db");
            DatabaseSchemaDefinition schema = CreateSchemaDefinition();

            using (LitNexusDatabase database = LitNexusDatabase.Open(databasePath, schema))
            {
                database.EnsureDynamicSchema(schema);
                ISet<string> articleColumns = new HashSet<string>(
                    database.GetArticleColumns(), StringComparer.Ordinal);
                Assert(articleColumns.IsSupersetOf(new[]
                {
                    "epmc_id", "pmid", "doi", "title", "include", "tags", "review_note",
                    "q1_ans", "q1_rea", "q9_ans", "q9_rea",
                }),
                    "SQLite schema: base, review, and question dynamic columns exist");
                Assert(database.JournalMode.Equals("wal", StringComparison.OrdinalIgnoreCase),
                    "SQLite runtime: database uses WAL journal mode");

                string featureBackup = Path.Combine(temporaryRoot, "sqlite-feature-backup.db");
                SqliteFeatureReport features = database.ProbeRequiredFeatures(featureBackup);
                Assert(!string.IsNullOrWhiteSpace(features.Version)
                       && features.JournalMode.Equals("wal", StringComparison.OrdinalIgnoreCase)
                       && File.Exists(features.BackupPath),
                    "SQLite feature probe: UPDATE FROM, DROP COLUMN, and VACUUM INTO work");

                var firstArticle = new ArticleRecord("EPMC-1")
                {
                    Pmid = "PMID-1",
                    Doi = "doi:one",
                    Title = "Original title",
                    PublicationYear = 2024,
                    JournalTitle = "Journal One",
                };
                var duplicatePmid = new ArticleRecord("EPMC-2")
                {
                    Pmid = "PMID-1",
                    Doi = "doi:two",
                    Title = "Must not replace original",
                };
                var duplicateDoi = new ArticleRecord("EPMC-3")
                {
                    Pmid = "PMID-3",
                    Doi = "doi:one",
                    Title = "Must not insert duplicate DOI",
                };

                Assert(database.InsertArticle(firstArticle),
                    "article merge: first article is inserted");
                Assert(!database.InsertArticle(duplicatePmid) && !database.InsertArticle(duplicateDoi),
                    "article merge: duplicate PMID and DOI records are ignored");
                Assert(database.ArticleCount == 1,
                    "article merge: duplicate records do not increase article count");
                Assert(database.GetArticleText("EPMC-1", "title") == "Original title",
                    "article merge: duplicate input never overwrites the first article");
            }
        }

        private static DatabaseSchemaDefinition CreateSchemaDefinition()
        {
            return new DatabaseSchemaDefinition(
                new[]
                {
                    new QuestionSchemaDefinition("q1", "领域", "是否属于目标领域？"),
                    new QuestionSchemaDefinition(
                        "q9", "仅未来", "是否属于新问题？", archived: true, classifyEnabled: true,
                        classifyAfterRowId: 42),
                },
                new[] { "include", "tags", "review_note" });
        }

        private static void VerifyReviewedCsvContracts(string temporaryRoot)
        {
            string databasePath = Path.Combine(temporaryRoot, "review-contract.db");
            using (LitNexusDatabase database = LitNexusDatabase.Open(databasePath, CreateSchemaDefinition()))
            {
                database.InsertArticle(new ArticleRecord("R1") { Title = "Original R1" });
                database.InsertArticle(new ArticleRecord("R2") { Title = "Original R2" });
                database.InsertArticle(new ArticleRecord("R3") { Title = "Original R3" });
                database.ApplyReviewedCsvUpdates(
                    new[] { new ReviewedCsvUpdate(1, "R2", "yes", "kept") }, allowOverwrite: true);

                string validPath = FixturePath("csv", "review-valid.csv");
                ReviewedCsvImportPlan validPlan = ReviewedCsvImporter.Preflight(database, validPath);
                ReviewedCsvUpdate? validUpdate = validPlan.Updates.FirstOrDefault();
                Assert(validPlan.CanApply && validPlan.Updates.Count == 1
                       && validUpdate != null
                       && validUpdate.EpmcId == "R1"
                       && validUpdate.Include == "yes"
                       && validUpdate.Tags == "new, \"tag\"",
                    "review CSV preflight: only matching unreviewed R1 is planned and YES normalizes");
                Assert(validPlan.UnknownRows == 1 && validPlan.ConflictedRows == 1
                       && validPlan.IgnoredColumns.Contains("title")
                       && validPlan.IgnoredColumns.Contains("q1_ans"),
                    "review CSV preflight: unknown IDs, protected values, and context columns are reported");

                ReviewedCsvImportResult validResult = ReviewedCsvImporter.Execute(database, validPath);
                IDictionary<string, ReviewValues> values = database.GetReviewValues(new[] { "R1", "R2", "R3" });
                Assert(validResult.UpdatedRows == 1 && validResult.UpdatedFields == 2
                       && values["R1"].Include == "yes" && values["R1"].Tags == "new, \"tag\"",
                    "review CSV execute: only include/tags are written for R1");
                Assert(database.GetArticleText("R1", "title") == "Original R1"
                       && values["R2"].Include == "yes" && values["R2"].Tags == "kept"
                       && database.ArticleCount == 3,
                    "review CSV safety: title is read-only, existing values stay protected, unknown IDs do not create articles");

                ReviewedCsvImportPlan tagsOnly = ReviewedCsvImporter.Preflight(
                    database, FixturePath("csv", "review-tags-only.csv"));
                Assert(tagsOnly.CanApply && tagsOnly.Updates.Count == 1
                       && tagsOnly.Updates[0].EpmcId == "R3"
                       && tagsOnly.Updates[0].Include == null
                       && tagsOnly.Updates[0].Tags == "tag-only",
                    "review CSV: tags-only import is allowed without changing include");
                ReviewedCsvImporter.Execute(database, FixturePath("csv", "review-tags-only.csv"));
                Assert(database.GetReviewValues(new[] { "R3" })["R3"].Include == null
                       && database.GetReviewValues(new[] { "R3" })["R3"].Tags == "tag-only",
                    "review CSV: blank include means leave the existing value unchanged");

                ReviewedCsvImportPlan invalidInclude = ReviewedCsvImporter.Preflight(
                    database, FixturePath("csv", "review-invalid-include.csv"));
                Assert(!invalidInclude.CanApply && invalidInclude.Issues.Any(issue =>
                            issue.Kind == ReviewImportIssueKind.InvalidInclude),
                    "review CSV: non-yes/no include is a blocking error");
                bool invalidWasBlocked = false;
                try
                {
                    ReviewedCsvImporter.Execute(database, FixturePath("csv", "review-invalid-include.csv"));
                }
                catch (ReviewedCsvImportException exception)
                {
                    invalidWasBlocked = exception.Plan.ErrorCount > 0;
                }

                Assert(invalidWasBlocked
                       && database.GetReviewValues(new[] { "R3" })["R3"].Tags == "tag-only",
                    "review CSV: a blocking error writes no partial review data");

                ReviewedCsvImportPlan duplicateId = ReviewedCsvImporter.Preflight(
                    database, FixturePath("csv", "review-duplicate-id.csv"));
                Assert(!duplicateId.CanApply && duplicateId.Issues.Any(issue =>
                            issue.Kind == ReviewImportIssueKind.DuplicateEpmcId),
                    "review CSV: duplicate epmc_id blocks import instead of using last-row-wins");

                ReviewedCsvImportPlan missingId = ReviewedCsvImporter.Preflight(
                    database, FixturePath("csv", "review-missing-id.csv"));
                Assert(!missingId.CanApply && missingId.Issues.Any(issue =>
                            issue.Kind == ReviewImportIssueKind.MissingEpmcId),
                    "review CSV: a requested write without epmc_id blocks import");

                ReviewedCsvImportPlan noIdColumn = ReviewedCsvImporter.Preflight(
                    database, FixturePath("csv", "review-no-id-column.csv"));
                Assert(!noIdColumn.CanApply && noIdColumn.MissingExpectedColumns.Contains("epmc_id"),
                    "review CSV: importer never falls back from epmc_id to PMID or another key");

                ReviewedCsvImportPlan readOnlyOnly = ReviewedCsvImporter.Preflight(
                    database, FixturePath("csv", "review-ignored-only.csv"));
                Assert(!readOnlyOnly.CanApply && readOnlyOnly.Issues.Any(issue =>
                            issue.Kind == ReviewImportIssueKind.MissingWritableColumns),
                    "review CSV: a file without include or tags cannot be imported");

                ReviewedCsvImportPlan overwritePlan = ReviewedCsvImporter.Preflight(database, validPath, allowOverwrite: true);
                Assert(overwritePlan.CanApply && overwritePlan.Updates.Count == 1
                       && overwritePlan.Updates[0].EpmcId == "R2"
                       && overwritePlan.Updates[0].Include == "no"
                       && overwritePlan.Updates[0].Tags == "replace tag",
                    "review CSV: explicit overwrite creates a replacement plan for R2 only");
                ReviewedCsvImporter.Execute(database, validPath, allowOverwrite: true);
                Assert(database.GetReviewValues(new[] { "R2" })["R2"].Include == "no"
                       && database.GetReviewValues(new[] { "R2" })["R2"].Tags == "replace tag",
                    "review CSV: explicit overwrite changes existing annotations only after confirmation");
            }
        }

        /// <summary>
        /// Exercises the Data-page contract without involving WPF: review-state
        /// counting, portable CSV export, automatic snapshots, and the explicit
        /// two-step review import.  These assertions intentionally test the
        /// behavior at the public Core boundary rather than the implementation
        /// details of a particular SQLite query or file writer.
        /// </summary>
        private static void VerifyDataPageContracts(string temporaryRoot)
        {
            VerifyArticleStatusAndCsvExportContracts(temporaryRoot);
            VerifyEmptyExportContracts(temporaryRoot);
            VerifyBackupAndConfirmedImportContracts(temporaryRoot);
        }

        private static void VerifyArticleStatusAndCsvExportContracts(string temporaryRoot)
        {
            string databasePath = Path.Combine(temporaryRoot, "data-page-contract.db");
            string specialTitle = "Title, with a \"quote\"\nand a second line";
            string specialTags = "tag, \"quoted\"\r\nnext line";

            using (LitNexusDatabase database = LitNexusDatabase.Open(databasePath, CreateSchemaDefinition()))
            {
                database.InsertArticle(new ArticleRecord("PENDING-NULL")
                {
                    Title = "Pending title",
                    PublicationYear = 2021,
                });
                database.InsertArticle(new ArticleRecord("INCLUDED")
                {
                    Title = specialTitle,
                    PublicationYear = 2024,
                    JournalTitle = "Journal, \"one\"",
                });
                database.InsertArticle(new ArticleRecord("EXCLUDED")
                {
                    Title = "Excluded title",
                    PublicationYear = 2023,
                });
                database.InsertArticle(new ArticleRecord("EMPTY-STRING")
                {
                    Title = "Legacy empty include",
                    PublicationYear = 2022,
                });

                database.ApplyReviewedCsvUpdates(new[]
                {
                    new ReviewedCsvUpdate(1, "INCLUDED", "yes", specialTags),
                    new ReviewedCsvUpdate(2, "EXCLUDED", "no", "excluded tag"),
                    // The public write API permits a historical malformed empty
                    // value.  It must not be misreported as SQL NULL/pending.
                    new ReviewedCsvUpdate(3, "EMPTY-STRING", string.Empty, null),
                }, allowOverwrite: true);

                ArticleStatusSummary status = database.GetArticleStatusSummary();
                Assert(status.Total == 4 && status.Pending == 1
                       && status.Included == 1 && status.Excluded == 1 && status.Reviewed == 2,
                    "data status: pending is strictly SQL NULL; empty and malformed values are not pending");

                string exportDirectory = Path.Combine(temporaryRoot, "data-exports");
                string allPath = Path.Combine(exportDirectory, "all.csv");
                string pendingPath = Path.Combine(exportDirectory, "pending.csv");
                string includedPath = Path.Combine(exportDirectory, "included.csv");
                string excludedPath = Path.Combine(exportDirectory, "excluded.csv");

                ArticleCsvExportResult all = database.ExportArticlesCsv(
                    new ArticleCsvExportRequest(ArticleExportScope.All, allPath));
                ArticleCsvExportResult pending = database.ExportArticlesCsv(
                    new ArticleCsvExportRequest(ArticleExportScope.Pending, pendingPath));
                ArticleCsvExportResult included = database.ExportArticlesCsv(
                    new ArticleCsvExportRequest(ArticleExportScope.Included, includedPath));
                ArticleCsvExportResult excluded = database.ExportArticlesCsv(
                    new ArticleCsvExportRequest(ArticleExportScope.Excluded, excludedPath));

                Assert(all.FileCreated && all.WrittenRows == 4
                       && pending.FileCreated && pending.WrittenRows == 1
                       && included.FileCreated && included.WrittenRows == 1
                       && excluded.FileCreated && excluded.WrittenRows == 1,
                    "data export: all, pending, included, and excluded scopes use the exact review predicates");

                byte[] allBytes = File.ReadAllBytes(allPath);
                string allText = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false).GetString(allBytes);
                Assert(allBytes.Length >= 3 && allBytes[0] == 0xEF && allBytes[1] == 0xBB && allBytes[2] == 0xBF
                       && allText.Contains("\r\n"),
                    "data export: CSV is UTF-8 with BOM and uses CRLF records");

                IReadOnlyList<IReadOnlyList<string>> allRows = ReadExportCsv(allPath);
                IReadOnlyList<string> allHeader = allRows[0];
                IReadOnlyList<string> includedRow = allRows.Skip(1).Single(row =>
                    string.Equals(GetCsvValue(row, allHeader, "epmc_id"), "INCLUDED", StringComparison.Ordinal));
                Assert(GetCsvValue(includedRow, allHeader, "title") == specialTitle
                       && GetCsvValue(includedRow, allHeader, "tags") == specialTags,
                    "data export: RFC4180 keeps commas, quotes, and embedded newlines round-trippable");

                string requiredColumnsPath = Path.Combine(exportDirectory, "required-columns.csv");
                var requiredColumnsRequest = new ArticleCsvExportRequest(
                    ArticleExportScope.All,
                    requiredColumnsPath,
                    excludedColumns: new[] { "epmc_id", "include", "tags", "title" },
                    headerMap: new Dictionary<string, string>
                    {
                        { "epmc_id", "不可替换的 ID" },
                        { "include", "不可替换的纳入" },
                        { "tags", "不可替换的标签" },
                        { "journal_title", "期刊" },
                    });
                ArticleCsvExportResult requiredColumns = database.ExportArticlesCsv(requiredColumnsRequest);
                IReadOnlyList<string> requiredHeader = ReadExportCsv(requiredColumnsPath)[0];
                Assert(requiredColumns.Columns.Contains("epmc_id")
                       && requiredColumns.Columns.Contains("include")
                       && requiredColumns.Columns.Contains("tags")
                       && !requiredColumns.Columns.Contains("title")
                       && requiredHeader.Contains("epmc_id")
                       && requiredHeader.Contains("include")
                       && requiredHeader.Contains("tags")
                       && !requiredHeader.Contains("不可替换的 ID"),
                    "data export: epmc_id/include/tags remain present and machine-readable even when callers exclude or rename them");
            }
        }

        private static void VerifyEmptyExportContracts(string temporaryRoot)
        {
            string databasePath = Path.Combine(temporaryRoot, "empty-export-contract.db");
            using (LitNexusDatabase database = LitNexusDatabase.Open(databasePath, CreateSchemaDefinition()))
            {
                database.InsertArticle(new ArticleRecord("ONLY-INCLUDED") { Title = "Only included" });
                database.ApplyReviewedCsvUpdates(
                    new[] { new ReviewedCsvUpdate(1, "ONLY-INCLUDED", "yes", null) },
                    allowOverwrite: true);

                string exportDirectory = Path.Combine(temporaryRoot, "empty-exports");
                Directory.CreateDirectory(exportDirectory);
                string existingDestination = Path.Combine(exportDirectory, "must-not-overwrite.csv");
                string absentDestination = Path.Combine(exportDirectory, "must-not-create.csv");
                File.WriteAllText(existingDestination, "sentinel export", new UTF8Encoding(false));

                ArticleCsvExportResult existingResult = database.ExportArticlesCsv(
                    new ArticleCsvExportRequest(ArticleExportScope.Pending, existingDestination));
                ArticleCsvExportResult absentResult = database.ExportArticlesCsv(
                    new ArticleCsvExportRequest(ArticleExportScope.Pending, absentDestination));

                Assert(!existingResult.FileCreated && existingResult.WrittenRows == 0
                       && File.ReadAllText(existingDestination) == "sentinel export",
                    "data export: an empty scope never overwrites an existing file");
                Assert(!absentResult.FileCreated && absentResult.WrittenRows == 0 && !File.Exists(absentDestination),
                    "data export: an empty scope never creates a destination file");
            }
        }

        private static void VerifyBackupAndConfirmedImportContracts(string temporaryRoot)
        {
            string workspaceRoot = Path.Combine(temporaryRoot, "data-workspace");
            using (WorkspaceSession session = WorkspaceSession.Create(workspaceRoot))
            {
                session.Database.InsertArticle(new ArticleRecord("SNAPSHOT-ONLY") { Title = "Before snapshot" });
                WorkspaceDatabaseBackupResult directBackup = WorkspaceDatabaseBackupService.CreateAutomaticBackup(
                    session.Paths,
                    session.Database);
                Assert(directBackup.BackupPath == Path.Combine(session.Paths.RootDirectory, "litnexus.db.bak")
                       && File.Exists(directBackup.BackupPath),
                    "data backup: automatic snapshot uses the portable workspace-root litnexus.db.bak path");

                session.Database.InsertArticle(new ArticleRecord("AFTER-SNAPSHOT") { Title = "After snapshot" });
                using (LitNexusDatabase snapshot = LitNexusDatabase.Open(directBackup.BackupPath, session.DatabaseSchema))
                {
                    Assert(snapshot.ArticleCount == 1 && snapshot.GetArticleText("SNAPSHOT-ONLY", "title") == "Before snapshot"
                           && snapshot.GetArticleText("AFTER-SNAPSHOT", "title") == null,
                        "data backup: .db.bak is an independently openable SQLite point-in-time snapshot");
                }

                session.Database.InsertArticle(new ArticleRecord("IMPORT-1") { Title = "Needs review" });
                string validReviewPath = Path.Combine(temporaryRoot, "confirmed-review.csv");
                File.WriteAllText(
                    validReviewPath,
                    "epmc_id,include,tags\r\nIMPORT-1,yes,confirmed-from-csv\r\n",
                    new UTF8Encoding(false));

                DateTime backupBeforePrepare = File.GetLastWriteTimeUtc(directBackup.BackupPath);
                ReviewedCsvImportPlan prepared = ReviewedCsvImportCoordinator.Prepare(session, validReviewPath);
                ReviewValues valuesBeforeConfirm = session.Database.GetReviewValues(new[] { "IMPORT-1" })["IMPORT-1"];
                Assert(prepared.CanApply && prepared.HasChanges
                       && File.GetLastWriteTimeUtc(directBackup.BackupPath) == backupBeforePrepare
                       && valuesBeforeConfirm.Include == null && valuesBeforeConfirm.Tags == null,
                    "data review import: first phase is non-mutating and reports a confirmable plan");

                ConfirmedReviewedCsvImportResult confirmed = ReviewedCsvImportCoordinator.Confirm(session, validReviewPath);
                WorkspaceDatabaseBackupResult? confirmedBackup = confirmed.AutomaticBackup;
                Assert(confirmedBackup != null
                       && File.Exists(confirmedBackup.BackupPath)
                       && confirmed.ImportResult.UpdatedRows == 1
                       && session.Database.GetReviewValues(new[] { "IMPORT-1" })["IMPORT-1"].Include == "yes",
                    "data review import: confirmed write creates an automatic backup before applying annotations");

                if (confirmedBackup == null)
                {
                    return;
                }

                using (LitNexusDatabase beforeWriteSnapshot = LitNexusDatabase.Open(
                    confirmedBackup.BackupPath,
                    session.DatabaseSchema))
                {
                    ReviewValues beforeWrite = beforeWriteSnapshot.GetReviewValues(new[] { "IMPORT-1" })["IMPORT-1"];
                    Assert(beforeWrite.Include == null && beforeWrite.Tags == null,
                        "data review import: automatic backup contains the pre-write review state");
                }
            }

            string invalidWorkspaceRoot = Path.Combine(temporaryRoot, "invalid-data-workspace");
            using (WorkspaceSession invalidSession = WorkspaceSession.Create(invalidWorkspaceRoot))
            {
                invalidSession.Database.InsertArticle(new ArticleRecord("INVALID-1") { Title = "Must remain untouched" });
                string invalidReviewPath = Path.Combine(temporaryRoot, "invalid-confirmed-review.csv");
                File.WriteAllText(
                    invalidReviewPath,
                    "epmc_id,include,tags\r\nINVALID-1,maybe,not-written\r\n",
                    new UTF8Encoding(false));

                bool blocked = false;
                try
                {
                    ReviewedCsvImportCoordinator.Confirm(invalidSession, invalidReviewPath);
                }
                catch (ReviewedCsvImportException exception)
                {
                    blocked = exception.Plan.ErrorCount > 0;
                }

                string invalidBackupPath = Path.Combine(invalidSession.Paths.RootDirectory, "litnexus.db.bak");
                ReviewValues values = invalidSession.Database.GetReviewValues(new[] { "INVALID-1" })["INVALID-1"];
                Assert(blocked && !File.Exists(invalidBackupPath) && values.Include == null && values.Tags == null,
                    "data review import: invalid CSV neither writes annotations nor creates a backup");
            }
        }

        private static IReadOnlyList<IReadOnlyList<string>> ReadExportCsv(string outputPath)
        {
            string text = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false).GetString(File.ReadAllBytes(outputPath));
            if (text.Length > 0 && text[0] == '\uFEFF')
            {
                text = text.Substring(1);
            }

            return ReviewedCsvImporter.ParseCsv(text);
        }

        private static string GetCsvValue(
            IReadOnlyList<string> row,
            IReadOnlyList<string> header,
            string column)
        {
            int index = header.ToList().IndexOf(column);
            if (index < 0)
            {
                throw new InvalidOperationException("CSV 中缺少列：" + column);
            }

            if (index >= row.Count)
            {
                throw new InvalidOperationException("CSV 行缺少列：" + column);
            }

            return row[index];
        }

        private static string FixturePath(params string[] segments)
        {
            var pathSegments = new List<string> { AppContext.BaseDirectory, "Fixtures" };
            pathSegments.AddRange(segments);
            return Path.Combine(pathSegments.ToArray());
        }

        private static void Assert(bool condition, string name)
        {
            if (condition)
            {
                _passed++;
                Console.WriteLine("  [PASS] " + name);
                return;
            }

            Fail(name, null);
        }

        private static void Fail(string name, string? detail)
        {
            _failed++;
            Console.Error.WriteLine("  [FAIL] " + name + (string.IsNullOrWhiteSpace(detail) ? string.Empty : ": " + detail));
        }
    }
}
