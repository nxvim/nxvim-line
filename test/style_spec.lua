-- Phase 3 — separators, icons, and per-component styling. The status mirror carries
-- TEXT only (`t:statusline()`), so glyphs / separators / padding are observed in the
-- rendered text, and a per-component `color` is observed through the highlight group it
-- defines (`btv.hl`). Pure helpers (icons / colour interning) are exercised directly.
--
--     bemtvi --test-plugin ~/work/bemtvi-plugins/bemtvi-line

local line = require("bemtvi-line")
local icons = require("bemtvi-line.icons")
local highlights = require("bemtvi-line.highlights")

local COMP_SEP_LEFT = "\u{e0b1}" -- the default left-half component separator glyph

local function nudge(t)
  t:feed("<Esc>")
end

btv.test.describe("bemtvi-line.icons", function()
  btv.test.it("resolves by extension and exact name, with a default fallback", function()
    icons.configure({ enabled = true })
    btv.test.expect(icons.for_name("/x/init.lua")).to_be(icons._by_ext.lua)
    btv.test.expect(icons.for_name("Cargo.toml")).to_be(icons._by_name["Cargo.toml"])
    -- an unknown extension still gets the default file glyph (never nil when enabled)
    btv.test.expect(icons.for_name("mystery.zzz")).never.to_be_nil()
  end)

  btv.test.it("returns nil for every lookup when icons are disabled", function()
    icons.configure({ enabled = false })
    btv.test.expect(icons.for_name("init.lua")).to_be_nil()
    icons.configure({ enabled = true }) -- restore for later tests
  end)

  btv.test.it("a provider hook overrides the built-in tables", function()
    icons.configure({
      enabled = true,
      provider = function()
        return "PV"
      end,
    })
    btv.test.expect(icons.for_name("init.lua")).to_be("PV")
    icons.configure({ enabled = true }) -- drop the provider
  end)

  btv.test.it("register() extends the registry", function()
    icons.register({ zzz = "Z", name = { ["My.special"] = "S" } })
    btv.test.expect(icons.for_name("a.zzz")).to_be("Z")
    btv.test.expect(icons.for_name("My.special")).to_be("S")
  end)
end)

btv.test.describe("bemtvi-line.highlights", function()
  btv.test.it("interns a colour table into a defined group, cached by value", function()
    highlights.reset()
    local g = highlights.color_group({ fg = "#ff0000", gui = "bold" })
    btv.test.expect(g).to_be("BtvLineColor1")
    btv.test.expect(btv.hl.exists(g)).to_be(true) -- btv.hl.exists answers a boolean
    local def = btv.hl.get(0, { name = g })
    btv.test.expect(def.fg).to_be(0xff0000)
    btv.test.expect(def.bold).to_be(true)
    -- the same colour returns the cached group (no new BtvLineColor2)
    btv.test.expect(highlights.color_group({ fg = "#ff0000", gui = "bold" })).to_be("BtvLineColor1")
    -- a different colour gets a fresh group
    btv.test.expect(highlights.color_group({ fg = "#00ff00" })).to_be("BtvLineColor2")
  end)

  btv.test.it("passes a string colour through as a group link", function()
    btv.test.expect(highlights.color_group("WarningMsg")).to_be("WarningMsg")
  end)
end)

btv.test.describe("bemtvi-line.style", function()
  btv.test.it("puts a component separator glyph between two components", function(t)
    line.setup({
      options = { globalstatus = true },
      sections = { lualine_c = { "mode", "location" } },
    })
    nudge(t)
    local sl = t:wait_for(function()
      local s = t:statusline()
      return s:find("NORMAL") and s:find("1:1") and s
    end)
    btv.test.expect(sl).to_contain(COMP_SEP_LEFT)
  end)

  btv.test.it("an empty component separator degrades cleanly", function(t)
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
    btv.test.expect(sl).to_contain("NORMAL")
    btv.test.expect(sl).to_contain("1:1")
    btv.test.expect(sl).never.to_contain(COMP_SEP_LEFT)
  end)

  btv.test.it("per-component padding widens the cell", function(t)
    line.setup({
      options = { globalstatus = true },
      sections = { lualine_c = { { "mode", padding = { left = 4, right = 0 } } } },
    })
    nudge(t)
    local sl = t:wait_for(function()
      local s = t:statusline()
      return s:find("    NORMAL") and s -- four leading spaces (default is one)
    end)
    btv.test.expect(sl).to_contain("    NORMAL")
  end)

  btv.test.it("a per-component colour table defines + applies a group", function(t)
    line.setup({
      options = { globalstatus = true },
      sections = { lualine_c = { { "mode", color = { fg = "#abcdef", gui = "italic" } } } },
    })
    nudge(t)
    -- rendering the section calls color_group, which defines BtvLineColor1 (counter was
    -- reset by build()); its presence proves the colour was applied to the cell.
    t:wait_for(function()
      return t:statusline():find("NORMAL") and btv.hl.exists("BtvLineColor1")
    end)
    local def = btv.hl.get(0, { name = "BtvLineColor1" })
    btv.test.expect(def.fg).to_be(0xabcdef)
    btv.test.expect(def.italic).to_be(true)
  end)
end)
