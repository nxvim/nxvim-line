# nxvim-line — phased implementation plan

A fully-featured, **lualine-style** statusline for nxvim. lualine's whole value is its
*config shape* — `sections = { lualine_a = {...}, ... }`, themeable, mode-coloured,
powerline-separated, with a rich component library. nxvim-line delivers that shape, but
it is a **compiler, not a renderer**: the editor already owns statusline rendering via
the native `nx.statusline` segment registry, so this plugin LOWERS a lualine-shaped
config onto that primitive and lets the hot path stay in Rust.

```lua
require("nxvim-line").setup({
  theme = "auto",
  sections = {
    lualine_a = { "mode" },
    lualine_b = { "branch", "diff", "diagnostics" },
    lualine_c = { "filename" },
    lualine_x = { "encoding", "fileformat", "filetype" },
    lualine_y = { "progress" },
    lualine_z = { "location" },
  },
})
```

## What the editor already provides (and what it doesn't)

The native `nx.statusline` API (nxvim repo: `docs/specs/2026-06-11-native-plugin-api.md`
§2, `docs/plans/2026-06-15-nx-statusline-segments.md`) is **landed and complete** for
what it covers — nxvim-line is built entirely on it:

- **Two halves, ordered named segments**: `nx.statusline.setup{ left = {...}, right = {...} }`.
  A window-local layout via `setup{ win = N, ... }`; `reset()` drops it.
- **Built-in segments** resolve natively in `nxvim-core` **every frame** (no Lua per
  frame): `mode`, `filename` (`%t`), `filepath` (`%f`), `filetype`, `encoding`,
  `location` (`line,col`), `modified`, `readonly`, `diagnostics` (per-severity counts).
- **Custom Lua segments** — `nx.statusline.segment{ name, render(ctx)->cells, events }`
  — run `render` **only on invalidation**: an explicit `nx.statusline.invalidate(name)`
  (the async pattern) or one of the segment's declared autocmd `events`. The server
  caches the published cells per `(window, name)` and paints them until the next
  invalidation (ADR 0002 rule 4: never re-enter Lua per redraw).
- **Per-window / focus differentiation**: `render(ctx)` gets `ctx = { buf, win, focused }`;
  the server re-renders per window against a fresh window mirror on layout change
  (split/close/focus/buffer-swap). This is the seam for **inactive-window** statuslines.
- **Cells carry highlights and clicks**: a cell is `{ text, hl = "Group"?, on_click =
  "v:lua.<fn>"? }`; a left-click fires the handler — the same dispatch as `%@…%X`.
- **Highlights**: `nx.hl.define(name, spec)` / `nx.hl.get` / `nx.hl.exists` — define the
  section/component groups and **auto-derive a theme** by reading the active colorscheme.
- **Global statusline**: `vim.o.laststatus = 3` (a single bottom bar) is supported.
- **`ModeChanged` autocmd** (landed in nxvim core, commit `c7c3ce2d`, 2026-06-21 — the
  one editor seam this plan originally needed, built first). Fires on any change to the
  reported `mode()` code with the pattern `old:new` (e.g. `"n:i"`, `"v:n"`),
  glob-matchable (`"*:i"`, `"n:*"`, `"*:*"`); a handler reads the transition off
  `args.match`. Gated on a registered handler (no cost when nothing listens); a
  Normal↔MultiCursor swap (both report `"n"`) is silent. This is the precise driver for
  lualine's signature **whole-section recolour by mode** — Phase 4 subscribes to it
  directly, no polling.

What the editor does **not** yet provide — the load-bearing gaps this plan must design
around (loud, not papered over):

1. **No `winbar` option**, and the custom `tabline` stays on the `%`-format path (never a
   segment layout). So winbar is out of scope (a core dependency) and tabline support, if
   any, is `%`-format-driven — see Phase 7 / Out of scope.
2. **No bundled devicons.** Like nxvim-tree, nxvim-line ships its **own** filetype/icon
   registry (overridable, and able to defer to a user-provided icon function).
