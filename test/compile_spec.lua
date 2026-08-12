-- End-to-end: the compiler lowers a config onto btv.statusline and the rendered text
-- shows up. Driven through a real editor; assertions read the rendered statusline via
-- `t:statusline()`. That mirror reflects the GLOBAL bar (laststatus=3), so these tests
-- use `globalstatus = true` to observe the output.
--
--     bemtvi --test-plugin ~/work/bemtvi-plugins/bemtvi-line

local line = require("bemtvi-line")

-- The statusline mirror updates from `run_pending`, which fires on input — not from
-- the wait_for poll timer. So after a setup() that queues the layout, feed a harmless
-- key (a no-op `<Esc>` in normal mode) to drive one tick and render the first frame.
local function nudge(t)
  t:feed("<Esc>")
end

btv.test.describe("bemtvi-line.compile", function()
  btv.test.it("renders mode + location into the global statusline", function(t)
    line.setup({
      options = { globalstatus = true },
      sections = { lualine_a = { "mode" }, lualine_z = { "location" } },
    })
    nudge(t)
    local sl = t:wait_for(function()
      local s = t:statusline()
      return s:find("NORMAL") and s
    end)
    btv.test.expect(sl).to_contain("NORMAL")
    btv.test.expect(sl).to_contain("1:1")
  end)

  btv.test.it(
    "edge sections' separators transition into the fill, not the inner neighbour",
    function(t)
      -- The last LEFT section and the first RIGHT section border the central fill, so
      -- their powerline arrows must transition to/from the fill section (c) — both ending
      -- up the same fill colour. A regressed adjacency made the last left section point at
      -- its inner neighbour (b) instead, so the fill colour disagreed with the right half
      -- and the join rendered as a mismatched solid cell.
      local compile = require("bemtvi-line.compile")
      local theme = {
        normal = {
          a = { fg = "#000000", bg = "#aa0000" },
          b = { fg = "#000000", bg = "#00aa00" },
          c = { fg = "#000000", bg = "#0000aa" }, -- the fill colour
        },
      }
      line.setup({
        options = { globalstatus = true, theme = theme },
        sections = {
          lualine_a = { "mode" },
          lualine_b = { "mode" },
          lualine_c = { "mode" },
          lualine_x = { "mode" },
          lualine_y = { "mode" },
          lualine_z = { "mode" },
        },
      })
      nudge(t)
      t:wait_for(function()
        return t:statusline():find("NORMAL")
      end)
      local function sep_bg(cell)
        return cell and cell.hl and btv.hl.get(0, { name = cell.hl }).bg
      end
      -- last left section's trailing arrow = its LAST cell; first right section's leading
      -- arrow = its FIRST cell. Both must carry the fill (c) background, 0x0000aa.
      local left = compile._last["BtvLineC"]
      local right = compile._last["BtvLineX"]
      local left_sep_bg = sep_bg(left[#left])
      local right_sep_bg = sep_bg(right[1])
      btv.test.expect(left_sep_bg).to_be(0x0000aa)
      btv.test.expect(right_sep_bg).to_be(0x0000aa)
      btv.test.expect(left_sep_bg).to_be(right_sep_bg)
    end
  )

  btv.test.it("reacts to a mode change via ModeChanged", function(t)
    line.setup({
      options = { globalstatus = true },
      sections = { lualine_a = { "mode" } },
    })
    nudge(t)
    t:wait_for(function()
      return t:statusline():find("NORMAL")
    end)
    t:feed("i")
    local sl = t:wait_for(function()
      local s = t:statusline()
      return s:find("INSERT") and s
    end)
    btv.test.expect(sl).to_contain("INSERT")
    -- back to normal so a later test starts in a known mode
    t:feed("<Esc>")
    t:wait_for(function()
      return t:statusline():find("NORMAL")
    end)
  end)

  btv.test.it("the fill-bordering right separator is a thin component-style one", function(t)
    -- The first right section borders the central (lualine_c) fill. Its leading
    -- separator uses the thin COMPONENT glyph with the section's own (light) fg —
    -- not the solid SECTION arrow whose colour transition is invisible/pointless
    -- against the neutral fill. Inner section boundaries keep the solid arrow.
    local compile = require("bemtvi-line.compile")
    local theme = {
      normal = {
        a = { fg = "#000000", bg = "#aa0000" },
        b = { fg = "#000000", bg = "#00aa00" },
        c = { fg = "#111111", bg = "#0000aa" },
        x = { fg = "#cccccc", bg = "#222222" }, -- distinct section, light fg
      },
    }
    line.setup({
      options = {
        globalstatus = true,
        theme = theme,
        section_separators = { left = "\u{e0b0}", right = "\u{e0b2}" },
        component_separators = { left = "\u{e0b1}", right = "\u{e0b3}" },
      },
      sections = {
        lualine_a = { "mode" },
        lualine_x = { "mode" },
        lualine_y = { "mode" },
        lualine_z = { "mode" },
      },
    })
    nudge(t)
    t:wait_for(function()
      return t:statusline():find("NORMAL")
    end)
    local x = compile._last["BtvLineX"]
    -- cell 1 is the leading (fill-bordering) separator
    btv.test.expect(x[1].text).to_be("\u{e0b3}") -- thin component glyph, not solid "\u{e0b2}"
    btv.test.expect(btv.hl.get(0, { name = x[1].hl }).fg).to_be(0xcccccc) -- light section fg
    -- the inner Y separator still uses the solid section arrow
    local y = compile._last["BtvLineY"]
    btv.test.expect(y[1].text).to_be("\u{e0b2}")
  end)

  btv.test.it("the mode arrow skips an empty neighbour and reaches the fill bg", function(t)
    -- The mode block (a) arrows into section b. When b renders NOTHING (an empty git
    -- branch), its arrow must NOT keep b's background over the collapsed section — it must
    -- transition into the first section that actually renders (here filename, c), whose bg
    -- IS the fill. A regression here leaves a mismatched green chevron floating before the
    -- dark fill.
    local compile = require("bemtvi-line.compile")
    local theme = {
      normal = {
        a = { fg = "#000000", bg = "#aa0000" },
        b = { fg = "#000000", bg = "#00aa00" }, -- the git/branch section bg (distinct)
        c = { fg = "#000000", bg = "#0000aa" }, -- the fill colour
      },
    }
    line.setup({
      options = { globalstatus = true, theme = theme },
      sections = {
        lualine_a = { "mode" },
        lualine_b = {
          function()
            return nil
          end,
        }, -- renders nothing (no branch)
        lualine_c = { "filename" },
      },
    })
    nudge(t)
    t:wait_for(function()
      return t:statusline():find("NORMAL")
    end)
    local a = compile._last["BtvLineA"]
    local arrow_bg = btv.hl.get(0, { name = a[#a].hl }).bg
    btv.test.expect(arrow_bg).to_be(0x0000aa) -- fill (c), NOT 0x00aa00 (the empty b)
  end)

  btv.test.it("the mode arrow takes the neighbour's bg when the neighbour renders", function(t)
    -- Same layout, but now b renders (the branch shows): the mode arrow must transition
    -- into b's (green) background, distinct from the fill.
    local compile = require("bemtvi-line.compile")
    local theme = {
      normal = {
        a = { fg = "#000000", bg = "#aa0000" },
        b = { fg = "#000000", bg = "#00aa00" },
        c = { fg = "#000000", bg = "#0000aa" },
      },
    }
    line.setup({
      options = { globalstatus = true, theme = theme },
      sections = {
        lualine_a = { "mode" },
        lualine_b = {
          function()
            return "main"
          end,
        }, -- renders (branch shown)
        lualine_c = { "filename" },
      },
    })
    nudge(t)
    t:wait_for(function()
      return t:statusline():find("NORMAL")
    end)
    local a = compile._last["BtvLineA"]
    local arrow_bg = btv.hl.get(0, { name = a[#a].hl }).bg
    btv.test.expect(arrow_bg).to_be(0x00aa00) -- section b bg
  end)

  btv.test.it("shows MULTICURSOR in multi-cursor placement mode", function(t)
    line.setup({
      options = { globalstatus = true },
      sections = { lualine_a = { "mode" } },
    })
    nudge(t)
    t:wait_for(function()
      return t:statusline():find("NORMAL")
    end)
    -- `<A-c>` enters bemtvi's multi-cursor placement mode, which reports mode() "m";
    -- the mode component must label it MULTICURSOR (not fall back to NORMAL).
    t:feed("<A-c>")
    local sl = t:wait_for(function()
      local s = t:statusline()
      return s:find("MULTICURSOR") and s
    end)
    btv.test.expect(sl).to_contain("MULTICURSOR")
    -- leave placement mode so a later test starts in a known mode
    t:feed("<Esc>")
    t:wait_for(function()
      return t:statusline():find("NORMAL")
    end)
  end)

  btv.test.it("shows [No Name] for an unnamed buffer", function(t)
    line.setup({
      options = { globalstatus = true },
      sections = { lualine_c = { "filename" } },
    })
    nudge(t)
    local sl = t:wait_for(function()
      local s = t:statusline()
      return s:find("No Name") and s
    end)
    btv.test.expect(sl).to_contain("[No Name]")
  end)

  btv.test.it("re-running setup() does not duplicate a section", function(t)
    local cfg = {
      options = { globalstatus = true },
      sections = { lualine_a = { "mode" } },
    }
    line.setup(cfg)
    line.setup(cfg)
    nudge(t)
    local sl = t:wait_for(function()
      local s = t:statusline()
      return s:find("NORMAL") and s
    end)
    local _, count = sl:gsub("NORMAL", "")
    btv.test.expect(count).to_be(1)
  end)

  btv.test.it("location tracks the cursor on a motion", function(t)
    line.setup({
      options = { globalstatus = true },
      sections = { lualine_z = { "location" } },
    })
    nudge(t)
    btv.await(btv.buf.set_lines(0, 0, -1, false, { "one", "two", "three" }))
    t:wait_for(function()
      return t:statusline():find("1:1")
    end)
    t:feed("j")
    local sl = t:wait_for(function()
      local s = t:statusline()
      return s:find("2:1") and s
    end)
    btv.test.expect(sl).to_contain("2:1")
  end)

  btv.test.it("an empty section is omitted (no NormalNORMAL collisions)", function(t)
    -- Only section A is populated; b/c/x/y/z are empty and must contribute nothing.
    line.setup({
      options = { globalstatus = true },
      sections = {
        lualine_a = { "mode" },
        lualine_b = {},
        lualine_c = {},
        lualine_x = {},
        lualine_y = {},
        lualine_z = {},
      },
    })
    nudge(t)
    local sl = t:wait_for(function()
      local s = t:statusline()
      return s:find("NORMAL") and s
    end)
    btv.test.expect(sl).to_contain("NORMAL")
    btv.test.expect(sl).never.to_contain("E:")
  end)
end)
