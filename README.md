# bemtvi-line

A fully-featured, **lualine-style** statusline for [bemtvi](https://github.com/bemtvi/bemtvi).

Configure it the way you'd configure `lualine.nvim` — sections `a`–`z`, a rich component
library (mode, branch, diff, diagnostics, filename, filetype + icons, fileformat,
encoding, progress, location, LSP clients + their `$/progress` status, searchcount,
daemon), themes that recolour by mode, and
powerline separators:

```lua
require("bemtvi-line").setup({
  options = { theme = "auto" },
  sections = {
    lualine_a = { "mode" },
    lualine_b = { "branch", "diff", "diagnostics" },
    lualine_c = { "filename" },
    lualine_x = { "lsp", "encoding", "fileformat", "filetype" },
    lualine_y = { "progress" },
    lualine_z = { "location" },
  },
})
```

bemtvi-line is a **compiler, not a renderer**. The editor already owns statusline
rendering through the native `btv.statusline` segment registry — built-in segments resolve
in Rust every frame, and custom Lua segments run only when invalidated by a declared event,
never per frame (ADR 0002). bemtvi-line **lowers** a lualine-shaped config onto that
primitive: one custom segment per section, the theme's highlight groups, and each
component's invalidation events. The hot path stays in Rust; your config stays familiar.

## Install

Declare it with the built-in `:Plugins` manager, then `:PluginSync`:

```lua
btv.plugins({
  {
    "bemtvi/bemtvi-line",
    config = function()
      require("bemtvi-line").setup({ options = { theme = "auto" } })
    end,
  },
})
```

## Documentation

Full docs — `setup()`, every option, the section model, the component library and
per-component options, themes, highlight groups, extensions, the tabline, the `register_*`
API, and writing a custom component — live in the help file. The same source renders both
on GitHub and in the editor:

- In editor: `:help bemtvi-line`
- On GitHub: [doc/bemtvi-line.md](./doc/bemtvi-line.md) (the help source)

## Development

A Lua test suite (`test/*_spec.lua`) runs on bemtvi's native `btv.test` framework:

```sh
bemtvi --test-plugin .
```

The vimdoc `doc/bemtvi-line.txt` is **generated** from `doc/bemtvi-line.md` via
[panvimdoc](https://github.com/kdheepak/panvimdoc): edit the `.md`, then run
`bash scripts/gen-vimdoc.sh` (needs `pandoc` + `git`). Never edit the `.txt` by hand.

## License

MIT © David Rios
