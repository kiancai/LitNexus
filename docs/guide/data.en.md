# Guide: Data

**Purpose**: Inspect counts in the database, export a CSV for manual review, import the review results, and back up or import the database.

- After CSV export, edit the manual-label columns in a spreadsheet application and import the file back into this project. The `?` beside **Import manual-review results** explains: “match only by `epmc_id`; read only `include` and `tags`; `include` accepts only `yes` or `no`; blank means no change in this import.”
- Titles, abstracts, journals, translations, and AI columns are read-only context. Editing them in the CSV never writes them back to the database.
- Imports validate duplicate IDs, invalid values, unmatched rows, and overwrite conflicts first. Existing manual labels are not overwritten by default. See [Manual review & CSV import](manual-review.md) for the full contract.
- Database import and clearing both create backups first. Clearing removes only article data and keeps the project configuration and column structure.

<!-- TODO: Document export scopes, column selection, backup recovery, and the step-by-step database-clearing operation. -->
