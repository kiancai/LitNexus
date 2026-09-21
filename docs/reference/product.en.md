# Product overview and motivation

## The problem

In biology-adjacent and AI-related fields, much important work first appears on **bioRxiv / medRxiv**, and sometimes arXiv. PubMed covers only part of it (for example, NIH-funded preprints). Relying only on PubMed / WoS can miss leading preprints, while Google Scholar is not suitable for stable API automation.

**The central tension**: cover the field as completely as practical, while still retrieving and screening literature programmatically and reproducibly.

## Why this approach

LitNexus uses **Europe PMC** because it:

- incorporates PubMed and further covers bioRxiv, medRxiv, and related sources;
- provides a mature search API.

On top of that, LitNexus makes the workflow explicit:

1. Retrieve from Europe PMC using **tracked journals** and **keyword queries**.
2. Deduplicate and manage records in **SQLite**.
3. Use **AI** to translate titles and perform initial classification with multiple questions.
4. Export a **CSV** for rapid human review, then import the decisions back into the database.

Well-designed AI prompts and classification questions can substantially reduce the amount of material humans need to read. The final decision remains human-owned, through annotation columns such as `include`.

## In one sentence

> Use Europe PMC, a local workspace, and AI-assisted initial screening to build broad, repeatable screening for literature in a field of interest.

## The workspace model (user data)

All user data lives in one self-contained directory, similar to an Obsidian vault. This makes projects easy to back up, synchronize, and move between machines instead of scattering state under `~/.config`.

See [Workspace and configuration](workspace.md) for details.
