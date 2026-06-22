-- Runnable demo for nxvim-line.
--
--     NXVIM_CONFIG=examples nxvim examples/sample.lua
--
-- Phases 1-2 are implemented: the config + the lualine->nx.statusline compiler + the
-- component library (mode, branch, diff, diagnostics, filename, filetype, encoding,
-- lsp, progress, location). Styling (separators, icons, per-mode theme colour) lands
-- in later phases — see docs/plans/2026-06-21-nxvim-line.md. TRY IT: open a file in a
-- git repo (branch + diff show), switch modes (i / v / :), and move the cursor.

-- Load the plugin straight from this repo (a local-dev spec: `dir` is never cloned).
-- A real config would instead use `{ "davidrios/nxvim-line", config = ... }` + :PluginSync.
nx.plugins({
  {
    name = "nxvim-line",
    dir = vim.fn.expand("<sfile>:p:h:h"), -- the repo root (this file's grandparent dir)
    config = function()
      require("nxvim-line").setup({
        sections = {
          lualine_a = { "mode" },
          lualine_b = { "branch", "diff", "diagnostics" },
          lualine_c = { { "filename", path = 1 } },
          lualine_x = { "encoding", "filetype" },
          lualine_y = { "progress" },
          lualine_z = { "location" },
        },
      })
    end,
  },
})