3. **No `searchcount` / no diff-against-HEAD primitive.** Search-count and git data are
   computed in the plugin (git via `nx.run`); both are async/cached + `invalidate()`.

## Architecture at a glance

```
setup(config) ─► config.validate ─► compile.build
                                       │
   for each section a..z:  resolve components ─► one CUSTOM nx.statusline segment
   per section ("NxLineA".."NxLineZ"), whose render(ctx) emits the section's cells
   (icons + per-component hl + component separators), wrapped by the section's
   powerline separators in the section highlight.
                                       │
   nx.statusline.setup{ left = {A,B,C}, right = {X,Y,Z} }   (built-ins pass through)
   nx.hl.define(...)  lualine_<section>_<mode> groups, from the theme
   event wiring:  each component's events ─► invalidate its section
                  ModeChanged (old:new) ─► re-theme + invalidate mode-coloured sections
```

The design choice: **one custom segment per lualine section** (not per component). A
section is the unit lualine colours and separates, and the unit that must be emitted as a
contiguous run of cells with the powerline transition between sections. Each section's
`render(ctx)` walks its component list, calls each component's pure `provide(ctx)`,
applies that component's icon / colour / separator / condition / `fmt`, and concatenates.
Components that map 1:1 onto a native built-in (`location`, raw `diagnostics`) *may*
pass through as built-in segment names when no per-component styling is requested — an
optimisation, decided in `compile`, transparent to config.

Module map (one concern each): `config` (defaults + validate), `compile` (the lowering +
event wiring — the heart), `components/*` (the library), `highlights` (group naming +
section/component separators), `themes/*` (tables + auto-derive), `git` (async branch +
diff), `icons` (glyph registry), `extensions` (per-filetype overrides).

---

## Phase 0 — Scaffold ✅ (this commit)

Repo skeleton under `~/work/nxvim-plugins/nxvim-line`, matching the sibling plugins:
`LICENSE`, `.gitignore`, `stylua.toml`, `lua/nxvim-line/init.lua` (module-map doc + a
loud-stub `setup()` that errors until Phase 1), `examples/`, `test/`, `doc/`, this plan.

## Phase 1 — Config model + the lowering core (the compiler)

The spine everything else hangs on; thin component set so it's verifiable early.

- **`config.lua`** — the lualine-shaped defaults and a validated deep-merge:
  `options` (`theme`, `section_separators`, `component_separators`,
  `globalstatus`, `refresh`, `disabled_filetypes`, …), `sections`,
  `inactive_sections`, `tabline`, `extensions`. Accept lualine's two component
  spellings — a bare string (`"filename"`) and a table (`{ "filename", icon = …,
  color = …, separator = …, cond = …, fmt = … }`). Unknown component name → **hard
  error** (no silent blank — the `nx.statusline` unknown-segment rule, mirrored here so
  the error names the component, not an opaque `E:` cell at paint time).
- **`compile.lua`** — `build(config)`:
  1. For each non-empty section, register a custom `nx.statusline.segment` named
     `NxLine<Section>` whose `render(ctx)` resolves its components to cells.
  2. Call `nx.statusline.setup{ left = present a/b/c, right = present x/y/z }` (or
     `{ win = … }` per the active-window plumbing in Phase 5). Set `vim.o.laststatus`
     from `globalstatus`.
  3. Wire events: union each component's declared `events` → invalidate that section
     (de-duplicated so one `BufEnter` autocmd invalidates every section that needs it).
  4. Idempotent: a re-`setup()` tears down prior segments/autocmds/highlights and
     rebuilds (the keys-helper `setup()`-is-idempotent contract).
- **Components this phase** (built-in-backed, trivial `provide`): `mode`, `filename`,
  `filetype`, `location`, `progress`, `diagnostics`. No icons/colours/separators yet.
- **Tests** (`test/compile_spec.lua`, native `nx.test`): a config produces the expected
  segment names + left/right layout; the projected `status` text matches; an unknown
  component errors; `setup()` twice doesn't double-register.

