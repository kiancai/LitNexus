# Database

## Summary

- File: `litnexus.db` in the workspace root
- Engine: SQLite, using WAL at runtime
- Migration: check the schema on connection; automatically create a `.db.bak` backup before structural changes
- Principle: article facts, human decisions, AI answers, and the current configuration must not overwrite one another

The database is the project's historical record, not a cache of `litnexus.toml`. A configuration change may affect future pipeline runs only. Deleting a question or query must not silently discard existing articles, manual reviews, or AI results.

## Current transitional structure

The current Mac version uses `articles` as the central table, with stable article fields and several dynamic columns.

| Field / structure | Description |
|---|---|
| `epmc_id` | Article primary key; the unique matching key for manual-review CSV files |
| `pmid` / `doi` | Auxiliary deduplication keys |
| `source` | Europe PMC source code, such as `MED`, `PMC`, `PPR`, `AGR`, or `CTX`; it is not a quality or inclusion decision |
| `title` / `abstract` / `journal_title` / `pub_year`, etc. | Article facts |
| `title_zh` | AI-translated title |
| `include` | Human review decision: `yes` / `no` / `NULL` |
| `tags` | Free-form human labels |
| `{qid}_ans` / `{qid}_rea` | Answer and reason for one AI question; the current dynamic-column implementation |
| `litnexus_questions` | A metadata mirror of current questions, including archival state, AI toggle, and the `rowid` boundary for “future articles only”; it makes the database self-describing and aligns cross-database imports |
| `article_terms` | Associations between articles and the journal / query text hit in raw download files; currently recorded by text rather than stable query ID |

The merge stage uses semantics such as `INSERT OR IGNORE` with primary keys / uniqueness constraints to avoid duplicate records. `include` and `tags` are human data and must not be overwritten by download, merge, translation, or classification.

## Manual-review data contract (implemented in Mac and Windows Core)

Only `epmc_id`, `include`, and `tags` carry meaning when a manual-annotation CSV is imported:

- `epmc_id` must be the unique matching key.
- `include` accepts only `yes` or `no` (case and surrounding whitespace may be normalized); blank means that this import does not change the existing value.
- `tags` is free text; blank likewise means that this import does not change the existing value.
- Even if title, abstract, journal, translation, or AI results appear in the CSV, they are never written back.
- Import must preflight first. Duplicate IDs, missing IDs, nonblank values with a missing ID, invalid `include`, and missing required columns are blocking errors.
- Existing human annotations are read-only by default. They may be overwritten only when the user explicitly enables overwrite and confirms the number of conflicts a second time.

See [Manual review and CSV import](../guide/manual-review.md) for complete examples, exception handling, and spreadsheet notes.

<a id="question-query-lifecycle"></a>

## Lifecycle of questions and queries

### Established behavior

| Change | Future behavior | How history is retained | How statistics avoid confusion |
|---|---|---|---|
| Add an AI question | Explicitly choose “only future new articles” (default) or “backfill historical articles” at creation | Existing question answers remain unchanged; future-only mode records the current `rowid` boundary | Display it in the current question set; historical articles outside its scope are not counted as “unclassified” |
| Rewrite question text | Create an independent question and archive the old one when semantics change | Old answers remain attached to the old question | View current questions by default; archived items remain on the Settings page |
| Disable a question | Do not call AI for it in future | Preserve every answer and reason | Hide by default in current statistics; show it in historical mode |
| Permanently clear a question | Advanced maintenance with backup and a second confirmation | Only then may data be physically deleted | Do not display it again |
| Add a query | Use it in future downloads | Do not change earlier downloads or earlier hits | Current and historical query lists can be distinguished |
| Rewrite a query | Create a new query version | Preserve the original query and its hits | Do not combine different query text into one item |
| Remove / rewrite a query | Do not download the old text in future | Do not delete existing articles or hits in raw download files | The current version has no query-archive UI yet; stable IDs and versioning are the next migration stage |

Backfilling historical articles can invoke a large amount of AI work, so it must never run automatically without notice after a question is added. The confirmation UI should also distinguish a minor formatting adjustment from a semantic change in question text. Whenever answer interpretation would change, the safe default is a new version.

### Why dynamic columns cannot remain indefinitely

At present, each new question adds `{qid}_ans` and `{qid}_rea` to `articles`. Adding columns normally does not rewrite existing article content, but backfilling historical articles incurs AI cost. Permanently deleting a question removes its columns and all historical answers, which makes structural changes riskier. As questions and queries accumulate, the column layout of `articles` becomes increasingly unsuitable for their history.

The long-term goal is to separate current rules from historical evidence:

```text
articles                         stable article facts
manual_reviews                   human include / tags

question_definitions             stable identity and archival state of a question
question_versions                every version of question text
article_answers                  article × question version × AI answer / reason / run batch

search_queries                   stable identity and archival state of a query
search_query_versions            versions of query text
download_runs                    download range, time, and configuration snapshot
article_query_hits               article × query version × download batch
```

Here, “archive” is the default deletion semantic: it no longer affects future retrieval / classification or current statistics, but does not erase history. Only “permanently clear” in advanced maintenance actually deletes data.

## Compatibility migration plan

The normalized structure must not arrive through one dangerous full-database rewrite. Migration should happen in stages:

1. Back up the current database and verify it can be restored.
2. Create the normalized tables above without immediately deleting legacy question columns from `articles`.
3. Migrate current TOML questions, dynamic answer columns, and retrieval-channel associations into the first definition / version records.
4. Compare article counts, manual-review counts, answered counts for each question, and query-hit counts before and after migration.
5. New code reads normalized tables first; legacy dynamic columns remain read-only compatible for a period.
6. Allow cleanup of old columns only when the user explicitly performs advanced maintenance, a backup exists, and verification has passed.

This keeps old projects openable while allowing statistics to explain which question text and run batch produced each answer.

## Operations

| Capability | Description |
|---|---|
| Statistics | Read only this project's database; do not retrieve literature again or call AI |
| Manual-review CSV import | Write only `include` / `tags` by `epmc_id`; preflight first and do not overwrite existing annotations by default |
| Database import | Different from CSV review; requires a separate merge strategy and question-column alignment |
| Backup / export | Create a recoverable database copy |
| Clear article data | High-risk operation; retain project configuration and column layout, and require a second confirmation |

Precise field definitions are governed by migration versions and `selftest`; this page describes the product invariants. Implementation changes must update both this page and [Pipeline](pipeline.md).
