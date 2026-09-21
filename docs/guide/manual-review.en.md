# Manual review & CSV import

Manual review is LitNexus's final human-decision stage. The app downloads, merges, translates, and performs an AI pre-screen; **the manually entered value of `include` determines whether an article is included**. This page defines the CSV data contract and exceptional-case handling already implemented by the current Mac version.

> **Implementation status (2026-07-12)**: The Data page provides inline `?` help and a two-step import: **validate → explicitly confirm → write**. The importer recognizes only `epmc_id`, `include`, and `tags`, and does not overwrite existing manual labels by default.

## Workflow

1. Choose the export scope on the **Data** page and export a CSV.
2. Review it in a spreadsheet application. Keep `epmc_id` and edit only `include` and `tags`.
3. Save as CSV (UTF-8 is safest) and choose the file under **Import manual-review results**.
4. Read the validation report first. Errors must be fixed; unmatched rows and conflicts with existing labels are listed clearly.
5. The database is written only after confirmation. The app creates a database backup before writing.

## Only three columns are recognized

The importer uses only the following three columns. You may keep other columns for reading context, but modifying them **never overwrites** titles, abstracts, journals, translations, or AI answers in the database.

| CSV column | Required | Meaning and rule |
|---|---:|---|
| `epmc_id` | Yes | Unique matching key. Keep both the column name and every article's value; do not substitute a title, DOI, or row number. |
| `include` | No | Manual inclusion decision. Only English `yes` or `no` is accepted. Leading/trailing whitespace and case are normalized, so for example ` YES ` is written as `yes`. |
| `tags` | No | Free-form manual tags. Any short text is allowed, for example `core`, `methods`, or `to discuss`. |

At least one of `include` and `tags` must be present. A CSV with no writable manual-review column cannot be imported.

### The only valid values for `include`

| Entry | Meaning | State after import |
|---|---|---|
| `yes` | Manually decided to include | Included |
| `no` | Manually decided to exclude | Excluded |
| Blank | Do not change the existing manual label in this import | Keep the previous value |

Do not enter `是` / `否`, `Y` / `N`, `1` / `0`, `maybe`, `N/A`, or custom text. Validation reports them as errors instead of asking the app to guess their meaning.

The meaning of a blank cell is especially important: it means **do not change**, not “reset to pending review.” To reset an existing decision to pending review, use the explicit reset operation supplied by the app; an empty cell cannot do that.

### Example

The `title` below is for people to read only. It is not read during import.

```csv
epmc_id,include,tags,title
12345678,yes,核心,"A study to include"
PMC1234567,no,不符合范围,"A study to exclude"
MED9876543,,待讨论,"Do not change include this time"
```

## How validation handles exceptional rows

After you select a file, the app validates it first and does not write to the database immediately. Validation assigns every row to one of the following categories and shows its count and details on the confirmation page.

| Situation | Validation result | Is it written? |
|---|---|---:|
| `epmc_id` exists, its value is valid, and at least one manual field has a value | Importable | Yes, subject to overwrite rules |
| Completely blank row | Ignored | No |
| Extra columns, or only modified title/abstract/AI columns | Those columns are ignored | Only the three-column rules may write data |
| The database has no matching `epmc_id` | Unmatched warning | No |
| `include` or `tags` has a value, but `epmc_id` is blank | Error | No; fix it before confirmation |
| The same `epmc_id` has `include` or `tags` entered on two rows | Error | No; remove duplicates to avoid “the last row overwrites the previous row.” Duplicate blank rows kept only for reading are ignored |
| `include` is not `yes` / `no` | Error | No; correct it |
| No `epmc_id` column | Error | No |
| Neither an `include` nor a `tags` column | Error | No |

An **error** blocks this import. An **unmatched** row is a visible warning; other valid, matched rows may still be imported after confirmation. No exception may be silently discarded.

## Overwrite and conflicts

Manual-review CSV imports use a **fill blanks only; do not overwrite existing manual labels** policy by default:

- The database `include` is blank and the CSV provides `yes` / `no`: it may be written.
- The database `tags` is blank and the CSV provides tags: they may be written.
- The database already has `include` or `tags`, and the CSV attempts to write a different value: validation lists this as **overwrite existing label**. It is not written by default.
- If a user truly needs to overwrite, they must explicitly enable **Allow overwriting existing manual labels** on the confirmation page and confirm the conflict count again.

This rule applies only to manual-review CSV imports. It is not the same as the merge policy for importing another database. For whole-database import rules such as **skip existing** / **fill blanks only**, see [Data page help](page-help.md#data-page).

## Spreadsheet guidance

- Do not sort a sheet, copy only one column, and paste it into another CSV. That can easily misalign decisions and `epmc_id` values.
- Filtering, sorting, and hiding columns are fine, but saved files must keep the `epmc_id` header and its corresponding values.
- If Excel automatically rewrites long IDs, scientific notation, or encoding, disable automatic formatting first, or use LibreOffice / Numbers and inspect the exported file afterward.
- Commas, quotation marks, and line breaks are allowed in tags. LitNexus exports standard escaped CSV; select CSV format when saving it again.
- Import one clearly defined batch of review results at a time and retain the original exported file. The automatic database backup is not a replacement for your own version management.

## Short inline-help text for the Data page

The `?` beside **Import manual-review results** on the Data page should summarize the following:

> Match only by `epmc_id`; read only `include` and `tags`. `include` accepts only `yes` or `no`; blank means no change in this import. Other columns are for reading and are never written back when modified. Before import, validation checks duplicate IDs, invalid values, and unmatched rows; existing manual labels are not overwritten by default.

See this page for the complete rules and exceptional-case handling.
