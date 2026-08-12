-- Phase 4 — themes + mode-reactive colour. The signature lualine experience: the bar
-- recolours by mode. The status mirror carries text only, so the mode-flip is observed
-- through `compile._last` (the cells each segment last emitted) and the generated
-- `lualine_<section>_<mode>` groups through `btv.hl`. Pure helpers (mode resolver, palette
-- normalize, theme resolution) are exercised directly.
--
--     bemtvi --test-plugin ~/work/bemtvi-plugins/bemtvi-line

local line = require("bemtvi-line")
local themes = require("bemtvi-line.themes")
local compile = require("bemtvi-line.compile")

local function nudge(t)
  t:feed("<Esc>")
end

btv.test.describe("bemtvi-line.themes (pure)", function()
  btv.test.it("maps every mode code to its theme key", function()
    local cases = {
      n = "normal",
      i = "insert",
      v = "visual",
      V = "visual",
      R = "replace",
      c = "command",
      t = "terminal",
      -- Helix's selection-first modes (mode() reports hn/hs): normal keeps the
      -- normal palette, select (extend) reuses visual like vim's visual modes.
      hn = "normal",
      hs = "visual",
      -- vim Select mode (charwise `s` / linewise `S`) — a selection mode, so it
      -- takes the visual palette (lualine themes carry no dedicated select key).
      s = "visual",
      S = "visual",
    }
    for code, want in pairs(cases) do
      btv.test.expect(themes.mode_of(code)).to_be(want)
    end
    btv.test.expect(themes.mode_of("?")).to_be("normal") -- unknown → normal
  end)

  btv.test.it("normalize fills x/y/z from c/b/a and missing modes from normal", function()
    local norm = themes.normalize({
      normal = { a = { bg = "#111111" }, b = { bg = "#222222" }, c = { bg = "#333333" } },
      insert = { a = { bg = "#444444" } },
    })
    -- x/y/z default to c/b/a
    btv.test.expect(norm.normal.x.bg).to_be("#333333")
    btv.test.expect(norm.normal.y.bg).to_be("#222222")
    btv.test.expect(norm.normal.z.bg).to_be("#111111")
    -- an unspecified mode (visual) inherits normal wholesale
    btv.test.expect(norm.visual.a.bg).to_be("#111111")
    -- insert overrode only `a`; b/c fall back to normal's
    btv.test.expect(norm.insert.a.bg).to_be("#444444")
    btv.test.expect(norm.insert.b.bg).to_be("#222222")
  end)

  btv.test.it("resolve errors loud on an unknown theme name", function()
    btv.test
      .expect(function()
        themes.resolve("definitely-not-a-theme")
      end)
      .to_error("unknown theme")
  end)

  -- Regression: the auto palette's fill (c) and inactive sections must ride the
  -- StatusLine background, NOT Normal — otherwise the bar blends into the document
  -- (e.g. catppuccin's mantle vs base). `x` defaults to `c`, so the whole right
  -- half of the active bar follows.
  btv.test.it("auto's fill (c) and inactive sections ride the StatusLine bg, not Normal", function()
    vim.g.colors_name = "no-lualine-theme-here" -- force the synthesis fallback path
    btv.hl.define(0, "Normal", { fg = "#cdd6f4", bg = "#1e1e2e" }) -- the document bg
    btv.hl.define(0, "StatusLine", { fg = "#cdd6f4", bg = "#181825" }) -- a darker bar bg
    local pal = themes.derive_auto()
    btv.test.expect(pal.normal.c.bg).to_be("#181825")
    btv.test.expect(pal.inactive.b.bg).to_be("#181825")
    btv.test.expect(pal.inactive.c.bg).to_be("#181825")
  end)

  btv.test.it("auto prefers the active colorscheme's shipped lualine theme", function()
    -- Real lualine's `auto` loads `lualine.themes.<colors_name>` when it exists
    -- (e.g. catppuccin ships catppuccin-mocha) rather than synthesizing. Simulate a
    -- shipped theme via package.loaded and point colors_name at it.
    local shipped = {
      normal = { a = { fg = "#000000", bg = "#89b4fa" }, c = { fg = "#cdd6f4", bg = "#181825" } },
      inactive = { c = { fg = "#6c7086", bg = "#181825" } },
    }
    package.loaded["lualine.themes.faketheme"] = shipped
    local prev = vim.g.colors_name
    vim.g.colors_name = "faketheme"
    -- Even with distinct highlight groups present, the shipped theme wins.
    btv.hl.define(0, "Normal", { fg = "#ffffff", bg = "#111111" })
    btv.hl.define(0, "StatusLine", { fg = "#ffffff", bg = "#222222" })
    local pal = themes.derive_auto()
    btv.test.expect(pal.normal.a.bg).to_be("#89b4fa")
    btv.test.expect(pal.normal.c.bg).to_be("#181825")
    package.loaded["lualine.themes.faketheme"] = nil
    vim.g.colors_name = prev
  end)

  btv.test.it("auto's inactive bar uses StatusLineNC's faded foreground", function()
    vim.g.colors_name = "no-lualine-theme-here" -- force the synthesis fallback path
    btv.hl.define(0, "Normal", { fg = "#cdd6f4", bg = "#1e1e2e" })
    btv.hl.define(0, "StatusLine", { fg = "#cdd6f4", bg = "#181825" }) -- active: bright text
    btv.hl.define(0, "StatusLineNC", { fg = "#45475a", bg = "#181825" }) -- inactive: faded text
    local pal = themes.derive_auto()
    -- The inactive text is the dimmer StatusLineNC fg, not the active StatusLine fg.
    btv.test.expect(pal.inactive.c.fg).to_be("#45475a")
    btv.test.expect(pal.inactive.a.fg).to_be("#45475a")
    btv.test.expect(pal.normal.c.fg).to_be("#cdd6f4")
  end)

  -- Every mode accent comes from `btv.hl.palette()`, so under the editor's own `bemtvi`
  -- scheme the whole bar is in One Dark. The regression this guards: the accents used
  -- to read ONE group each (visual←Statement, replace←Error), and a theme that leaves
  -- that group undefined dropped those modes to a hardcoded generic magenta/red that
  -- belonged to no palette at all — which is exactly what `:colorscheme bemtvi` did.
  btv.test.it("auto derives every mode accent from the active palette", function(t)
    t:cmd("hi clear")
    t:cmd("colorscheme bemtvi")
    vim.g.colors_name = "no-lualine-theme-here" -- force the synthesis fallback path
    local pal = themes.derive_auto()
    btv.test.expect(pal.normal.a.bg).to_be("#61afef") -- One Dark blue
    btv.test.expect(pal.insert.a.bg).to_be("#98c379") -- green
    btv.test.expect(pal.visual.a.bg).to_be("#c678dd") -- purple
    btv.test.expect(pal.replace.a.bg).to_be("#e06c75") -- red
    btv.test.expect(pal.command.a.bg).to_be("#d19a66") -- orange
    btv.test.expect(pal.terminal.a.bg).to_be("#56b6c2") -- cyan
    -- The bar's own surfaces come from the StatusLine groups the scheme defines.
    btv.test.expect(pal.normal.c.bg).to_be("#21252b")
    btv.test.expect(pal.normal.a.fg).to_be("#282c34") -- text on an accent = Normal bg
    -- The inactive bar rides StatusLineNC, which the built-in scheme now defines.
    btv.test.expect(pal.inactive.c.fg).to_be("#5c6370")
    btv.test.expect(pal.inactive.c.bg).to_be("#21252b")
  end)
end)

btv.test.describe("bemtvi-line.theme", function()
  btv.test.it(
    "re-applies the theme on ColorScheme (colorscheme loads/switches after setup)",
    function(t)
      -- The colorscheme may load AFTER setup, or the user switches flavours live; the
      -- bar must re-derive on ColorScheme (real lualine does). Start on synthesis…
      vim.g.colors_name = "no-shipped-theme-x"
      btv.hl.define(0, "Normal", { fg = "#cccccc", bg = "#101010" })
      btv.hl.define(0, "StatusLine", { fg = "#cccccc", bg = "#202020" })
      line.setup({
        options = { globalstatus = true, theme = "auto" },
        sections = { lualine_a = { "mode" } },
      })
      nudge(t)
      t:wait_for(function()
        return btv.hl.exists("lualine_c_normal")
      end)
      btv.test.expect(btv.hl.get(0, { name = "lualine_c_normal" }).bg).to_be(0x202020) -- synthesized fill

      -- …then a colorscheme with a shipped lualine theme becomes active. Firing
      -- ColorScheme must re-derive and re-apply so the bar follows it.
      package.loaded["lualine.themes.shipped-x"] = {
        normal = { a = { fg = "#000000", bg = "#89b4fa" }, c = { fg = "#cdd6f4", bg = "#181825" } },
      }
      vim.g.colors_name = "shipped-x"
      btv.autocmd.exec("ColorScheme", {})
      t:wait_for(function()
        return btv.hl.get(0, { name = "lualine_c_normal" }).bg == 0x181825
      end)
      btv.test.expect(btv.hl.get(0, { name = "lualine_c_normal" }).bg).to_be(0x181825)
      package.loaded["lualine.themes.shipped-x"] = nil
    end
  )

  btv.test.it("a theme table colours the sections under lualine_<sec>_<mode> names", function(t)
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
      return t:statusline():find("NORMAL") and btv.hl.exists("lualine_a_normal")
    end)
    btv.test.expect(btv.hl.get(0, { name = "lualine_a_normal" }).bg).to_be(0x112233)
    btv.test.expect(btv.hl.get(0, { name = "lualine_a_insert" }).bg).to_be(0x445566)
  end)

  btv.test.it("a name resolves through require('lualine.themes.<name>')", function(t)
    -- A lualine theme module on the runtimepath (here, preloaded) resolves unchanged.
    package.loaded["lualine.themes.btvlfake"] = {
      normal = { a = { fg = "#0a0a0a", bg = "#abcabc" }, b = {}, c = {} },
    }
    line.setup({
      options = { globalstatus = true, theme = "btvlfake" },
      sections = { lualine_a = { "mode" } },
    })
    nudge(t)
    t:wait_for(function()
      return t:statusline():find("NORMAL") and btv.hl.exists("lualine_a_normal")
    end)
    btv.test.expect(btv.hl.get(0, { name = "lualine_a_normal" }).bg).to_be(0xabcabc)
    package.loaded["lualine.themes.btvlfake"] = nil
  end)

  btv.test.it("auto derives non-nil groups from the active colorscheme", function(t)
    btv.hl.define(0, "Normal", { fg = "#cccccc", bg = "#202020" })
    btv.hl.define(0, "Function", { fg = "#5599ff" })
    line.setup({
      options = { globalstatus = true, theme = "auto" },
      sections = { lualine_a = { "mode" } },
    })
    nudge(t)
    t:wait_for(function()
      return t:statusline():find("NORMAL") and btv.hl.exists("lualine_a_normal")
    end)
    -- section A's accent is derived from Function's fg
    btv.test.expect(btv.hl.get(0, { name = "lualine_a_normal" }).bg).to_be(0x5599ff)
  end)

  btv.test.it("recolours section A by mode via ModeChanged", function(t)
    line.setup({
      options = { globalstatus = true, theme = "default" },
      sections = { lualine_a = { "mode" } },
    })
    nudge(t)
    t:wait_for(function()
      return t:statusline():find("NORMAL")
    end)
    local function mode_hl()
      local cells = compile._last.BtvLineA
      return cells and cells[1] and cells[1].hl
    end
    btv.test.expect(mode_hl()).to_be("lualine_a_normal")

    t:feed("i")
    t:wait_for(function()
      return t:statusline():find("INSERT")
    end)
    btv.test.expect(mode_hl()).to_be("lualine_a_insert")

    t:feed("<Esc>")
    t:wait_for(function()
      return t:statusline():find("NORMAL")
    end)
    btv.test.expect(mode_hl()).to_be("lualine_a_normal")

    t:feed("v")
    t:wait_for(function()
      return t:statusline():find("VISUAL")
    end)
    btv.test.expect(mode_hl()).to_be("lualine_a_visual")
    t:feed("<Esc>")
  end)

  btv.test.it("labels and colours Helix's selection-first modes", function(t)
    line.setup({
      options = { globalstatus = true, theme = "default" },
      sections = { lualine_a = { "mode" } },
    })
    nudge(t)
    t:wait_for(function()
      return t:statusline():find("NORMAL")
    end)
    local function mode_hl()
      local cells = compile._last.BtvLineA
      return cells and cells[1] and cells[1].hl
    end

    -- Enter Helix's selection-first normal mode: the bar reads HELIX (not the raw
    -- "HN" code) and keeps the normal palette.
    btv.helix.enable()
    t:wait_for(function()
      return t:statusline():find("HELIX")
    end)
    btv.test.expect(mode_hl()).to_be("lualine_a_normal")

    -- `v` toggles Helix select (extend) mode: HELIX-SEL, coloured like visual.
    t:feed("v")
    t:wait_for(function()
      return t:statusline():find("HELIX%-SEL")
    end)
    btv.test.expect(mode_hl()).to_be("lualine_a_visual")

    -- Leave Helix so later tests see vim's Normal again.
    t:feed("<Esc>")
    btv.helix.disable()
    t:wait_for(function()
      return t:statusline():find("NORMAL")
    end)
  end)
end)
