# Guide: Run

This page describes the full Mac pipeline. Windows Preview does not yet implement Run.

## Before running

1. Open a workspace and add at least one valid journal or query in Settings → Search.
2. For translation or classification, select and test the active model service in AI & Translation. Check enabled questions and their coverage in Classification.
3. Set the number of recent days on Run. New projects default to 14 days; changes are saved as the project's default.

Without a model service, use the additional actions to run download and merge individually. Model calls may incur provider charges.

## Start a round

Choose Start, review the scope and AI workload in the confirmation, then proceed. If you previously disabled confirmation, restore it using the additional actions menu.

| Step | Result |
|---|---|
| Download | Raw JSONL files in the workspace's `downloads/` folder |
| Merge | Deduplicated database records; processed files move to `downloads/_merged/` |
| Translate | Missing translations, using the active model service |
| Classify | AI answers and reasons for enabled questions, within each question's coverage |

The execution path shows state, counts, elapsed time and warnings. Run records summarize the round; expand technical details to investigate failures. Export CSV and import human review separately on [Data](data.md).

## Stop and continue

Choose Stop and wait for the current work to reach a safe checkpoint. Written results remain. Once idle, run the required step again. Merge handles unmerged files; translation and classification handle unfinished records. Downloading again still queries Europe PMC rather than resuming an exact network page.

## Troubleshooting

| Symptom | Check and recovery |
|---|---|
| Download fails or returns no results | Check connectivity, the time window and query. Verify the query in Europe PMC, then retry download. Increase the paging delay in Search if rate-limited. |
| Downloads exist but database counts do not increase | Ensure merge completed. Duplicates are skipped; inspect records for missing article IDs or file errors. |
| Translation or classification fails | Check the active endpoint, model, key and provider balance. Test the connection and retry the step. Do not clear the database to retry AI. |
| No classification work is pending | Check whether questions are enabled, archived or limited to future articles. Historical backfill must be explicitly enabled. |
| Reporting an error | Copy diagnostics and identify the failed step. Review for sensitive content before sharing; do not attach a project configuration containing API keys. |

See [Settings](settings.md) and the [pipeline rules](../reference/pipeline.md).
