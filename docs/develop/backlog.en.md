# Backlog and feature direction

This page records agreed directions that are not implemented yet. When an item is finished, move it to “Completed” or remove the corresponding entry in its commit.

## Completed

### Safe manual-review import and question lifecycle (2026-07-12)

- The Data page includes concise `?` help for “Import review results”; see [Manual review and CSV import](../guide/manual-review.md) for the full rules.
- CSV matches only by `epmc_id` and reads only `include` and `tags`; `include` accepts only `yes` / `no`, while blank leaves the old value unchanged.
- Import preflights before writing: duplicate IDs, invalid values, missing IDs, and missing required columns block the write; unmatched IDs and overwrite conflicts are visible.
- Existing `include` / `tags` values are not overwritten by default; the user can explicitly enable overwrite and confirm again.
- Questions archive by default rather than being hard-deleted. A new question applies by default only to articles merged after it is created; backfilling historical articles must be explicitly enabled.

## To implement

### Normalized history for questions and queries

**Status**: the safe boundary is complete; compatible migration is pending (2026-07-12)

- Migrate dynamic question columns and text-based retrieval hits into stable IDs, versions, run batches, and article association tables.
- Add archive and version UI for queries. The current editable list affects future downloads only; earlier download records remain.
- Preserve old columns as read-only compatibility during migration, verify counts first, and only then permit advanced maintenance to permanently clear them.

See [Database](../reference/database.md#question-query-lifecycle) for the full target structure and compatible migration.

### Exclude results by journal / type after retrieval

**Status**: not implemented (recorded 2026-07-07)

**Scenario**: keyword queries can retrieve many articles from low-impact or poor-quality journals. Users may want to exclude them after retrieval so that high-volume low-quality content does not drown out stronger results.

**Functional requirements**:

- Exclude by a journal list: given journal names (or ISSNs), remove articles belonging to those journals from results.
- Exclude by type: for example, exclude preprints with `source = PPR`.
- These are **optional capabilities and are off by default**. Users can enable them only when needed.

**Implementation notes**:

- This can work alongside the backlog item for “retrieval-channel tracking / `article_terms` association table.” The latter records which query or channel produced each article, enabling later screening by channel or journal.
- The data layer already contains Europe PMC `source` codes and journal fields. Exclusion can become a post-merge / post-retrieval filtering step. It must apply only to keyword-query results, so journal-query results are not accidentally harmed by the application's own journal list.
