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

## Phase 1 — Config model + the lowering core (the compiler) ✅ (done)

The spine everything else hangs on; thin component set so it's verifiable early.
Landed as `config.lua` + `compile.lua` + `components.lua` + the public `init.lua`
surface, with `config_spec.lua` (pure) and `compile_spec.lua` (end-to-end) — 14 tests.

> **A core fix this surfaced** (committed in the editor repo, `700f24d3`): the plugin
> test mirror's `t:statusline()` returned `""` for *any* statusline — its text extractor
> (`chunk_runs_text`) only handled chunk-pair arrays, not the `{ text, style }` segment
> *maps* `global_status` actually carries. Fixed so the rendered statusline is observable
> in plugin tests (`compile_spec` asserts on `t:statusline()`). The mirror reflects the
> **global** bar (`laststatus=3`), so those tests set `globalstatus = true`.

Notes from the build (refinements over the original sketch below):
- `nx.statusline` already owns the event→invalidate wiring (it registers an autocmd per
  segment's declared `events` and replaces them on each `setup`), so `compile` just hands
  each segment the **union** of its components' events — no separate autocmd bookkeeping,
  and idempotency falls out for free.
- A user `sections` entry **replaces that section's default wholesale** (lualine
  semantics); unspecified sections keep their (Phase-1) defaults.
- `mode` rides the new `ModeChanged` event; `location`/`progress` ride `CursorMoved(I)`;
  `diagnostics` rides `LspDiagnostics`.

Original step list (for reference):

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

## Phase 2 — Component library ✅ (done)

Each component is `{ events = {...}, provide = function(ctx, opts) -> result }` where
`result` is nil, a single cell `{ text, hl }`, or a **list of cells** (the multi-cell
support added this phase — diagnostics/diff emit one coloured cell per part). Pure
`provide`; events drive invalidation. Landed in `components.lua` + `git.lua`, with
`components_spec.lua`. **21 tests pass.**

- **`mode`** ✅ — lualine-style label; the data source for Phase 4's colour.
- **`branch`** ✅ — current git branch, from the async `git.lua` source.
- **`diff`** ✅ — added/changed/removed counts vs HEAD, each a coloured sub-cell
  (`DiffAdd`/`DiffChange`/`DiffDelete`); from `git.lua`. (Icons in Phase 3.)
- **`diagnostics`** ✅ — per-severity counts, each coloured with the editor's
  `Diagnostic{Error,Warn,Info,Hint}` groups; configurable `symbols`; `LspDiagnostics`.
- **`filename`** ✅ — tail / relative / absolute (`path = 0|1|2`) + `[+]`/`[-]` flags.
  (`readonly` isn't exposed by `nx.bo`, so `[-]` tracks `nomodifiable`; shorten-when-narrow
  is Phase 3.)
- **`filetype`** ✅ — the name (devicon in Phase 3).
- **`encoding`** ✅ — `'fileencoding'`.
- **`progress`** ✅ — `Top`/`Bot`/`NN%`. **`location`** ✅ — `line:col`.
- **`lsp`** ✅ — attached client names (`nx.lsp.clients`); `LspAttach`.

**Reordered from the original sketch (honest scope):**
- **`git.lua` pulled forward from Phase 6** so `branch`/`diff` are *real*, not silent
  stubs reading an empty cache. It runs `git` via `nx.run` off the tick, caches per file,
  and invalidates only the hosting segments on fresh data. The refresh is driven from the
  **render path**, not from a file-load event: the `branch`/`diff` `provide` calls
  `git.ensure(buf)` (a one-shot, cache-miss-guarded fetch) on each render, and the
  components list `BufEnter` + `TextChanged` so they *do* re-render when the buffer
  changes. (Why not key off a load event? A fresh `:edit` **reuses** the empty initial
  buffer — same id, so no `BufEnter` — and a no-filetype file fires no `FileType`; nxvim
  also gates `BufReadPost` once-per-buffer via its `announced` set, so loading a file into
  the reused buffer fires none of them. But the file-load advances the changedtick, which
  *does* fire `TextChanged` — so that's the reliable "buffer changed" signal. The buffer
  *name is* settled by then; the earlier worry that it wasn't was wrong.) A write /
  cwd-change force a re-fetch for staleness. **Phase 6 is now "git polish"** (debounce, a
  staleness TTL, a watch) rather than the initial build.
- **`fileformat` and `searchcount` DEFERRED** — each needs an editor primitive that
  doesn't exist: a core `'fileformat'` option (unix/dos/mac isn't modelled), and a
  search-count state surface (last pattern + match count). They are **not registered**;
  naming one in `sections` errors loud with the reason (`components._deferred`) rather
  than silently rendering nothing. Both become follow-ups gated on a small core addition.