## Phase 2 — Component library

Each component is a module returning `{ events = {...}, provide = function(ctx) ->
{ text, hl?, icon? } | nil }`. Pure `provide`; events drive invalidation.

- **`mode`** — long/short mode name (`NORMAL`/`N`), the data source for Phase 4's colour.
- **`branch`** — current git branch (from `git.lua`'s cache; events: `BufEnter`,
  `DirChanged`-equivalent, + explicit invalidate when the async job returns).
- **`diff`** — added/changed/removed counts vs HEAD (from `git.lua`), each its own
  coloured sub-cell with an icon.
- **`diagnostics`** — per-severity counts with icons and `DiagnosticError/Warn/Info/Hint`
  colours; sources configurable; built on `nx.diagnostic.get`; event `LspDiagnostics`.
- **`filename`** — tail / relative / absolute (`path = 0|1|2`), `[+]`/`[-]`/`[RO]` flags
  (`modified`, `readonly`), shorten-when-narrow.
- **`filetype`** — name + devicon (Phase 3 icons).
- **`fileformat`** — unix/dos/mac glyph. **`encoding`** — `'fileencoding'` + BOM.
- **`progress`** — `Top`/`Bot`/`NN%`. **`location`** — `line:col`, `%l:%c` style.
- **`lsp`** — attached client names (`nx.lsp.clients`); event `LspAttach`.
- **`searchcount`** — `[n/N]` for the active search (computed in Lua; events:
  `CursorMoved` while a search is active + on `/`/`?`).
- **Tests**: each component's `provide` against a fake `ctx`, plus end-to-end text in a
  driven editor for the stateful ones (branch/diff/diagnostics/searchcount).

## Phase 3 — Separators, icons, per-component styling

The lualine *look*, still no mode-reactive colour.

