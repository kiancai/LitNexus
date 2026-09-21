# Scope and boundaries

This page states what LitNexus does and does not do, so that the product and its documentation do not drift apart again.

## Goals (in scope)

| Goal | Description |
|---|---|
| Literature retrieval | Journal lists and keyword queries through the Europe PMC API |
| Local library | SQLite deduplication and a portable workspace |
| AI assistance | Title translation and configurable multi-question classification, with results written to the database |
| Human review loop | CSV export → review → import of annotations |
| Traceable data | Human review, question versions, and retrieval sources must remain explainable rather than being silently lost when configuration changes |
| Desktop-first | A native client that can be opened directly (Mac is required; Windows follows) |
| Lightweight | Small footprint; no bundled heavyweight runtime |

## Non-goals (at least for now)

| Non-goal | Description |
|---|---|
| Replace a full-text reader or reference manager | LitNexus is not trying to provide Zotero/EndNote-level management |
| A shared cross-language engine | Each platform is rewritten and aligned through tests (Plan A) |
| Treat configuration changes as deletion of historical data | Old and new questions / queries should be archived and versioned, not quietly erased along with their results |
| A Linux client | Not planned for now |
| A server or account system | Workspaces are local; AI uses the user's own API credentials |
| Automatic download and parsing of full-text PDFs | The current focus is metadata plus title and abstract |
| A black box that automatically decides importance | AI performs initial screening only; final labels belong to people |

## Established design principles

- **Tests define behavior**: Mac `selftest` and equivalent checks align semantics across platforms; sharing code is not the goal.
- **A workspace is self-contained**: configuration, lists, database, downloads, and exports all live in the vault.
- **Desktop clients do not rely on environment variables**: the Mac UI manages multiple AI configurations and persists changes immediately.
- **Merge processes only new files**: merged JSONL files move to `downloads/_merged/` to avoid repeated work.

These principles will grow as the documentation matures. When a design is disputed, update this documentation before changing the code.
