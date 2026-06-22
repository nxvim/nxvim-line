-- Phase 5 — inactive windows, cond / fmt / on_click, refresh, globalstatus. Text effects
-- are read off the status mirror; per-window highlights (the inactive bar) and the click
-- handler are read through the `compile._last_win` / `compile._click` seams.
--
--     nxvim --test-plugin ~/work/nxvim-plugins/nxvim-line

local line = require("nxvim-line")
local compile = require("nxvim-line.compile")

local function nudge(t)
  t:feed("<Esc>")
end

nx.test.describe("nxvim-line.runtime", function()
  nx.test.it("globalstatus flips 'laststatus'", function(t)
    line.setup({ options = { globalstatus = true }, sections = { lualine_a = { "mode" } } })
    nudge(t)
    nx.test.expect(vim.o.laststatus).to_be(3)
    line.setup({ options = { globalstatus = false }, sections = { lualine_a = { "mode" } } })
    nudge(t)
    nx.test.expect(vim.o.laststatus).to_be(2)
  end)

  nx.test.it("cond = false hides a component", function(t)
    line.setup({
      options = { globalstatus = true },
      sections = {
        lualine_a = {},
        lualine_c = {
          {
            "filename",
            cond = function()
              return false
            end,
          },
          "location",
        },
      },
    })
    nudge(t)
    local sl = t:wait_for(function()
      local s = t:statusline()
      return s:find("1:1") and s
    end)
    nx.test.expect(sl).to_contain("1:1") -- location renders
    nx.test.expect(sl).never.to_contain("No Name") -- the gated filename does not
  end)

  nx.test.it("fmt post-processes a component's text", function(t)
    line.setup({
      options = { globalstatus = true },
      sections = {
        lualine_a = {},
        lualine_c = {
          {
            "mode",
            fmt = function(s)
              return "X" .. s .. "Y"
            end,
          },
        },
      },
    })
    nudge(t)
    local sl = t:wait_for(function()
      local s = t:statusline()
      return s:find("XNORMALY") and s
    end)
    nx.test.expect(sl).to_contain("XNORMALY")
  end)

  nx.test.it("on_click threads a handler the click bridge fires", function(t)
    local fired = { n = 0 }
    line.setup({
      options = { globalstatus = true },
      sections = {
        lualine_c = {
          {
            "mode",
            on_click = function()
              fired.n = fired.n + 1
            end,
          },
        },
      },
    })
    nudge(t)
    t:wait_for(function()
      return t:statusline():find("NORMAL")
    end)
    -- find the clickable cell and drive the native click bridge with neovim's args
    local cell
    for _, c in ipairs(compile._last.NxLineC or {}) do
      if c.on_click then
        cell = c
        break
      end
    end
    nx.test.expect(cell).never.to_be_nil()
    nx._statusline_click(cell.on_click, 0, 1, "l", "")
    nx.test.expect(fired.n).to_be(1)
  end)

  nx.test.it("an unfocused split window renders inactive_sections", function(t)
    line.setup({
      options = { globalstatus = false },
      sections = { lualine_a = { "mode" } },
      inactive_sections = { lualine_a = { "location" } },
    })
    nudge(t)
    t:feed("<C-w>s") -- split: the original window becomes unfocused
    nudge(t)

    local cur = nx.win.current()
    local unfocused
    for _, w in ipairs(nx.win.list()) do
      if w ~= cur then
        unfocused = w
        break
      end
    end
    nx.test.expect(unfocused).never.to_be_nil()

    t:wait_for(function()
      local segs = compile._last_win[unfocused]
      local cells = segs and segs.NxLineA
      return cells and cells[1] and cells[1].hl == "lualine_a_inactive"
    end)
    -- the inactive window paints in the inactive group and shows the inactive layout
    local icells = compile._last_win[unfocused].NxLineA
    nx.test.expect(icells[1].hl).to_be("lualine_a_inactive")
    local text = ""
    for _, c in ipairs(icells) do
      text = text .. c.text
    end
    nx.test.expect(text:find("1:1")).never.to_be_nil()
    -- the focused window keeps the active (mode) layout
    nx.test.expect(compile._last_win[cur].NxLineA[1].hl).to_be("lualine_a_normal")
    t:feed("<C-w>o") -- close the split so later tests start single-window
  end)

  nx.test.it("the refresh timer re-renders time-varying sections", function(t)
    local count = { n = 0 }
    line.register_component("nxl_counter", {
      events = {},
      provide = function()
        count.n = count.n + 1
        return { text = "C" .. count.n }
      end,
    })
    line.setup({
      options = { globalstatus = true, refresh = { statusline = 20 } },
      sections = { lualine_c = { "nxl_counter" } },
    })
    nudge(t)
    -- the periodic timer keeps invalidating the section, so provide runs repeatedly
    t:wait_for(function()
      return count.n >= 4
    end)
    nx.test.expect(count.n >= 4).to_be(true)
    -- a rebuild without refresh supersedes the timer (generation bump)
    line.setup({
      options = { globalstatus = true, refresh = { statusline = 0 } },
      sections = { lualine_c = { "nxl_counter" } },
    })
    nudge(t)
  end)
end)
