# Guide: Statistics

**Purpose**: First read the project's basic facts, then inspect the clues shown by prompts and the journal list when needed. Statistics reads only this project's database. Refreshing neither downloads literature again nor calls AI.

**Overview** is always shown as a fixed reference for the current project state. The cards below it are split into basic distributions and advanced evaluations. **Year distribution** and **Journal distribution** are expanded by default; all other cards are collapsed by default. Every card can be expanded, collapsed, and reordered independently. These reading preferences are stored on the current device and never written into project data.

After you choose **Edit**, every card temporarily collapses its content while retaining its own card boundary. Drag the cards directly to reorder them. On save, each card returns to the expanded/collapsed state it had before editing.

## Basic distributions

### Year distribution

The year chart is for observing the time range of collected literature and screening results across years.

- When switched to **Manual-review results**, the legend reflects only the pending-review, included, and excluded states shown in that chart.
- When switched to an individual question, the option is labelled **Question · question name**, and the legend likewise displays only that question's **yes / no / unclassified** results; it does not mix them with manual-review states.
- When the inclusion rate is very low, use a scale suitable for comparing small magnitudes so that small values are not overwhelmed by the total. A linear scale remains available for viewing absolute magnitude.

The **Source composition** section of the same card uses raw source codes such as `MED` and `PPR`. The `?` beside the source title explains each code. They identify literature source types, not inclusion or exclusion decisions.

### Journal distribution

Journal distribution shows the complete journal set rather than a preselected Top N. You can search every journal, click any table heading to sort it, and switch between ascending and descending order. The collected, pending-review, included, excluded, and inclusion-rate values are summaries of existing data only. Without manual-review results, an inclusion rate must display as unknown instead of being interpreted as low quality or irrelevance.

## Advanced evaluations

Advanced cards are collapsed by default, so daily corpus facts do not become mixed with analysis clues that need interpretation. They fall into two groups.

### Prompt evaluation

- **Classification result distribution**: View the classification results produced by each **Question · question name**. Very high or very low results are only a signal to inspect the scope of a prompt further; they do not mean that the prompt is correct or incorrect.
- **AI and manual comparison**: Display AI results alongside manual-review results using neutral terms such as **AI result / Manual-review result / Disagreement**, rather than directly calling a result an “AI error.” In addition to per-question comparison, it should support an aggregate review across questions, such as the set of literature that all questions tend to include but humans ultimately exclude.
- **Export comparison results**: Export the currently selected comparison set for external analysis or for using AI to help draft new screening questions. Export never changes manual labels or AI results in the database.
- **Search-query output**: Show the literature and inclusion results brought in by each search query. **Rebuild search channels** here means scanning the project's existing merged files to restore the mapping between articles and matched search queries. It does not download literature again or alter article, review, or classification data.

### Journal-list observations

This section shows collected, reviewed, and included outcomes for journals in the current data, distinguishing entries **already in the current journal list** from ones **not in the list**. It is a tool for observing list coverage and existing results; no entry should be stated directly as “recommended to add” or “recommended to remove,” and it never changes journal configuration automatically. The complete available results should remain viewable rather than being reduced to a few examples.

Journal inclusion rates, prompt comparisons, and journal-list observations all depend on existing manual-review data. When the sample is small, manual review is incomplete, or question definitions change, treat them as clues requiring verification rather than automatic decisions.

<!-- TODO: Add screenshots of each Statistics card, concrete filtering methods, and export examples. -->