- **Tests** (`components_spec.lua`): filename `[+]` flag (after an edit), encoding,
  injected diagnostics per severity (`nx.diagnostic.set`), `lsp` → nil with no client,
  the deferred-component error, `git._parse_diff` (pure hunk classification), and a
  real-repo branch+diff end-to-end (a temp repo via `nx.test.tempdir()`).

## Phase 3 — Separators, icons, per-component styling ✅ (done)

The lualine *look*, still no mode-reactive colour. Landed as `icons.lua` +
`highlights.lua` + the styling pass in `compile.lua` (icon emission in `components.lua`),
with `test/style_spec.lua`. **31 tests pass.**

- **`icons.lua`** ✅ — a filename/extension → glyph registry sharing nxvim-tree's
  Nerd-Font codepoints; `configure{ enabled, provider }` (from `options.icons_enabled` /
  `options.icon_provider`), `register(map)` overrides (surfaced as
  `require("nxvim-line").register_icons`), and an `icon` provider hook (a
  devicons-equivalent) that wins over the tables. `enabled = false` returns nil for every
  lookup so components render plain. The `filetype`/`branch`/`diagnostics` components emit
  their own default glyphs gated on `icons.enabled()`.
- **`highlights.lua`** ✅ — `color_group(color)` interns a lualine `color` (a `{ fg, bg,
  sp, gui }` table → a generated `NxLineColor<N>` group via `nx.hl.define`, cached by
  value; a string → the group name used as-is) and translates `gui = "bold,italic"` to
  the nx.hl boolean attrs. `reset()` clears the cache each build so the group names don't
  grow unbounded across rebuilds.
- **The render pass** (`compile.lua`) ✅ — per component: a leading `icon` override, the
  `color` override applied to every cell, then `padding` (number or `{ left, right }`,
  default 1) framing the run, with the configured **component separator** glyph between
  adjacent components (left half → `component_separators.left`, right → `.right`; `""`
  degrades to just the paddings). The lualine powerline-glyph defaults now live in
  `config.lua` (` / ` section arrows, ` / ` component separators), and a separator
  option accepts the bare-string shorthand.
- **Tests** (`test/style_spec.lua`) ✅ — icon resolution (ext / exact name / default /
  disabled / provider / register); colour interning + caching + the string pass-through;
  the component separator glyph appears between two components and an empty separator
  degrades; padding widens the cell; a per-component `color` table defines + applies its
  group (observed via `nx.hl`, since the status mirror carries text only).

