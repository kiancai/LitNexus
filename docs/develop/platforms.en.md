# Platform strategy

## Goal

Lightweight native desktop applications: open directly with a double-click and do not bundle a heavyweight runtime.

## Plan A: rewrite each platform independently

| Platform | Technology | Status |
|---|---|---|
| **Mac** (`mac/`) | Swift + SwiftUI | The engine has self-tests; the UI will be finalized after the documentation is settled |
| **Windows** (`win/`) | C# + WPF, targeting .NET Framework 4.8 | Project selection, basic configuration, and the safe data-review loop are integrated; Run / Statistics and the remaining Settings pages still need to be recreated |
| **Linux** | — | Not planned for now |

There is no shared cross-language engine. Alignment comes from the disk and pipeline contracts in this documentation together with Mac `selftest`.

## Mac notes

- Build with SPM and Command Line Tools.
- Package with `./make_app.sh release`.
- Established interaction: multiple AI profiles, automatically saved settings, no environment-variable configuration, and merge processes new files only (`_merged/`).

## Windows notes

- Rewrite Core and the WPF UI independently; do not port or share the Swift engine.
- A headless acceptance baseline has been established with `litnexus.toml`, `litnexus.db`, the CSV review contract, and Mac `selftest`.
- Project selection and local recent-project records, basic retrieval configuration, data status, scoped export, export-column selection, and a CSV re-import loop of “preflight → explicit confirmation → automatic backup → write human-review columns only” are integrated.
- Run, Statistics, full Settings, database maintenance, and packaging must still be recreated page by page from the established Mac interaction. The current basic pages must not be mistaken for full parity.
- A workspace can be opened across platforms, but Mac and Windows must not write to the same SQLite/WAL workspace at the same time.
- The direction is a small executable using the runtime already present on Windows 10/11. Development uses an SDK-style project; release must be verified in a clean Windows environment.

## Windows Preview testing (after release)

The test package is provided through [GitHub Releases](https://github.com/kiancai/LitNexus/releases) as `LitNexus-windows-net48-preview.zip`. Fully extract the ZIP before running `LitNexus.exe`; do not take out and run only the executable. This preview covers only project selection, basic configuration, and the data-review loop. Run, Statistics, full Settings, and database maintenance are not yet at full parity.

## Documentation and implementation

```text
This documentation site ──defines──► scope for Mac completion ──after it is settled──► Windows recreation
Mac selftest ──aligns──► behavior does not drift
```
