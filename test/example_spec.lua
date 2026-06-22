-- The full example config (examples/init.lua) must set up and render end-to-end — every
-- component, both layouts, a theme, extensions, and a tabline together. This guards the
-- runnable example against drift (the example-config convention).
--
--     nxvim --test-plugin ~/work/nxvim-plugins/nxvim-line

local line = require("nxvim-line")

nx.test.describe("nxvim-line.example", function()
  nx.test.it("the full lualine-style config renders", function(t)
    line.setup({
      options = { theme = "auto", globalstatus = true },
      sections = {
        lualine_a = { "mode" },
        lualine_b = { "branch", "diff", "diagnostics" },
        lualine_c = { { "filename", path = 1 } },
        lualine_x = { "encoding", "filetype" },
        lualine_y = { "progress" },
        lualine_z = { "location" },
      },
      inactive_sections = {
        lualine_c = { { "filename", path = 1 } },
        lualine_x = { "location" },
      },
      extensions = { "nxvim-tree", "quickfix" },
      tabline = { lualine_a = { { "label", text = "nxvim-line" } } },
    })
    t:feed("<Esc>")
    local sl = t:wait_for(function()
      local s = t:statusline()
      return s:find("NORMAL") and s:find("1:1") and s
    end)
    nx.test.expect(sl).to_contain("NORMAL") -- section A (mode)
    nx.test.expect(sl).to_contain("1:1") -- section Z (location)
    nx.test.expect(sl).never.to_contain("E:") -- no component errored
  end)
end)
