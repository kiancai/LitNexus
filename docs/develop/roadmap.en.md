# Roadmap

The current agreed development sequence (from 2026-07):

```text
1. Organize the project architecture (documentation site + clear responsibilities)
2. Document the purpose, boundaries, data flow, and platform strategy
3. After the documentation is settled → finish the native Mac version
4. Use the finalized Mac version → build the native Windows version (data contract first, then pages)
```

## Stages

### Stage 1 — Architecture and documentation infrastructure ✅ In progress

- [x] Use MkDocs Material + GitHub Pages
- [x] Publish architecture and product skeleton pages
- [x] Repository top level: `mac/` · `win/` · `docs/` (symmetric naming)
- [x] Consolidate the repository around the three product entry points `mac/`, `win/`, and `docs/`
- [ ] Deepen the documentation
- [x] Keep README as a front door only

### Stage 2 — Clarify the documentation and product purpose

- [ ] Review product motivation and boundaries ([overview](../reference/product.md), [scope](../reference/scope.md))
- [ ] Make the pipeline, database, and workspace invariants explicit
- [x] Rewrite the user guide around Mac, align bilingual navigation and redirect legacy URLs
- [ ] Define the Mac completion acceptance checklist (functional and interaction decisions)

### Stage 3 — Finish Mac

- [ ] Validate UI and engine behavior against the documentation
- [ ] Finalize release flow and installation instructions
- [ ] Recheck alignment with `selftest`

### Stage 4 — Windows (`win/`) 🚧

- [x] Establish an independent C# WPF / .NET Framework 4.8 project boundary
- [x] Port headless `selftest` acceptance with workspace, SQLite, and CSV first
- [x] Integrate project selection, basic configuration, and the safe data-review loop (status, CSV scope / column export, preflight confirmation import, automatic backup)
- [ ] Recreate Run, Statistics, full Settings, and database maintenance pages after the Mac version is finalized
- [x] Windows CI build, self-test and Preview packaging workflow
- [ ] Clean-environment Windows installation acceptance

## Product backlog

See [Feature backlog](backlog.md).

## Intentionally deferred

| Item | Reason |
|---|---|
| Windows feature recreation | Complete the data contract and engine acceptance first, so UI-first work does not make platform behavior drift |
| Linux client | Out of scope |
| Standalone brand website | GitHub Pages is sufficient |
