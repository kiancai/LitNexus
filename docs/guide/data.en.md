# Guide: Data

The full workflow below describes Mac. Windows Preview supports CSV export and review import; database maintenance is not yet at parity.

## Check status and export CSV

1. Check total, pending-review, included and excluded counts. These are human-review states, not AI classification results.
2. Select an export scope: All, Pending review, Included or Excluded.
3. Expand Choose columns and select the fields you need. Each question's export switch in Settings → Classification controls its answer columns.
4. Export CSV, then open the export directory to find the file in the workspace's `exports/` folder. Scope and column choices are saved for next time.

`epmc_id`, `include` and `tags` are always included. Edit only `include` (`yes` / `no`) and optional `tags`. Titles, abstracts, translations and AI answers provide context and are not written back by review import.

## Import human review

1. Choose Import review results and open the edited CSV.
2. Read the preflight report. Fix missing IDs, duplicate IDs and invalid values; unmatched articles and overwrite conflicts are also listed.
3. Existing labels are protected by default. To replace them deliberately, enable Allow overwriting existing manual labels and recheck the report.
4. Confirm import. Blocking errors prevent writes. When changes can be applied, the app creates a backup first. Check the updated count afterwards.

Blank values mean no change, not clearing existing labels. See [Manual review & CSV import](manual-review.md) for formats and examples.

## Back up and import a database

Choose Export database (backup) in database maintenance to save an independent `.db` snapshot. This backs up the database only. To retain model services, search configuration and raw downloads too, quit the app and back up the entire workspace.

To import a backup or another project's database:

1. Check the destination project and keep a separate backup of its current database.
2. Choose Import database (skip existing) and open the source `.db`.
3. If question mapping appears, map each source question to an existing question, create a new one or skip it. Matching IDs alone do not establish matching meanings.
4. Confirm and check inserted, skipped and backup counts. Import backs up the destination first and preserves existing articles by default.
5. Use Advanced import: fill empty fields only when you want to complete missing fields in current articles.

Import merges data; it does not restore existing nonempty fields to an old snapshot. To inspect or recover a complete old snapshot, create a separate workspace, import the backup, and verify question mappings and counts while retaining the current project for comparison.

## Clear article data

1. Export a separate backup and verify the project you intend to clear.
2. Expand Clear database and choose the action.
3. Read the warning, type the full project name and confirm.

This clears articles, translations, classifications and review labels while keeping configuration and column structure. An automatic backup is created first. There is no one-click undo, so verify your backup before proceeding.
