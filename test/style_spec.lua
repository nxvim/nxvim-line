-- Phase 3 — separators, icons, and per-component styling. The status mirror carries
-- TEXT only (`t:statusline()`), so glyphs / separators / padding are observed in the
-- rendered text, and a per-component `color` is observed through the highlight group it
-- defines (`nx.hl`). Pure helpers (icons / colour interning) are exercised directly.
--
--     nxvim --test-plugin ~/work/nxvim-plugins/nxvim-line

local line = require("nxvim-line")
local icons = require("nxvim-line.icons")
local highlights = require("nxvim-line.highlights")

local COMP_SEP_LEFT = "\u{e0b1}" -- the default left-half component separator glyph

local function nudge(t)
  t:feed("<Esc>")
end

nx.test.describe("nxvim-line.icons", function()
  nx.test.it("resolves by extension and exact name, with a default fallback", function()
    icons.configure({ enabled = true })
    nx.test.expect(icons.for_name("/x/init.lua")).to_be(icons._by_ext.lua)
    nx.test.expect(icons.for_name("Cargo.toml")).to_be(icons._by_name["Cargo.toml"])
    -- an unknown extension still gets the default file glyph (never nil when enabled)
    nx.test.expect(icons.for_name("mystery.zzz")).never.to_be_nil()
  end)

  nx.test.it("returns nil for every lookup when icons are disabled", function()
    icons.configure({ enabled = false })
    nx.test.expect(icons.for_name("init.lua")).to_be_nil()
    icons.configure({ enabled = true }) -- restore for later tests
  end)

  nx.test.it("a provider hook overrides the built-in tables", function()
    icons.configure({
      enabled = true,
      provider = function()
        return "PV"
      end,
    })
    nx.test.expect(icons.for_name("init.lua")).to_be("PV")
    icons.configure({ enabled = true }) -- drop the provider
  end)

  nx.test.it("register() extends the registry", function()
    icons.register({ zzz = "Z", name = { ["My.special"] = "S" } })
    nx.test.expect(icons.for_name("a.zzz")).to_be("Z")
    nx.test.expect(icons.for_name("My.special")).to_be("S")
  end)
end)

nx.test.describe("nxvim-line.highlights", function()
  nx.test.it("interns a colour table into a defined group, cached by value", function()
    highlights.reset()
    local g = highlights.color_group({ fg = "#ff0000", gui = "bold" })
    nx.test.expect(g).to_be("NxLineColor1")
    nx.test.expect(nx.hl.exists(g)).to_be(true) -- nx.hl.exists answers a boolean
    local def = nx.hl.get(0, { name = g })
    nx.test.expect(def.fg).to_be(0xff0000)
    nx.test.expect(def.bold).to_be(true)
    -- the same colour returns the cached group (no new NxLineColor2)
    nx.test.expect(highlights.color_group({ fg = "#ff0000", gui = "bold" })).to_be("NxLineColor1")
    -- a different colour gets a fresh group
    nx.test.expect(highlights.color_group({ fg = "#00ff00" })).to_be("NxLineColor2")
  end)

  nx.test.it("passes a string colour through as a group link", function()
    nx.test.expect(highlights.color_group("WarningMsg")).to_be("WarningMsg")
  end)
end)

nx.test.describe("nxvim-line.style", function()
  nx.test.it("puts a component separator glyph between two components", function(t)
    line.setup({
      options = { globalstatus = true },
      sections = { lualine_c = { "mode", "location" } },
    })
    nudge(t)
    local sl = t:wait_for(function()
      local s = t:statusline()
      return s:find("NORMAL") and s:find("1:1") and s
    end)
    nx.test.expect(sl).to_contain(COMP_SEP_LEFT)
  end)

  nx.test.it("an empty component separator degrades cleanly", function(t)
    line.setup({
      options = { globalstatus = true, component_separators = "" },
      sections = { lualine_c = { "mode", "location" } },
    })
    nudge(t)
    local sl = t:wait_for(function()
      local s = t:statusline()
      return s:find("NORMAL") and s:find("1:1") and s
    end)
    -- both components still render, with no separator glyph
    nx.test.expect(sl).to_contain("NORMAL")
    nx.test.expect(sl).to_contain("1:1")
    nx.test.expect(sl).never.to_contain(COMP_SEP_LEFT)
  end)

  nx.test.it("per-component padding widens the cell", function(t)
    line.setup({
      options = { globalstatus = true },
      sections = { lualine_c = { { "mode", padding = { left = 4, right = 0 } } } },
    })
    nudge(t)
    local sl = t:wait_for(function()
      local s = t:statusline()
      return s:find("    NORMAL") and s -- four leading spaces (default is one)
    end)
    nx.test.expect(sl).to_contain("    NORMAL")
  end)

  nx.test.it("a per-component colour table defines + applies a group", function(t)
    line.setup({
      options = { globalstatus = true },
      sections = { lualine_c = { { "mode", color = { fg = "#abcdef", gui = "italic" } } } },
    })
    nudge(t)
    -- rendering the section calls color_group, which defines NxLineColor1 (counter was
    -- reset by build()); its presence proves the colour was applied to the cell.
    t:wait_for(function()
      return t:statusline():find("NORMAL") and nx.hl.exists("NxLineColor1")
    end)
    local def = nx.hl.get(0, { name = "NxLineColor1" })
    nx.test.expect(def.fg).to_be(0xabcdef)
    nx.test.expect(def.italic).to_be(true)
  end)
end)
