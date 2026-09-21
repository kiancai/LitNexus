# Guide: Settings

**Purpose**: Manage project appearance, search lists, AI profiles, translation and classification parameters, project location, and advanced data structures.

- Appearance mode is stored only on the current device. The project accent color is written to `litnexus.toml` and can travel with the project.
- Journal and keyword-query editors number logical lines. Visual wrapping of a long entry does not create another line number.
- Download request settings under **Search** control Europe PMC pagination only: articles per page must be 1–1,000 and 100–1,000 is usually appropriate; the page interval defaults to 0.5 seconds and 0.2–1 second is usually appropriate, with a longer delay when requests are throttled or the network is unstable. Set the download time window only on **Run**; it is remembered as the current project's default.
- AI profiles, classification questions, journal lists, and keyword search queries are automatically saved into project configuration. New projects use `litnexus.toml` as their only primary configuration source.
- You may save multiple AI profiles, but exactly one is active at a time; translation and classification use that profile. Deleting the active profile selects the first remaining profile. If no profile remains, AI actions ask you to configure one first.
- Adjust CSV export scopes and columns only on the **Data** page. The app remembers them automatically as the next default; Settings no longer duplicates export settings.
- `include` and `tags` are fixed review columns. Additional manual columns belong to **Project → Data structure (Advanced)** and do not change the rule that manual-review CSV import writes only `include` / `tags`.
- When adding a question, explicitly choose whether it applies only to future new articles or whether it should answer historical articles as well. The latter consumes additional AI quota.
- Before changing a classification question's text, read the confirmation options. When its semantics change, create a new version and archive the old question. Existing answers must not be interpreted directly as answers to the new question; archived questions are excluded from future classification and current Statistics by default.
- API keys are stored in project configuration. Remove sensitive information before sharing or uploading a project directory.

## Edit search scope

Open Settings → Search and enter one journal or query per line. Blank lines and lines beginning with `#` are ignored during download. Changes affect future downloads without deleting existing articles. Set recent days on Run; adjust page size and paging delay here. See [Search queries](retrieval.md) for examples.

## Add or switch a model service

1. Open AI & Translation and choose Add service.
2. Enter a name, endpoint, model and API key. Add JSON parameters only if your provider requires them.
3. Select the service as active and test its connection.
4. Check translation options, then return to Run. Saving multiple services does not call all of them in one run.

## Manage screening questions

1. Open Classification, choose Add question, and enter its nickname and text.
2. Choose its coverage. The default covers future newly merged articles. Historical backfill adds existing articles to the next classification workload; it does not call AI immediately.
3. Adjust AI and export switches as needed. Use the card's save buttons to commit nickname or question-text drafts.
4. When a question with existing answers changes meaning, prefer creating a new question. Preserve answers only for wording corrections. Editing in place and clearing old answers discards those results.
5. Archive questions you no longer use; restore them if needed. Permanent deletion is an advanced operation that creates a backup and requires confirmation of the question ID.

Fully versioned question and search-query storage is still planned. See [Database lifecycle](../reference/database.md#question-query-lifecycle).

## Project and advanced data structure

Use Project to open the workspace directory or switch projects. Additional manual fields are managed in Advanced data structure; defaults are usually sufficient. Extra fields do not expand review CSV writes, which remain limited to `include` and `tags`. Export a database backup on [Data](data.md) before structural changes.

This page describes Mac. Windows Preview provides basic settings and does not yet implement all of these features.
