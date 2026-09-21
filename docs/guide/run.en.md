# Guide: Run

**Purpose**: Run download, merge, translation, and classification in sequence, or run one step separately from **More actions**.

1. Set the fetch scope and time window. New projects default to the latest 14 days. Changing the time window saves it as the current project's default for later runs and project reopenings until it is changed again.
2. Choose **Start run**. Translation and classification that use AI are confirmed before the first run, avoiding unintended usage charges.
3. Check the state, counts, duration, and warnings for every step under **Execution path**.
4. Check the summary of the current run under **Run record**. Expand technical details or copy diagnostics only when troubleshooting is needed.

Download produces raw files only; merge is the step that writes to the database. Translation and classification call the AI profile selected for the current project (switch it in [Settings](settings.md)). Cancellation takes effect at safe checkpoints, and completed work is retained.

<!-- TODO: Document first-run preparation, common failures in each step, and recovery procedures. -->
