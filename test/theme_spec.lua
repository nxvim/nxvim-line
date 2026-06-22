-- Phase 4 — themes + mode-reactive colour. The signature lualine experience: the bar
-- recolours by mode. The status mirror carries text only, so the mode-flip is observed
-- through `compile._last` (the cells each segment last emitted) and the generated
-- `lualine_<section>_<mode>` groups through `nx.hl`. Pure helpers (mode resolver, palette
-- normalize, theme resolution) are exercised directly.
--
--     nxvim --test-plugin ~/work/nxvim-plugins/nxvim-line

local line = require("nxvim-line")
local themes = require("nxvim-line.themes")
local compile = require("nxvim-line.compile")

local function nudge(t)
  t:feed("<Esc>")
end

nx.test.describe("nxvim-line.themes (pure)", function()
  nx.test.it("maps every mode code to its theme key", function()
    local cases = {
      n = "normal",
      i = "insert",
      v = "visual",
      V = "visual",
      R = "replace",
      c = "command",
      t = "terminal",
    }
    for code, want in pairs(cases) do
      nx.test.expect(themes.mode_of(code)).to_be(want)
    end
    nx.test.expect(themes.mode_of("?")).to_be("normal") -- unknown → normal
  end)

  nx.test.it("normalize fills x/y/z from c/b/a and missing modes from normal", function()
    local norm = themes.normalize({
      normal = { a = { bg = "#111111" }, b = { bg = "#222222" }, c = { bg = "#333333" } },
      insert = { a = { bg = "#444444" } },
    })
    -- x/y/z default to c/b/a
    nx.test.expect(norm.normal.x.bg).to_be("#333333")
    nx.test.expect(norm.normal.y.bg).to_be("#222222")
    nx.test.expect(norm.normal.z.bg).to_be("#111111")
    -- an unspecified mode (visual) inherits normal wholesale
    nx.test.expect(norm.visual.a.bg).to_be("#111111")
    -- insert overrode only `a`; b/c fall back to normal's
    nx.test.expect(norm.insert.a.bg).to_be("#444444")
    nx.test.expect(norm.insert.b.bg).to_be("#222222")
  end)

  nx.test.it("resolve errors loud on an unknown theme name", function()
    nx.test
      .expect(function()
        themes.resolve("definitely-not-a-theme")
      end)
      .to_error("unknown theme")
  end)
end)

nx.test.describe("nxvim-line.theme", function()
  nx.test.it("a theme table colours the sections under lualine_<sec>_<mode> names", function(t)
    line.setup({
      options = {
        globalstatus = true,
        theme = {
          normal = { a = { fg = "#000000", bg = "#112233" }, b = {}, c = {} },
          insert = { a = { bg = "#445566" } },
        },
      },
      sections = { lualine_a = { "mode" } },
    })
    nudge(t)
    t:wait_for(function()
      return t:statusline():find("NORMAL") and nx.hl.exists("lualine_a_normal") == 1
    end)
    nx.test.expect(nx.hl.get(0, { name = "lualine_a_normal" }).bg).to_be(0x112233)
    nx.test.expect(nx.hl.get(0, { name = "lualine_a_insert" }).bg).to_be(0x445566)
  end)

  nx.test.it("a name resolves through require('lualine.themes.<name>')", function(t)
    -- A lualine theme module on the runtimepath (here, preloaded) resolves unchanged.
    package.loaded["lualine.themes.nxlfake"] = {
      normal = { a = { fg = "#0a0a0a", bg = "#abcabc" }, b = {}, c = {} },
    }
    line.setup({
      options = { globalstatus = true, theme = "nxlfake" },
      sections = { lualine_a = { "mode" } },
    })
    nudge(t)
    t:wait_for(function()
      return t:statusline():find("NORMAL") and nx.hl.exists("lualine_a_normal") == 1
    end)
    nx.test.expect(nx.hl.get(0, { name = "lualine_a_normal" }).bg).to_be(0xabcabc)
    package.loaded["lualine.themes.nxlfake"] = nil
  end)

  nx.test.it("auto derives non-nil groups from the active colorscheme", function(t)
    nx.hl.define(0, "Normal", { fg = "#cccccc", bg = "#202020" })
    nx.hl.define(0, "Function", { fg = "#5599ff" })
    line.setup({
      options = { globalstatus = true, theme = "auto" },
      sections = { lualine_a = { "mode" } },
    })
    nudge(t)
    t:wait_for(function()
      return t:statusline():find("NORMAL") and nx.hl.exists("lualine_a_normal") == 1
    end)
    -- section A's accent is derived from Function's fg
    nx.test.expect(nx.hl.get(0, { name = "lualine_a_normal" }).bg).to_be(0x5599ff)
  end)

  nx.test.it("recolours section A by mode via ModeChanged", function(t)
    line.setup({
      options = { globalstatus = true, theme = "default" },
      sections = { lualine_a = { "mode" } },
    })
    nudge(t)
    t:wait_for(function()
      return t:statusline():find("NORMAL")
    end)
    local function mode_hl()
      local cells = compile._last.NxLineA
      return cells and cells[1] and cells[1].hl
    end
    nx.test.expect(mode_hl()).to_be("lualine_a_normal")

    t:feed("i")
    t:wait_for(function()
      return t:statusline():find("INSERT")
    end)
    nx.test.expect(mode_hl()).to_be("lualine_a_insert")

    t:feed("<Esc>")
    t:wait_for(function()
      return t:statusline():find("NORMAL")
    end)
    nx.test.expect(mode_hl()).to_be("lualine_a_normal")

    t:feed("v")
    t:wait_for(function()
      return t:statusline():find("VISUAL")
    end)
    nx.test.expect(mode_hl()).to_be("lualine_a_visual")
    t:feed("<Esc>")
  end)
end)
