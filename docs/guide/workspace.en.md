# Guide: Workspace

For users, the essential rule is: **one project = one workspace folder**.

## Create a workspace

- **CLI**: `litnexus init <directory>` — writes configuration/list templates/data directories and makes the directory the active workspace
- **Mac UI**: create or open one from the project picker or first-run setup

## Everyday editing

| File | What you edit |
|---|---|
| `litnexus.toml` | AI profiles, classification questions, journal list, keyword query, download settings, and the project accent color |
| `litnexus.db` | Articles, manual-review decisions, AI classifications, and runtime structures; normally maintained by the app |
| `downloads/` | Raw downloaded files; maintained by the app |
| `exports/` | Exported CSV files, comparison results, and other files for manual work |

In the Mac app, edit journals and search queries under **Settings → Search**. They are automatically written to the `[download]` section of `litnexus.toml`. New projects no longer use `journals.txt` or `keywords.txt` as their primary configuration source.

If these text files still exist in an older project, the client reads them only for compatibility when `litnexus.toml` does not yet contain the corresponding lists. Once the configuration has been saved, the TOML lists are authoritative. See [Workspace & configuration](../reference/workspace.md) for details.

Do not edit the database directly for manual review. Export a CSV from the Data page, then import it back according to the [Manual review & CSV import](manual-review.md) contract.

## Backup and migration

Copy the entire workspace directory to another computer, then open that directory in the client or make it the active workspace.

> **Cross-platform use**: the same workspace can move between Mac and Windows, but it cannot be written by both at the same time. Fully quit LitNexus on the other platform before switching devices, so that two clients never operate on the same SQLite/WAL database simultaneously.

For architectural details, see [Workspace & configuration](../reference/workspace.md).
