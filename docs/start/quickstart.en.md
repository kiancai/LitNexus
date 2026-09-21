# Quick start

The current primary product is the **native Mac app**. Windows is a Preview whose functions are still being reproduced page by page.

## Mac

```bash
cd mac
swift build
swift run LitNexus selftest
./make_app.sh release
```

Or download the `.app` from GitHub Releases (when available).  
To open an unsigned app for the first time: right-click it and choose **Open**.

## Windows Preview (after release)

Download `LitNexus-windows-net48-preview.zip` from [GitHub Releases](https://github.com/kiancai/LitNexus/releases), **extract the entire ZIP archive**, then run `LitNexus.exe` inside it. Do not copy or open that `.exe` alone, because files in the same directory are also runtime dependencies.

This is a test build. It currently supports project selection, basic settings, data status, CSV export, and importing manual-review results. Run, Statistics, complete Settings, and database maintenance have not yet reached full parity. Windows may show a SmartScreen warning for this unsigned test build; only continue after confirming that the download came from this project's Releases page.

## Workspace

Create or open a workspace directory in the app. It holds its configuration, database, downloads, and exports.  
See [Workspace](../guide/workspace.md).

A workspace can move from Mac to Windows and back, but its SQLite/WAL database cannot be written from both platforms at the same time. Fully quit LitNexus on the other device before switching devices.

## Initial setup

The initial wizard has three steps: **retrieval scope**, **screening questions**, and **AI profiles**. It provides one sample screening question, which you can remove or expand into any number of independent questions. AI profiles can likewise be added, edited, removed, and switched; one selected profile is used for translation and classification in a run.

Every step can be revisited in **Settings**. See [Initial setup](../guide/setup.md).

## Complete one manual-review round

After running download, merge, translation, and classification, export a CSV from the **Data** page for manual review. Imports match articles only by `epmc_id` and read only `include` and `tags`. `include` accepts only `yes` or `no`; the app validates the file before you confirm the write. See [Manual review & CSV import](../guide/manual-review.md) for the complete entry rules, validation, and conflict handling.

## Next steps

- [Workspace](../guide/workspace.md)
- [Pipeline](../reference/pipeline.md)
- [Manual review & CSV import](../guide/manual-review.md)
