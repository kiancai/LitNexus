# Architecture overview

## Top-level design

Three layers must remain separate:

1. **Product semantics** (language-independent): the workspace, pipeline, and database intent.
2. **Implementations**: `mac/` is the current main line; `win/` follows.
3. **Documentation**: `docs/` serves the documentation website only.

```text
        Documentation docs/
                │ constrains
          ┌─────┴─────┐
          ▼           ▼
         mac/        win/
   current product   next stage
```

## Repository directories (tracked)

```text
LitNexus/
├── docs/          # Documentation website source only
├── mac/           # Native Mac application
├── win/           # Native Windows application: Core / WPF base project and selftest
├── mkdocs.yml
└── README.md
```

Local, untracked directories may also exist (such as an old `python/` folder or a machine-local `AGENTS.md`). They are not part of the product structure.

## Product layers (conceptual)

```text
UI (mac / future win)
  → pipeline
    → EPMC · database · AI · CSV
      → workspace disk contract
```

Each desktop application has its own implementation. The disk contract and pipeline semantics remain aligned. See [Platform strategy](platforms.md) for details.

## Desktop visual hierarchy

Primary content cards across the four main pages use one shared shape with a 14 pt corner radius. Independently grouped content inside a card uses a 10 pt radius. Inputs, buttons, badges, and other controls use smaller radii to preserve hierarchy; individual main pages must not define their own primary-card radius. Page titles and icons keep at least 6 pt of drawing-safe inset inside the content column while cards remain on the column baseline; edge clipping must not truncate glyphs or icon strokes.

Editor gutters use a distinct neutral fill and separator instead of reusing the containing card fill. Full-row links to web guides use a soft accent fill and accent border so they remain visually distinct from ordinary information cards and inputs.

Navigation selection must not change text or icon font metrics. Use foreground color, fill, and borders to communicate selection so labels do not shift when switching pages.

The app uses a fixed minimum content-size baseline that does not change with routing and is large enough for the sidebar, Run's primary control deck, and the full width of the active setup step. Setup and main content must scroll when vertical space is insufficient; primary cards and actions must not be clipped, and controls must not collapse into incidental vertical stacks through natural compression. Supporting a narrower window later requires an explicit compact-layout breakpoint.

Setup steps use a short directional fade-and-offset transition while the primary card size and shadow remain fixed. Settings tabs crossfade horizontally according to their row order and move the selected background smoothly. Main pages use a two-stage vertical fade-through according to sidebar order: the old page fades out briefly, content is replaced only when fully transparent, and the new page then fades in from the corresponding direction. Only one main page is mounted at a time; complex pages must not overlap and create ghosted text, cards, or charts, and full-page slides are not used. Under normal motion, the outgoing phase is no longer than 100 ms, the incoming phase no longer than 140 ms, and the change settles within 250 ms of selection, with no intentional blank hold between phases. This is a perceptual budget; platforms may use equivalent animation curves. All displacement must respect the system Reduce Motion setting. Page and tab animation transactions are scoped to fixed content hosts; the window title bar, toolbar, sidebar, and their geometry must not inherit those transactions. An animated navigation selection may change only its local background and must not animate layout. The four main pages share one stable top-level scroll host, and page changes replace only its inner content. On macOS, `NSWindow.titlebarSeparatorStyle` is explicitly fixed for the lifetime of the window, and page changes must not recompute or flash the window chrome.
