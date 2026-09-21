# Generate search queries and screening questions

An AI assistant can help draft journal lists, Europe PMC queries and screening questions for your project. Model services are configured separately in the third [setup step](setup.md), which can be skipped.

Copy a prompt below into an assistant, replace the placeholders, check the results, then paste the relevant entries into LitNexus.

- Journals: one name per line, matching names used in [Europe PMC](https://europepmc.org/). Lines beginning with `#` are comments; blank lines are ignored.
- Queries: one Europe PMC query per line, using Boolean operators and quoted phrases. Check generated syntax and results in Europe PMC before running it in the app.
- Questions: ask for an independent yes/no decision and a reason from the article's title and abstract.

## Journal list { #journals }

```text
My research area is {{your research area}}.
Suggest 5–10 authoritative, relevant journal names to retrieve from Europe PMC.
Return journal names only, one per line, without numbering or explanations.
```

## Search queries { #keywords }

```text
My research area is {{your research area}}.
Draft 3–5 Europe PMC queries covering its core topics and related fields.
Use AND/OR/NOT and double quotes for phrases. Return one query per line,
without numbering or explanations.
```

## Screening questions { #questions }

```text
I want to screen literature for {{your screening objective}}.
Draft one or more independent questions for an AI reading titles and abstracts.
Each question should ask for yes/no and a short reason.
Provide a nickname and question text for each. Keep each decision clear;
do not combine unrelated criteria into a question that cannot be answered independently.
```

Setup provides one sample question; remove it, add questions or leave the list empty. Once a question has answers, create a new question and archive the old one when its meaning changes. You can manage these choices later in Settings.