- **`icons.lua`** — filetype/extension → glyph registry (seeded like nxvim-tree's),
  `setup{ icons = {...} }` overrides, and an optional `icon` provider hook so a user's
  devicons-equivalent can drive it.
- **`highlights.lua`** — section separators (powerline `` / `` defaults, configurable
  incl. `""`), component separators (`` / ``), and the transition cells between two
  adjacent sections (the separator cell paints `fg = next section bg`, `bg = this
  section bg` — the powerline arrow). `padding` (left/right) and per-component `color`
  (`{ fg, bg, gui }` or a highlight-group name) become per-cell `hl` groups defined via
  `nx.hl.define`. Components emit their own icons here.
- **Tests** (`test/style_spec.lua`): separators appear as cells with the right groups; a
  per-component `color` defines and applies a group; padding widens a cell; empty
  separators degrade cleanly.

## Phase 4 — Themes + mode-reactive colour

The signature lualine experience: the bar recolours by mode (most visibly section A and
the powerline edges). The `ModeChanged` core seam (now available — see *What the editor
provides*) makes this **event-driven and precise**, with no polling.

**Compatibility is the point here** — adopt lualine's theme-table shape, its theme
*resolution*, and its generated highlight-group *names*, so an existing lualine theme
(and a colorscheme's lualine integration, e.g. catppuccin) drops in unchanged.

- **`themes/`** — theme tables in lualine's exact shape: per-mode palettes
  `{ normal = { a = {fg,bg,gui}, b, c }, insert, visual, replace, command, terminal,
  inactive }`. Per lualine's rules, **x/y/z default to c/b/a**, and **any unspecified
  mode defaults to `normal`**; a cell may be a `{fg,bg,gui}` table **or a string naming a
  highlight group to link to**. Resolution mirrors lualine: `options.theme` is a table
  (used as-is), or a name resolved **bundled theme → `require("lualine.themes.<name>")`
  → error** — so `theme = "catppuccin"` loads catppuccin's own lualine theme module
  (a self-contained palette table; it works because nxvim already runs catppuccin's
  colorscheme and the theme module is pure Lua on the runtimepath). `auto` derives a
  palette by reading the active colorscheme via `nx.hl.get` (`Normal`, `StatusLine`,
  `Function`, `String`, `Error`, …). `register_theme(name, table)` adds one.
- **Highlight groups, lualine-named, pre-defined once.** `compile`/`highlights` defines a
  group per `(section, mode)` from the theme up front under **lualine's own naming** —
  `lualine_<section>_<mode>` (e.g. `lualine_a_normal`, `lualine_a_insert`,
  `lualine_c_inactive`) via `nx.hl.define`. Using lualine's *highlight-group* names
  (rather than a private group scheme) means a colorscheme or user override that already
  styles `lualine_a_normal` just applies, and the surface is the one lualine users know.
  (The `nx.statusline` *segment* registry names — `NxLineA`…`NxLineZ` — are a separate,
  private namespace and don't collide with these groups.) x/y/z link to the c/b/a group
  of the same mode. Nothing is created on the hot path. The mode key comes from a
  **mode-code → theme-mode** resolver (`n → normal`, `i → insert`, `v`/`V → visual`,
  `R → replace`, `c → command`, `t → terminal`; unknown → `normal`).
- **Mode-reactive render.** Each section's `render(ctx)` reads the current mode
  (`nx.mode()`), maps it through the resolver, and emits its cells (and the powerline
  separator transition cells, whose colours depend on the adjacent sections' *current*
  bg) in the mode-appropriate `lualine_*` groups. So the `mode` component becomes a
  **custom** cell here (carrying its mode group), rather than the Phase-1 built-in
  pass-through.
- **The driver.** One `nx.autocmd.create("ModeChanged", { pattern = "*:*", callback })`
  invalidates every theme-coloured section. Because the groups are pre-defined and
  `render` just picks by the new mode, the re-render is cheap; mode changes are infrequent
  (never per-keystroke), so this is well within the no-frame-time-Lua budget. (A component
  with an explicit `color` override — itself a `{fg,bg,gui}` table, a function, or a
  **highlight-group name**, the lualine `color` surface — opts out of the mode palette.)
- **Tests** (`test/theme_spec.lua`): a theme table colours the sections; a name resolves
  through `lualine.themes.*` (a stub theme module on the rtp); `auto` produces non-nil
  groups from a loaded scheme; the code→theme-mode resolver maps each mode; the generated
  groups are named `lualine_a_normal` etc.; driving `i` / `v` / `:` recolours section A
  via `ModeChanged` (assert the cell's `hl` flips to `lualine_a_insert` / `_visual` /
  `_command` in the projected `status`), and `<Esc>` restores `lualine_a_normal`.

## Phase 5 — Inactive windows, conditions, clicks, refresh, globalstatus

- **Inactive statusline** — `inactive_sections` rendered for non-focused windows using
  `ctx.focused` (the per-window render the primitive already drives). Distinct (dim)
  highlight groups.
- **`cond` / `fmt`** — a component's `cond(ctx)` gates whether it renders;
  `fmt(str, ctx)` post-processes its text (both lualine-faithful).
- **`on_click`** — per-component `on_click = function(...)` registered as a `v:lua.<fn>`
  and threaded onto the cell (the native click bridge).
- **`refresh`** — `options.refresh = { statusline = ms }` drives a periodic
  `invalidate` of time-varying sections (e.g. a clock component). Mode colour is *not*
  on this timer — it is event-driven via `ModeChanged` (Phase 4) — so the refresh can
  stay coarse (lualine's default 1 s) without making mode transitions feel laggy.
- **`globalstatus`** — `true` → `laststatus = 3`; the layout renders once for the global
  bar; component `ctx` uses the current window.
- **Tests**: an inactive split shows `inactive_sections`; `cond=false` hides a component;
  `fmt` transforms text; a click fires its handler; `globalstatus` flips `laststatus`.

## Phase 6 — Async git (`git.lua`)

- Branch + per-file diff counts via `nx.run` (`git rev-parse`, `git diff --numstat` /
  `--shortstat` against HEAD), keyed by repo/file, **off the editor thread**; on
  completion cache the result and `nx.statusline.invalidate("NxLineB")` (or whichever
  sections host `branch`/`diff`).
- Recompute triggers: `BufEnter`, `BufWritePost`, directory change, and a debounced
  refresh. Bounded/cancellable so a slow repo never blocks (the "editor must never
  freeze" rule).
- **Tests** (`test/git_spec.lua`): a real init'd repo — branch shows; an edit+write
  updates diff counts; a non-repo buffer shows nothing (no error).

## Phase 7 — Extensions, tabline

- **`extensions.lua`** — per-filetype layout overrides (lualine's `extensions`):
  e.g. an `nxvim-tree` extension shows just the tree title, a `quickfix` extension a
  quickfix label. A filetype in `disabled_filetypes` shows the plain/empty line.
- **`tabline`** — if configured, lower the tabline sections onto the `'tabline'`
  `%`-format engine (the segment layout never applies to the tabline per the core
  design); a thin compile path emits a `%`-format string from the tabline components.
  Winbar is **out of scope** (no `winbar` option in core — a separate core dependency).
- **Tests**: a tree/quickfix buffer renders its extension layout; a disabled filetype
  shows nothing; a tabline config produces the expected `%`-format.

## Phase 8 — Docs, help, examples, polish

- **`examples/`** — a runnable `init.lua` (full lualine-style config, `theme = "auto"`,
  git + diagnostics + icons) + a sample file, verified end-to-end (the example-config
  convention). Loads the plugin from the checkout via a `dir=` spec (no `:PluginSync`).
- **`doc/nxvim-line.txt`** — vim-help-format manual surfaced by nxvim-help
  (`:help nxvim-line`); no `tags` file (auto-derived from `*anchors*`, like the siblings).
  Covers options, every component + its options, themes + writing one, extensions, the
  full config reference, and a "writing a custom component" worked example.
- **README** — install via `:Plugins`, the config surface, a component table, theming,
  and an "Extending" section (custom component + custom theme).
- **Perf pass** — confirm no per-frame Lua (built-ins stay native; custom sections only
  re-render on their events), debounce git, and bound every timer.

---

## The public Lua API (stable target)

```lua
local line = require("nxvim-line")

line.setup({
  options = {
    theme = "auto",                          -- name | table | "auto" (name → bundled or lualine.themes.<name>)
    globalstatus = false,                    -- laststatus = 3 when true
    section_separators = { left = "", right = "" },
    component_separators = { left = "", right = "" },
    disabled_filetypes = { statusline = { "nxvim-tree" } },
    refresh = { statusline = 1000 },
  },
  sections = {
    lualine_a = { "mode" },
    lualine_b = { "branch", "diff", "diagnostics" },
    lualine_c = { "filename" },
    lualine_x = { "encoding", "fileformat", "filetype" },
    lualine_y = { "progress" },
    lualine_z = { "location" },
  },
  inactive_sections = { lualine_c = { "filename" }, lualine_x = { "location" } },
  tabline = {},
  extensions = { "nxvim-tree", "quickfix" },
})

-- extension points
line.register_component("clock", { events = {}, provide = function(ctx) ... end })
line.register_theme("mine", { normal = { a = {...}, ... }, ... })
line.refresh()         -- force a re-render of all custom sections
```

A component entry is a string (`"filename"`) or a table whose `[1]` is the name plus any
of `icon`, `color`, `separator`, `cond`, `fmt`, `on_click`, and component-specific opts
(e.g. `filename.path`, `diagnostics.sources`) — the lualine shape. `setup()` is
idempotent and validates loud: an unknown component / theme / section is a hard error.

## Out of scope (v1)

- **Winbar** — needs a `'winbar'` option in nxvim-core (a separate core dependency).
- **Tabline beyond `%`-format lowering** — clickable per-tab segment regions on the
  tabline track the core's tabline `%@…@` work, not this plugin.
- **A native built-in `git`/`lsp_progress` segment** — these are plugin components by
  design (the core ships them only as custom-segment examples).
