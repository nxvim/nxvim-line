-- Runnable demo for nxvim-line.
--
--     NXVIM_CONFIG=examples nxvim examples/sample.lua
--
-- Phase 1 is implemented: the config + the lualine->nx.statusline compiler + the
-- mode / filename / filetype / diagnostics / progress / location components. Styling
-- (separators, icons, per-mode theme colour) lands in later phases — see
-- docs/plans/2026-06-21-nxvim-line.md. TRY IT: switch modes (i / v / :) and move the
-- cursor (j/k, G) and watch the statusline's mode + location update.

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
          lualine_b = { "diagnostics" },
          lualine_c = { "filename" },
          lualine_x = { "filetype" },
          lualine_y = { "progress" },
          lualine_z = { "location" },
        },
      })
    end,
  },
})
