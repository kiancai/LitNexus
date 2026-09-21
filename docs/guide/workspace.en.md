# Guide: Workspace

For users, the essential rule is: **one project = one workspace folder**.

## Create a workspace

1. Create a project from the project picker and choose its location, or open an existing workspace folder.
2. Prefer a new subfolder. Nonempty folders require confirmation; locations such as your home, Desktop or cloud-drive root cannot be initialized directly as new workspaces.
3. Follow [Initial setup](setup.md) to enter retrieval scope, questions and model services. Adjust them later in Settings.

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

Fully quit LitNexus before copying the entire workspace to another computer, then open it in the client. While the app is running, use the database backup on [Data](data.md). A database backup does not include TOML configuration or raw downloads.

> **Cross-platform use**: the same workspace can move between Mac and Windows, but it cannot be written by both at the same time. Fully quit LitNexus on the other platform before switching devices, so that two clients never operate on the same SQLite/WAL database simultaneously.

For architectural details, see [Workspace & configuration](../reference/workspace.md).
