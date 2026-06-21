-- Runnable demo for nxvim-line.
--
--     NXVIM_CONFIG=examples nxvim examples/sample.lua
--
-- NOTE: nxvim-line is currently scaffolding — `setup()` errors loud until Phase 1 of
-- docs/plans/2026-06-21-nxvim-line.md lands. This demo is the target config; it will
-- light up the statusline once the compiler is wired.

-- Load the plugin straight from this repo (a local-dev spec: `dir` is never cloned).
-- A real config would instead use `{ "davidrios/nxvim-line", config = ... }` + :PluginSync.
nx.plugins({
  {
    name = "nxvim-line",
    dir = vim.fn.expand("<sfile>:p:h:h"), -- the repo root (this file's grandparent dir)
    config = function()
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
    end,
  },
})
