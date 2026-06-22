-- Runnable demo for nxvim-line.
--
--     NXVIM_CONFIG=examples nxvim examples/sample.lua
--
-- Phases 1-4 are implemented: the config + the lualine->nx.statusline compiler + the
-- component library (mode, branch, diff, diagnostics, filename, filetype, encoding,
-- lsp, progress, location) + the lualine LOOK — Nerd-Font icons, separators,
-- per-component colour/padding, AND mode-reactive theme colour (the bar recolours by
-- mode; `theme = "auto"` derives from your colorscheme). See
-- docs/plans/2026-06-21-nxvim-line.md. TRY IT: open a file in a git repo (branch + diff
-- show, with a  glyph), switch modes (i / v / :) and watch section A + the powerline
-- edges recolour, and move the cursor.

-- Load the plugin straight from this repo (a local-dev spec: `dir` is never cloned).
-- A real config would instead use `{ "davidrios/nxvim-line", config = ... }` + :PluginSync.
nx.plugins({
  {
    name = "nxvim-line",
    dir = vim.fn.expand("<sfile>:p:h:h"), -- the repo root (this file's grandparent dir)
    config = function()
      require("nxvim-line").setup({
        options = { theme = "auto" }, -- derive the palette from the active colorscheme
        sections = {
          lualine_a = { "mode" },
          lualine_b = { "branch", "diff", "diagnostics" },
          lualine_c = { { "filename", path = 1 } },
          lualine_x = { "encoding", "filetype" },
          lualine_y = { "progress" },
          lualine_z = { "location" },
        },
        -- non-focused windows get a dim, flat bar (split with <C-w>s to see it)
        inactive_sections = {
          lualine_c = { { "filename", path = 1 } },
          lualine_x = { "location" },
        },
        -- per-filetype layout overrides (the tree shows a title, qf a label)
        extensions = { "nxvim-tree", "quickfix" },
      })
    end,
  },
})
