# Initial setup

When you create or first open a workspace, LitNexus collects initial configuration in three independent steps. Every step can be changed later in **Settings**. Choosing **Skip** does not affect download, merge, browsing, or export; it only leaves AI-dependent translation and classification unconfigured.

## 1. Retrieval scope { #retrieval }

Enter journal names and Europe PMC keyword queries. Both are line-based inputs, and lines beginning with `#` are comments. You can keep the examples, leave either list empty, or revise them later.

## 2. Screening questions { #questions }

Initial setup provides one sample question. For each question, AI independently answers **yes** or **no** and gives a reason. You may keep one, remove all questions, or add as many independent questions as needed. When a question's meaning changes, create a new one and archive the old one in **Settings** rather than rewriting a question that already has answers.

For a workspace that already has a database, the initial wizard never overwrites its existing questions or answers; manage them in **Settings** instead.

## 3. AI profiles { #ai }

An AI profile is a named OpenAI-compatible endpoint configuration: name, Base URL, model, API key, and optional extra request parameters. Initial setup can add, edit, and delete multiple profiles and select one as the active profile. Translation and classification use only the selected active profile for a run.

You may leave AI unconfigured and add a profile later in **Settings**. API keys are stored in the workspace's `litnexus.toml`; remove sensitive information before sharing or uploading a workspace.
