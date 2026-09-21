# Quick start

## 1. Install

=== ":material-download: Choose a platform"

    Select your operating system to see its installation steps.

=== ":fontawesome-brands-apple: Mac"

    1. Open [GitHub Releases](https://github.com/kiancai/LitNexus/releases).
    2. Download and extract the Mac package, then move `LitNexus.app` to Applications.
    3. The current build is ad-hoc signed, not Apple-notarized. If macOS blocks it, see the [FAQ](faq.md) before opening it.

=== ":fontawesome-brands-windows: Windows"

    1. Download `LitNexus-windows-net48-preview.zip` from [GitHub Releases](https://github.com/kiancai/LitNexus/releases).
    2. Extract the entire ZIP and run `LitNexus.exe` from the extracted directory. Keep its DLLs and other dependencies alongside it.
    3. Preview supports workspace selection, basic settings, data status, CSV export and manual-review import. Run, Statistics, full Settings and database maintenance are not yet complete. The full workflow below describes Mac.

=== ":material-console: Build from source"

    Open a terminal at the repository root. Mac requires Swift / Xcode Command Line Tools:

    ```bash
    cd mac
    swift build
    swift run LitNexus selftest
    ./make_app.sh release
    ```

    The app is generated at `mac/LitNexus.app`. For Windows prerequisites, see the [Windows README](https://github.com/kiancai/LitNexus/tree/main/win).

    ```powershell
    cd win
    .\build.ps1 -Configuration Release -SelfTest
    ```

## 2. Create or open a workspace

A workspace is a folder containing your database, configuration, downloads and exports.

1. Launch LitNexus.
2. Create a new workspace or open an existing one.
3. Prefer an empty folder when creating a workspace.
4. Before copying the entire workspace for backup or transfer, fully quit the app. Use the app's database backup while it is running.

!!! note "Moving between devices"
    Mac and Windows must not write the same SQLite/WAL workspace simultaneously. Quit the other client before switching devices.

See [Workspace and configuration](../reference/workspace.md) for the folder layout.

## 3. Initial setup

The wizard has three steps: **retrieval scope**, **screening questions** and **model services**. You can remove the sample question, add multiple questions, or skip them. You can save multiple services and choose the active one. Revisit these choices in Settings. See [Initial setup](../guide/setup.md).

## 4. Minimum configuration

| Setting | What to provide |
|---|---|
| Journals / search queries | The journals or Europe PMC queries you want to follow |
| Model service (optional) | Endpoint, model and credentials for translation and classification |

!!! abstract "Default pipeline"
    `download → merge → translate → classify`
    Export CSV and import manual-review results separately on the Data page. Without a model service, run download and merge individually first.

## 5. Complete one round

1. Open Run and execute the pipeline or individual steps.
2. Check article counts on Data.
3. Export CSV, edit `include` / `tags` in a spreadsheet, then import the reviewed file.

!!! success "Review import rules"
    - Articles match only by `epmc_id`.
    - Only `include` (`yes` / `no`) and `tags` are written back. Blank `include` leaves the original unchanged.
    - Inspect the preflight report before confirming; existing labels are protected by default.

See [Data](../guide/data.md) for export and backup steps, and [Manual review](../guide/manual-review.md) for CSV rules and conflicts.

## 6. Self-test (optional, for developers)

```bash
cd mac && swift run LitNexus selftest
```

```powershell
cd win
.\build.ps1 -Configuration Release -SelfTest
```

## Next steps

- Troubleshooting: [FAQ](faq.md)
- Documentation map: [Overview](../index.md)
- Page instructions: [Run](../guide/run.md), [Data](../guide/data.md), [Statistics](../guide/statistics.md), [Settings](../guide/settings.md)
