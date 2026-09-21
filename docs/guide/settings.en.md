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

<!-- TODO: Document the editing steps for AI profiles, classification questions, search queries, journal lists, and advanced data structures. -->
