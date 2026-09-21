# Workspace and configuration

## Workspace directory layout

```text
<root>/
├── litnexus.toml    # Project configuration: retrieval lists, AI profiles, questions, download settings, accent color
├── litnexus.db      # SQLite database (WAL)
├── downloads/       # Raw JSONL, including _merged/
└── exports/         # Exported CSV files, comparison results, and related output
```

This is the user's project vault: backing up this directory is effectively backing up the project state. `litnexus.db-wal` and `litnexus.db-shm` are SQLite runtime files. When the database is in use, do not copy just one of them. Prefer the in-app database backup/export, or fully quit the application before copying the entire directory.

## How a workspace is found

On Mac, the desktop application creates or opens a workspace through the project-selection page or first-run setup. The active project and list of recently opened projects are stored only in the local application-support directory. The project itself does not record an absolute path, so a copied or moved workspace can still be opened on another machine.

The desktop client does not use environment variables to decide either the workspace or AI configuration. Interaction is driven by in-app selection and the workspace-root `litnexus.toml`.

## `litnexus.toml` is the primary configuration source

The current Mac application stores journal lists, keyword queries, and other project configuration in the workspace-root `litnexus.toml`. Conceptually, it looks like this:

```toml
[download]
days = 14
page_size = 1000
request_delay = 0.5
journals = ["Nature", "Bioinformatics"]
keywords = [
  "(microbiome OR microbiota) AND \"machine learning\"",
  "\"single cell\" AND (deep learning OR neural network)",
]
```

- `days`: the project-default time window used on **Run**; new projects start at 14 days and edits on **Run** are saved automatically.
- `page_size`: the number of articles returned by each Europe PMC page request; valid values are 1–1,000.
- `request_delay`: seconds to wait between consecutive pages of the same query; it must be non-negative.
- `journals`: journal names used by the journal-download channel.
- `keywords`: Europe PMC search expressions used by the keyword-download channel.
- Each item is one string. Empty items or items beginning with `#` may serve as separators or comments while editing; downloads skip them.
- The Mac settings page automatically saves both lists. When TOML is edited by hand, reopening the project reads the new values.

### Compatibility with legacy list files

Older projects may contain `journals.txt`, `keywords.txt`, or `keywords/*.txt`. They are not the primary configuration for new projects. When TOML lacks the matching `download.journals` / `download.keywords` entry, a client may read the old file as a compatibility source. Once configuration is saved from the application, the arrays in `litnexus.toml` are authoritative.

Do not treat both locations as editable sources of truth, or it becomes difficult to know which list the next run will actually use.

## Other configuration

- Classification questions: `[[classify.questions]]`; each has a stable `id`, display name, and question text.
- AI profiles: stored in the `[ai].profiles` array, with `[ai].active` recording the active profile. They can be added, selected, deleted, and edited in initial setup or the application, and changes are saved automatically; a translation/classification run uses only the active profile.
- Export options and custom manual-annotation columns: stored in TOML.
- Project accent color: may be written to `[theme].accent_hue`; light / dark / system-following appearance is a local display preference and is not written into the project.

API keys are sensitive project data. Remove keys, or make a copy without keys, before sharing, uploading, or committing a workspace.

## Configuration, history, and lifecycle

Configuration expresses **how future runs should behave**; the database records **what happened in the past**. Therefore editing journals, queries, or AI questions must not silently delete historical literature, manual reviews, or historical AI answers.

### Classification questions

The following data semantics are established. Versioned storage will be implemented in a later database migration; see [Database](database.md#question-query-lifecycle).

| Action | Future pipeline behavior | Historical data | Default statistics view |
|---|---|---|---|
| Add a question | At creation, explicitly choose “only future new articles” (default) or “backfill historical articles”; future-only mode records the current database boundary | Existing answers remain unchanged | The new question appears in the current question set; historical articles outside its scope are not counted as unclassified |
| Change question text | If semantics change, create a new question and archive the old one by default; old answers must not be silently reinterpreted as answers to the new text | Keep the old question and answers | Show current questions; archived questions remain on the Settings page |
| Disable / remove a question | Archive by default and stop future AI classification | Keep historical answers and reasons | Hide archived questions by default; do not mix them into current prompt statistics |
| Permanently clear a question | Advanced maintenance only; requires automatic backup and a second confirmation | Only then may data be physically deleted | No longer shown |

The current client still uses dynamic question columns as a transitional implementation, so permanent deletion is risky. The UI and database will gradually move to stable IDs and version records. During migration, an ID from a deleted question must not be reused.

### Journal and keyword queries

| Action | Future downloads | Historical data |
|---|---|---|
| Add | Affects future downloads only | Does not rewrite or delete existing articles |
| Edit | Currently affects future downloads only; over time it will become a stable version instead of overwriting a historical query | Original hits and their original query should remain |
| Disable / remove | Remove from the current list; do not use in future downloads | Does not delete downloaded articles or historical hits |

Current retrieval-channel associations are recorded mainly by article and query text. Over time they will migrate to records with stable IDs, versions, and download batches. See [Database](database.md#question-query-lifecycle) for the detailed target.
