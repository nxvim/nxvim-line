-- Runnable demo for bemtvi-line.
--
--     BEMTVI_CONFIG=examples bemtvi examples/sample.lua
--
-- The config + the lualine->btv.statusline compiler + the component library (mode,
-- branch, diff, diagnostics, filename, filetype, encoding, fileformat, lsp, progress,
-- location, searchcount, daemon, label) + the lualine LOOK — Nerd-Font icons,
-- separators, per-component colour/padding, and mode-reactive theme colour (the bar
-- recolours by mode; `theme = "auto"` derives from your colorscheme). See
-- docs/plans/2026-06-21-bemtvi-line.md.
--
-- TYPE THIS / SEE THAT:
--   * open a file in a git repo   -> section B shows the branch ( glyph) + diff counts
--   * `i` / `v` / `:` then <Esc>  -> section A relabels AND recolours, arrows follow
--   * `j` / `l`                   -> sections Y/Z (progress, line:col) update
--   * `<C-w>s`                    -> the unfocused window gets the dim, flat bar
--   * `/local<CR>` then `n` / `N` -> section Y shows searchcount's `[idx/total]`

-- Load the plugin straight from this repo (a local-dev spec: `dir` is never cloned).
-- A real config would instead use `{ "davidrios/bemtvi-line", config = ... }` + :PluginSync.
btv.plugins({
  {
    name = "bemtvi-line",
    dir = vim.fn.expand("<sfile>:p:h:h"), -- the repo root (this file's grandparent dir)
    config = function()
      require("bemtvi-line").setup({
        options = { theme = "auto" }, -- derive the palette from the active colorscheme
        sections = {
          lualine_a = { "mode" },
          lualine_b = { "branch", "diff", "diagnostics" },
          lualine_c = { { "filename", path = 1 } },
          -- `daemon` shows the remote-link health on a `:connect` session (green/yellow/red);
          -- it renders nothing on a local session, so it's safe to leave in always.
          lualine_x = { "daemon", "encoding", "fileformat", "filetype" },
          -- `searchcount` renders nothing until you search, then `[idx/total]`.
          lualine_y = { "searchcount", "progress" },
          lualine_z = { "location" },
        },
        -- non-focused windows get a dim, flat bar (split with <C-w>s to see it)
        inactive_sections = {
          lualine_c = { { "filename", path = 1 } },
          lualine_x = { "location" },
        },
        -- per-filetype layout overrides (the tree shows a title, qf a label)
        extensions = { "bemtvi-tree", "quickfix" },
      })
    end,
  },
})
