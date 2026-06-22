# nxvim-line

A fully-featured, **lualine-style** statusline for [nxvim](https://github.com/davidrios/nxvim).

Configure it the way you'd configure `lualine.nvim` — sections `a`–`z`, a rich component
library (mode, branch, diff, diagnostics, filename, filetype + icons, fileformat,
encoding, progress, location, LSP), themes that recolour by mode, and powerline
separators:

```lua
require("nxvim-line").setup({
  options = { theme = "auto" },
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

> **Status: Phases 1–2 landed** ([plan](docs/plans/2026-06-21-nxvim-line.md)). `setup()`
> works: the config model + the lualine→`nx.statusline` compiler, and the component
> library — `mode`, `branch`, `diff`, `diagnostics`, `filename` (path modes + `[+]`/`[-]`
> flags), `filetype`, `encoding`, `lsp`, `progress`, `location`. `diff`/`diagnostics`
> already colour with the editor's `Diff*`/`Diagnostic*` groups; `branch`/`diff` are
> driven by an async `git` source. Still to come: separators + icons (Phase 3), per-mode
> theme colour (Phase 4). `fileformat` and `searchcount` are **deferred** — they need
> editor primitives that don't exist yet, so naming them errors loud with the reason.

## How it works

nxvim-line is a **compiler, not a renderer**. The editor already owns statusline
rendering through the native `nx.statusline` segment registry: built-in segments
(`mode`, `location`, `diagnostics`, …) resolve in Rust every frame, and custom Lua
segments run their `render` **only when invalidated** by a declared event — never per
frame (ADR 0002). nxvim-line takes the lualine-shaped config and **lowers** it onto that
primitive: it registers one custom segment per section, defines the highlight groups for
the theme, and wires each component's invalidation events. The hot path stays in Rust;
your config stays familiar.

## Install

Declare it with the built-in `:Plugins` manager in your `init.lua`:

```lua
nx.plugins({
  {
    "davidrios/nxvim-line",
    config = function()
      require("nxvim-line").setup({ options = { theme = "auto" } })
    end,
  },
})
```

Then run `:PluginSync` to clone it.

## Configuration

The config mirrors lualine's shape:

```lua
require("nxvim-line").setup({
  options = {
    theme = "auto",                          -- name | table | "auto" (derive from colorscheme)
    globalstatus = false,                    -- one bottom bar (laststatus = 3)
    section_separators = { left = "", right = "" },
    component_separators = { left = "", right = "" },
    disabled_filetypes = { statusline = { "nxvim-tree" } },
    refresh = { statusline = 1000 },         -- ms; time-varying sections
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
  extensions = { "nxvim-tree", "quickfix" },
})
```

A component is a string or a table with per-component options (the lualine spelling):

```lua
sections = {
  lualine_c = {
    { "filename", path = 1, icon = "" },          -- relative path + an icon
    { "diagnostics", sources = { "nvim_lsp" } },
  },
  lualine_x = {
    { "filetype", colored = true },
    { function() return os.date("%H:%M") end, cond = function() return true end },
  },
}
```

Every component table accepts `icon`, `color`, `separator`, `cond`, `fmt`, and
`on_click`, plus component-specific keys.

## Components

| Component     | Shows                                                        |
| ------------- | ----------------------------------------------------------- |
| `mode`        | the current mode (and drives the mode-reactive theme colour) |
| `branch`      | the current git branch                                       |
| `diff`        | added / changed / removed line counts vs HEAD               |
| `diagnostics` | per-severity LSP diagnostic counts, with icons              |
| `filename`    | file name (tail / relative / absolute) + `[+]`/`[-]`/`[RO]` |
| `filetype`    | the filetype, with a devicon                                 |
| `fileformat`  | unix / dos / mac                                            |
| `encoding`    | the file encoding                                           |
| `progress`    | `Top` / `Bot` / `NN%` through the file                       |
| `location`    | `line:col`                                                  |
| `lsp`         | attached LSP client names                                   |
| `fileformat`  | unix / dos / mac — **deferred** (needs a core option)        |
| `searchcount` | `[n/N]` — **deferred** (needs core search-count state)       |

## Themes

`options.theme` takes a theme table (lualine's `{ normal = { a, b, c }, insert, visual,
… }` shape), a theme **name**, or `"auto"`. A name resolves the way lualine resolves one
— a bundled theme first, otherwise `require("lualine.themes.<name>")` — so a colorscheme
that ships a lualine theme drops in unchanged:

```lua
require("nxvim-line").setup({ options = { theme = "catppuccin" } })  -- catppuccin's own lualine theme
```

`"auto"` instead derives a palette from your active colorscheme, tracking whatever you've
loaded with no per-scheme wiring. Register your own with
`require("nxvim-line").register_theme(name, table)`.

Internally the theme is applied as the highlight groups lualine itself generates —
`lualine_a_normal`, `lualine_a_insert`, `lualine_c_inactive`, … — so a colorscheme or a
config that already styles those groups, and a component `color = "SomeHlGroup"`, all
work as they do under lualine.

## Extending

```lua
local line = require("nxvim-line")

-- A custom component: `provide(ctx)` returns the cell; `events` invalidate it.
line.register_component("clock", {
  events = {},
  provide = function(ctx) return { text = os.date("%H:%M"), icon = "" } end,
})

-- A custom theme.
line.register_theme("mine", {
  normal = { a = { fg = "#1e1e2e", bg = "#89b4fa" }, b = {...}, c = {...} },
  insert = { a = { fg = "#1e1e2e", bg = "#a6e3a1" } },
  -- visual / replace / command / inactive …
})
```

## Tests

This plugin carries a Lua test suite (`test/*_spec.lua`) on nxvim's native `nx.test`
framework. Run it headlessly:

```sh
nxvim --test-plugin .
```

## License

MIT © David Rios
