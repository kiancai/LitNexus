# Pipeline and data flow

## Overview

```text
Current configuration (litnexus.toml)
    ↓
Europe PMC API
    ↓  download   →  <workspace>/downloads/*.jsonl
    ↓  merge      →  litnexus.db (deduplicated with INSERT OR IGNORE)
    ↓  translate  →  title translation
    ↓  classify   →  AI answers and reasons for currently active questions
    ↓  export     →  exports/articles_TIMESTAMP.csv
    ←  import     ←  manually reviewed CSV (only epmc_id / include / tags)
```

`run` performs download, merge, translation, and classification in one action. **Manual-review import is separate** and is not part of the default `run`.

## Responsibilities of each step

| Step | Input | Output | What it must not do |
|---|---|---|---|
| **download** | Current journal / keyword lists and time range | `downloads/*.jsonl` | Change existing articles or human annotations |
| **merge** | JSONL not yet merged | SQLite article records | Overwrite existing human work |
| **translate** | Articles without translations | Translated titles | Change source text, manual review, or classification answers |
| **classify** | Currently active AI questions | Answers and reasons | Overwrite human `include` / `tags` |
| **export** | Database and export range | Manual-review CSV | Change the database |
| **import** | Edited manual-review CSV | Human `include` / `tags` | Write back article, translation, or AI columns |

## Classification semantics

- Every question has a stable ID, display name, question text, and active state. The current answer columns are `{id}_ans` / `{id}_rea`; they will later move to versioned records.
- AI answers use `是` / `否` (yes / no). `N/A` is allowed when the title or abstract is insufficient.
- If an invocation or parse fails, no answer is written, so a later run can retry.
- When adding a question, the user must choose its scope. **Only future new articles** is the default: the software records the database boundary at creation time, and only articles merged after that boundary wait for the question. Choosing “backfill historical articles” does not invoke AI immediately, but the next confirmed classification run includes historical pending work and may consume API budget.
- An archived question no longer participates in future classification and must not be mixed into current statistics. Its historical answers remain available for audit.

When a question's text changes semantically, replacing the text in configuration must not reinterpret old answers. The safe default is a new question version and archival of the old one. See [Database](database.md#question-query-lifecycle) for the full lifecycle and migration target.

## Manual-review import semantics

The manual-review CSV contract is stricter than merely having a readable CSV file:

- Match articles only by `epmc_id`; `pmid`, DOI, title, and row number are not substitute keys.
- Read only `include` and `tags`; no other columns are written back.
- `include` accepts only `yes` / `no`; blank means no change in this import, not “pending review.”
- Duplicate IDs, invalid values, missing IDs, unmatched articles, and overwrite conflicts must be preflighted before the user confirms writing.
- Existing human annotations are filled only when empty by default. Overwrite must be explicitly enabled by the user.

See [Manual review and CSV import](../guide/manual-review.md) for the exception-row table, CSV examples, and spreadsheet notes.

## Query changes do not rewrite history

Journal lists and keyword queries live under `[download]` in `litnexus.toml`. They configure future downloads: adding or archiving a query does not delete already downloaded articles. A changed query should be handled as a new version, rather than blending hits from different semantics into one history. Download batches and query versions will be recorded over time; see [Database](database.md#question-query-lifecycle).

## Interrupting and rerunning

The pipeline is designed by step, so it can start from, jump to, or skip a chosen step. Translation and classification target incomplete records, allowing work to continue after an interruption; they must not reset manual review.

More detailed UI operations will be completed alongside the implementation in [Page help](../guide/page-help.md).