**Honest scope (reordered from the original sketch):**
- **Section separators (the powerline arrows *between* sections) move to Phase 4.** The
  arrow cell's two colours ARE the two adjacent sections' *background* colours, which only
  exist once the theme defines the `lualine_<section>_<mode>` groups. So they are
  inseparable from the theme and ship with it. Phase 3 owns the *component* separators
  (drawn in the section's own highlight, no theme needed). The `section_separators`
  option + its powerline-glyph defaults are in place now, consumed in Phase 4.
- **Icon colour deferred.** A glyph rides inside its component's cell and inherits the
  section highlight (no separate coloured icon cell yet) — lualine's `colored` filetype
  option is a later refinement. Keeps Phase 3 off the theme's section groups.
- **Per-component `separator` override deferred to Phase 4** — lualine's per-component
  `separator` overrides the *section-edge* powerline separator, so it belongs with the
  section separators it parameterizes.

## Phase 4 — Themes + mode-reactive colour ✅ (done)

The signature lualine experience: the bar recolours by mode (most visibly section A and
the powerline edges). Landed as `themes.lua` + the theme-group / transition-group surface
in `highlights.lua` + the mode-reactive render & `ModeChanged` wiring in `compile.lua`,
with `test/theme_spec.lua`. **38 tests pass.** The **section powerline arrows moved here
from Phase 3** (their two colours ARE the adjacent sections' theme backgrounds) and ship
in this phase too.

Notes from the build:
- **`themes.lua`** ✅ — `resolve(theme)`: a table is used as-is; `"auto"` derives from the
  colorscheme via `nx.hl.get` (section-A accent per mode from `Function`/`String`/… , b/c
  from `StatusLine`/`Normal`, every read with a fallback so it never yields a nil cell); a
  name resolves **bundled (`default`) → `require("lualine.themes.<name>")` → hard error**.
  `normalize` fills **x/y/z from c/b/a** and **any unspecified mode from `normal`**, and a
  cell may be a `{fg,bg,gui}` table **or a string group to link to**. `mode_of(code)` maps
  `n→normal`, `i→insert`, `v`/`V`/`<C-v>→visual`, `R→replace`, `c→command`, `t→terminal`,
  else `normal`. `register(name, table)` (public `register_theme`).
- **`highlights.define_theme(palette)`** ✅ — predefines `lualine_<section>_<mode>` for
  every (section, mode) up front (lualine's own names, so a colorscheme/user override of
  those groups applies); `section_group`/`transition_group` pick by the current mode at
  render. The transition group paints the powerline arrow `fg = from-section bg`, `bg =
  to-section bg` (lazily defined + cached). Nothing on the hot path but a name lookup.
- **Mode-reactive render** ✅ — each section reads `nx.mode()`, maps it through `mode_of`,
  and paints its nil-highlight cells in `lualine_<section>_<mode>`; a component with its
  own `color`/per-severity `hl` keeps it (opts out). The powerline arrow is appended (left
  half, into the next present section / fill) or prepended (right half, from the previous /
  fill), so the chevrons point outward from the centre. A section that renders empty this
  frame emits nothing (no stray arrows).
- **The driver** ✅ — `ModeChanged` is folded into every section's event union (reusing
  `nx.statusline`'s idempotent per-segment autocmd wiring), so all sections recolour on a
  mode transition; the groups are pre-defined, so the re-render is just a group pick.
- **Observability** — the status mirror carries text only, so a `compile._last` seam
  records the cells each segment last emitted; the mode-flip test reads cell `hl` there.

(For reference, the original step list:)

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

## Phase 5 — Inactive windows, conditions, clicks, refresh, globalstatus ✅ (done)

Landed in `compile.lua` (the per-component pipeline + the focus-aware render + the click
registry + the refresh timer), with `test/runtime_spec.lua`. **44 tests pass.**

- **Inactive statusline** ✅ — each section segment now captures BOTH its `sections` and
  `inactive_sections` component lists; `render` picks by `ctx.focused` — a focused window
  draws the active layout in its mode group with the powerline arrows, an unfocused window
  draws `inactive_sections` flat (no arrows) in `lualine_<section>_inactive`. The half's
  segment set is the UNION of active+inactive present sections (a section only in
  `inactive_sections` renders empty when focused); the arrow adjacency is over the active
  layout. The theme's `inactive` palette (Phase 4) supplies the dim groups.
- **`cond` / `fmt`** ✅ — the component pipeline is `cond(ctx)` gate → `provide` →
  `fmt(str, ctx)` (operates on the joined text, collapsing to one cell; nil/`""` hides) →
  `icon` → `color` → `on_click`. A callback error becomes a loud `E:<name>` cell.
- **`on_click`** ✅ — a per-component `on_click = function(clicks, button, mods)` is
  assigned a build-time id (`compile._clicks`); the cell carries
  `v:lua.require'nxvim-line.compile'._click(id)`, and `_click` adapts neovim's
  `(minwid, clicks, button, mods)` to lualine's signature. (A fix this surfaced: cell
  padding must mutate `text` in place, not rebuild the cell, or it drops `on_click`.)
- **`refresh`** ✅ — `options.refresh = { statusline = ms }` arms a re-arming one-shot
  `nx.timer` (default 1000ms) that invalidates every active segment each interval; a
  generation token makes a rebuild supersede the prior loop, and `ms ≤ 0` disables it.
  Mode colour is event-driven (`ModeChanged`), so the timer stays coarse with no lag.
- **`globalstatus`** ✅ (since Phase 1) — `true` → `laststatus = 3`; inactive layouts
  therefore only show under `laststatus = 2` (per-window bars), as in lualine.
- **Tests** (`test/runtime_spec.lua`) ✅ — `globalstatus` flips `laststatus`; `cond=false`
  hides a component; `fmt` transforms the text; `on_click` fires through the native click
  bridge; a split's unfocused window paints `inactive_sections` in `lualine_a_inactive`
  while the focused one keeps `lualine_a_normal`; the refresh timer re-renders a counter
  component repeatedly. Per-window highlights are read off the `compile._last_win` seam.

**Honest scope:** the lualine **inline function component** (`{ function() … end }` in a
section) stays deferred — it errors loud (config.lua) rather than rendering. `cond`/`fmt`/
`on_click` are the function-VALUED component options, which are supported; an inline
function as the component *itself* is the separate feature still to come.

## Phase 6 — Git polish (`git.lua`) ✅ (done)

The async `git.lua` source **landed in Phase 2** (branch + per-file diff via `nx.run`,
cached per file, invalidating only the hosting segments; non-repo buffers show nothing).
This phase added the robustness — the "editor must never freeze" rule applied to a slow
repo. **46 tests pass.**

- **Debounce** ✅ — every event/watch trigger goes through `schedule(buf)`, a per-key
  debounce (`debounce_ms = 120`): a burst of writes (or `.git` change events) restarts the
  timer and collapses to a single git run. The cache-miss FIRST paint (`ensure`) still
  runs immediately so the bar isn't blank, and skips when a debounced refresh is pending.
- **Bounded runner** ✅ — at most `_max = 4` git fetches run at once; the rest queue
  (deduped by key) and `pump` as slots free, so opening many buffers never spawns an
  unbounded pile of `git` processes. A key already inflight is a no-op.
- **A `.git` watch** ✅ — on a successful fetch, a **best-effort** (pcall'd, after the data
  is published so it can never starve the invalidation) `nx.fs.watch` on the repo's
  `--absolute-git-dir` is armed once per git-dir; an external HEAD/index change (commit,
  checkout, stage) schedules a debounced refresh of the visible bar. Our own git reads
  never write `.git`, so the watch can't self-trigger.
- **Tests** (`components_spec`) ✅ — a burst of `schedule()` calls collapses to one
  `git._stats.runs` increment; a non-repo buffer caches an empty result (nil branch) with
  no error and the `branch` component renders nothing.

**Honest scope:** `--numstat`/`--shortstat` and richer comparisons (a rev / the index) are
left as future options — the `-U0` hunk parse is sufficient for working-tree-vs-HEAD, the
one comparison the `diff` component exposes today.

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

- **`fileformat` / `searchcount` components** — deferred pending core primitives: a
  `'fileformat'` option (unix/dos/mac) and a search-count state surface (last pattern +
  match count). Registered as *deferred* so naming one errors loud with the reason; each
  is a follow-up gated on a small core addition.
- **Winbar** — needs a `'winbar'` option in nxvim-core (a separate core dependency).
- **Tabline beyond `%`-format lowering** — clickable per-tab segment regions on the
  tabline track the core's tabline `%@…@` work, not this plugin.
- **A native built-in `git`/`lsp_progress` segment** — these are plugin components by
  design (the core ships them only as custom-segment examples).
