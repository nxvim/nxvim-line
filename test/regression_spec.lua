-- Regression coverage for bugs found in the code-quality pass:
--
--   * the `i_CTRL-O` mode codes (`niI` / `niR`) rendered as the raw code upper-cased
--     ("NII" / "NIR") instead of a label, and took the wrong theme palette;
--   * `searchcount` re-enumerated the whole buffer on every CursorMoved (and once a
--     second under the refresh timer), so a large buffer paid a full text scan — and
--     up to `maxcount` native regex compiles — per keystroke;
--   * `compile._last_win` grew a permanent entry per window ever rendered;
--   * clearing a tabline left `'showtabline'` at 2, stranding an empty bar;
--   * a typo'd section key (`lualine_d`) was silently dropped;
--   * `git.run_fetch` released its concurrency slot twice when the update callback
--     threw, drifting the in-flight counter below zero (uncapping the runner);
--   * a git fetch that failed cached nothing, so `ensure` re-ran it on every render;
--   * `icons.register` silently stored `nil` for a malformed glyph spec.
--
--     bemtvi --test-plugin ~/work/bemtvi-plugins/bemtvi-line

local line = require("bemtvi-line")
local components = require("bemtvi-line.components")
local compile = require("bemtvi-line.compile")
local themes = require("bemtvi-line.themes")
local highlights = require("bemtvi-line.highlights")
local git = require("bemtvi-line.git")
local icons = require("bemtvi-line.icons")

-- The concrete colours a cell's highlight group resolves to (through any link).
local function hl_of(name)
  return btv.hl.get(0, { name = name, link = false })
end

local function nudge(t)
  t:feed("<Esc>")
end

btv.test.describe("bemtvi-line.mode-codes", function()
  -- `mode()` reports `niI` / `niR` while an `i_CTRL-O` one-shot is pending (Normal for
  -- exactly one command, then Insert / Replace resumes). Unmapped, the label fell
  -- through to `code:upper()` and the bar read "NII" / "NIR".
  btv.test.it("labels the i_CTRL-O one-shot modes instead of upper-casing the code", function()
    local mode = components.get("mode")
    local saved = btv._cur_mode
    btv._cur_mode = "niI"
    btv.test.expect(mode.provide({}).text).to_be("NORMAL")
    btv._cur_mode = "niR"
    btv.test.expect(mode.provide({}).text).to_be("NORMAL")
    btv._cur_mode = saved
  end)

  btv.test.it("maps the i_CTRL-O one-shot modes to the normal palette", function()
    btv.test.expect(themes.mode_of("niI")).to_be("normal")
    btv.test.expect(themes.mode_of("niR")).to_be("normal")
  end)

  -- Whatever an unknown/future code is, the label must be printable text — never a
  -- raw control character smuggled into the bar by `code:upper()` (a control byte in a
  -- status cell corrupts the bar's column math).
  btv.test.it("falls back to a printable label for an unknown mode code", function()
    local mode = components.get("mode")
    local saved = btv._cur_mode
    btv._cur_mode = "zz" -- no such mode: upper-cased passthrough
    btv.test.expect(mode.provide({}).text).to_be("ZZ")
    btv._cur_mode = "\1" -- an unmapped CONTROL code must not reach the bar raw
    local text = mode.provide({}).text
    btv.test.expect(text:find("%c") == nil).to_be(true)
    btv.test.expect(#text > 0).to_be(true)
    btv._cur_mode = saved
  end)

  -- The label table and the palette table must cover the same codes, or a mode gets a
  -- name with the wrong colour (or vice versa) — the drift that produced "NII".
  btv.test.it("every labelled mode code also resolves to a palette", function()
    local codes = { "n", "i", "v", "V", "R", "c", "t", "m", "niI", "niR", "hn", "hs", "s", "S" }
    for _, code in ipairs(codes) do
      local label = components.get("mode").provide
      btv._cur_mode = code
      btv.test.expect(label({}).text:find("%c") == nil).to_be(true)
      -- a real palette key, not the unknown-code fallback for a code we claim to know
      btv.test.expect(themes.mode_of(code)).to_be_truthy()
    end
    btv._cur_mode = "n"
  end)
end)

-- Put the cursor on line `n`, column 0. `btv.win.set_cursor` QUEUES a window op the
-- server drains after the Lua chunk, so a test can't set the cursor and read it back in
-- one go — drive it with keys and wait for the mirror to catch up.
local function goto_line(t, n)
  t:feed("gg")
  if n > 1 then
    t:feed(tostring(n) .. "G")
  end
  t:wait_for(function()
    return btv.cursor.get(0)[1] == n
  end)
end

btv.test.describe("bemtvi-line.searchcount (cached)", function()
  -- The count is derived from an enumerated match list; enumerating it costs a full
  -- buffer scan. It may be recomputed only when the buffer text or the pattern
  -- changes — NOT on a cursor move, which is the event the component rides.
  btv.test.it("re-uses the enumerated matches across cursor moves", function(t)
    line.setup({
      options = { globalstatus = true },
      sections = { lualine_z = { "searchcount" } },
    })
    nudge(t)
    btv.await(btv.buf.set_lines(0, 0, -1, false, { "foo a", "foo b", "foo c", "foo d" }))
    t:feed("gg")
    t:feed("/foo<CR>")
    t:wait_for(function()
      return t:statusline():find("/4%]")
    end)

    local buf, win = btv.buf.current(), btv.win.current()
    local ctx = { buf = buf, win = win, focused = true }
    local sc = components.get("searchcount")

    -- First call may scan; every later call at an unchanged (buf, tick, pattern) must not.
    sc.provide(ctx, {})
    local before = components._searchcount_stats.scans
    for _ = 1, 20 do
      sc.provide(ctx, {})
    end
    btv.test.expect(components._searchcount_stats.scans).to_be(before)

    -- ...and the cached list still answers the cursor's index correctly. One match per
    -- line, so line 3 is the third match and line 1 the first — all from the same list,
    -- with no further scans.
    local scans = components._searchcount_stats.scans
    goto_line(t, 3)
    btv.test.expect(sc.provide({ buf = buf, win = win, focused = true }, {}).text).to_be("[3/4]")
    goto_line(t, 1)
    btv.test.expect(sc.provide({ buf = buf, win = win, focused = true }, {}).text).to_be("[1/4]")
    btv.test.expect(components._searchcount_stats.scans).to_be(scans)

    -- An edit invalidates it: the tick moved, so the next call re-scans and the new
    -- total shows.
    btv.await(btv.buf.set_lines(0, 4, 4, false, { "foo e" }))
    local before_edit = components._searchcount_stats.scans
    btv.test.expect(sc.provide({ buf = buf, win = win, focused = true }, {}).text).to_be("[1/5]")
    btv.test.expect(components._searchcount_stats.scans > before_edit).to_be(true)
    t:feed("<Esc>")
  end)

  btv.test.it("a changed pattern re-scans even at the same changedtick", function(t)
    nudge(t)
    btv.await(btv.buf.set_lines(0, 0, -1, false, { "aa bb", "aa bb", "bb" }))
    local buf, win = btv.buf.current(), btv.win.current()
    local sc = components.get("searchcount")
    -- The `/` register is read-only, so the pattern is set the way a user sets it.
    t:feed("gg")
    t:feed("/aa<CR>")
    t:wait_for(function()
      return vim.fn.getreg("/") == "aa"
    end)
    goto_line(t, 1)
    local scans = components._searchcount_stats.scans
    btv.test.expect(sc.provide({ buf = buf, win = win, focused = true }, {}).text).to_be("[1/2]")
    t:feed("/bb<CR>")
    t:wait_for(function()
      return vim.fn.getreg("/") == "bb"
    end)
    goto_line(t, 1)
    -- The text never changed, so the tick is identical — the PATTERN change alone must
    -- invalidate, or the bar would keep showing the old pattern's total.
    btv.test.expect(sc.provide({ buf = buf, win = win, focused = true }, {}).text).to_be("[0/3]")
    btv.test.expect(components._searchcount_stats.scans > scans).to_be(true)
    t:feed("<Esc>")
  end)

  -- `'regexsyntax'` defaults to `pcre`, so the `/` register holds a PCRE pattern. The
  -- enumeration used to hardcode the VIM engine, where `fo+` is a literal `fo+` — it
  -- matched nothing, and the bar showed no count for a search the editor had just run.
  btv.test.it("enumerates with the buffer's effective 'regexsyntax', not always vim", function(t)
    nudge(t)
    btv.await(btv.buf.set_lines(0, 0, -1, false, { "foo a", "fo b", "foooo c" }))
    local buf, win = btv.buf.current(), btv.win.current()
    btv.test.expect(btv.bo[buf].regexsyntax).to_be("pcre")
    t:feed("gg")
    t:feed("/fo+<CR>") -- a PCRE quantifier: three matches. Vim-escaped, it matches none.
    t:wait_for(function()
      return vim.fn.getreg("/") == "fo+"
    end)
    goto_line(t, 1)
    local cell = components.get("searchcount").provide({ buf = buf, win = win, focused = true }, {})
    btv.test.expect(cell).to_be_truthy()
    btv.test.expect(cell.text).to_be("[1/3]")
    t:feed("<Esc>")
  end)
end)

btv.test.describe("bemtvi-line.compile hygiene", function()
  -- `_last_win` is the per-window introspection seam; it was only ever cleared by a
  -- fresh build(), so a session that opened and closed windows leaked one cell-list
  -- entry per dead window id.
  btv.test.it("drops _last_win entries for windows that no longer exist", function(t)
    line.setup({
      options = { globalstatus = false },
      sections = { lualine_c = { "filename" } },
    })
    nudge(t)
    t:feed(":split<CR>")
    local split = t:wait_for(function()
      return #btv.win.list() > 1 and btv.win.current()
    end)
    -- The split rendered, so it has an entry.
    t:wait_for(function()
      return compile._last_win[split] ~= nil
    end)
    t:feed(":close<CR>")
    t:wait_for(function()
      return #btv.win.list() == 1
    end)
    line.refresh()
    nudge(t)
    t:wait_for(function()
      return compile._last_win[split] == nil
    end)
    btv.test.expect(compile._last_win[split]).to_be_nil()
  end)

  -- Clearing our tabline restored `'tabline'` but left `'showtabline'` at 2, so an
  -- empty bar kept occupying a screen row.
  btv.test.it("restores 'showtabline' when the tabline is configured away", function(t)
    -- An explicit baseline: an earlier test may have left it at 2, which would make the
    -- final assertion pass for the wrong reason.
    vim.o.showtabline = 1
    local before = vim.o.showtabline
    line.setup({
      options = { globalstatus = true },
      sections = { lualine_c = { "filename" } },
      tabline = { lualine_a = { { "label", text = "TABBAR" } } },
    })
    nudge(t)
    btv.test.expect(vim.o.showtabline).to_be(2)
    line.setup({
      options = { globalstatus = true },
      sections = { lualine_c = { "filename" } },
    })
    nudge(t)
    btv.test.expect(vim.o.tabline).to_be("")
    btv.test.expect(vim.o.showtabline).to_be(before)
  end)
end)

btv.test.describe("bemtvi-line.own-highlight padding", function()
  -- A component whose cells carry their OWN highlight (the per-kind `diff` counts, the
  -- per-severity `diagnostics` counts) got its padding concatenated onto the run's edge
  -- cells, and its internal separator prefixed onto the FOLLOWING cell. Both spaces
  -- therefore took the wrong colour: the gap separating the component from its neighbour
  -- was tinted with the FIRST count's colour, and the gap between two counts with the
  -- colour of the count AFTER it. With background-coloured Diff*/Diagnostic* groups that
  -- renders as `<add>" +12"<del>" -1 "` — a green block leaking left into the neighbour's
  -- gap and a red block starting a space too early:
  --
  --     want:  ·<add>" +12 "<del>" -1 "·      got:  <add>" +12"<del>" -1 "
  --
  -- so each count owns the spaces on both sides of it, and the component's outer padding
  -- stays neutral (the section group), belonging to no count.
  btv.test.it("keeps the outer pad neutral and pads each diff count in its own colour", function(t)
    -- Seed the cache so the render is deterministic (no git run, no repo needed); stub
    -- the fetch entry points so nothing can land over the seed mid-test.
    local buf = btv.buf.current()
    local name = btv.buf.name(buf)
    local k = name ~= "" and name or vim.fn.getcwd()
    local saved_ensure, saved_schedule = git.ensure, git.schedule
    git.ensure, git.schedule = function() end, function() end
    git._cache[k] = { branch = "b", diff = { added = 12, changed = 0, removed = 1 } }
    -- The bare test session loads no colorscheme: give the counts the foregrounds a real
    -- one would, so each is identifiable by colour below.
    btv.hl.define(0, "Added", { fg = "#00ff00" })
    btv.hl.define(0, "Removed", { fg = "#ff0000" })

    line.setup({
      options = { globalstatus = true },
      sections = { lualine_b = { "diff" } },
    })
    nudge(t)
    t:wait_for(function()
      return t:statusline():find("%+12")
    end)

    local cells = compile._last.BtvLineB
    -- restore BEFORE asserting: a failure throws, and leaving the stubs installed would
    -- break the git tests that follow.
    git.ensure, git.schedule = saved_ensure, saved_schedule
    git._cache[k] = nil

    local neutral = highlights.section_group("b", "normal")
    -- section b is a LEFT section: its cells are the component run followed by the
    -- trailing powerline arrow, which is not part of this assertion.
    btv.test.expect(cells[1].text).to_be(" ")
    btv.test.expect(cells[1].hl).to_be(neutral)
    btv.test.expect(cells[2].text).to_be(" +12 ")
    btv.test.expect(hl_of(cells[2].hl).fg).to_be(0x00ff00)
    btv.test.expect(cells[3].text).to_be(" -1 ")
    btv.test.expect(hl_of(cells[3].hl).fg).to_be(0xff0000)
    btv.test.expect(cells[4].text).to_be(" ")
    btv.test.expect(cells[4].hl).to_be(neutral)
  end)

  -- The same shape for the per-severity diagnostic counts.
  btv.test.it("pads each diagnostic count in its own severity colour", function(t)
    btv.hl.define(0, "DiagnosticError", { fg = "#ff0000" })
    btv.hl.define(0, "DiagnosticWarn", { fg = "#ffaa00" })
    line.setup({
      options = { globalstatus = true, icons_enabled = false },
      sections = { lualine_b = { "diagnostics" } },
    })
    nudge(t)
    local ns = vim.api.nvim_create_namespace("btvline_diag_pad_test")
    btv.diagnostic.set(ns, 0, {
      { lnum = 0, col = 0, severity = 1, message = "an error" },
      { lnum = 1, col = 0, severity = 2, message = "a warning" },
    })
    line.refresh()
    nudge(t)
    t:wait_for(function()
      return t:statusline():find("E:1")
    end)

    local cells = compile._last.BtvLineB
    local neutral = highlights.section_group("b", "normal")
    btv.test.expect(cells[1].text).to_be(" ")
    btv.test.expect(cells[1].hl).to_be(neutral)
    btv.test.expect(cells[2].text).to_be(" E:1 ")
    btv.test.expect(hl_of(cells[2].hl).fg).to_be(0xff0000)
    btv.test.expect(cells[3].text).to_be(" W:1 ")
    btv.test.expect(hl_of(cells[3].hl).fg).to_be(0xffaa00)
    btv.test.expect(cells[4].text).to_be(" ")
    btv.test.expect(cells[4].hl).to_be(neutral)
    btv.diagnostic.reset(ns, 0)
  end)

  -- A component-level `color` DOES own its padding (it colours the whole component, the
  -- lualine semantics), so its pad must stay coloured rather than going neutral.
  btv.test.it("a component-level color still covers its own padding", function(t)
    line.setup({
      options = { globalstatus = true },
      sections = { lualine_b = { { "mode", color = { fg = "#00ff00" } } } },
    })
    nudge(t)
    t:wait_for(function()
      return t:statusline():find("NORMAL")
    end)
    local cells = compile._last.BtvLineB
    local neutral = highlights.section_group("b", "normal")
    btv.test.expect(cells[1].text).to_be(" NORMAL ")
    btv.test.expect(cells[1].hl).never.to_be(neutral)
  end)
end)

-- A section whose background is NOT the bar's `StatusLine` background — catppuccin's
-- lualine theme (`surface0` for section b) over its `StatusLine` (`mantle`), the setup the
-- bug was reported on, with its real colours.
local CATPPUCCIN_B_BG = 0x313244
local CATPPUCCIN_SL_BG = 0x181825
local function setup_two_tone(sections)
  btv.hl.define(0, "StatusLine", { fg = "#cdd6f4", bg = "#181825" })
  line.setup({
    options = {
      globalstatus = true,
      icons_enabled = false,
      theme = {
        normal = {
          a = { fg = "#11111b", bg = "#89b4fa" },
          b = { fg = "#89b4fa", bg = "#313244" },
          c = {},
        },
      },
    },
    sections = sections,
  })
end

btv.test.describe("bemtvi-line.own-highlight background", function()
  -- A cell carrying its OWN colour named an editor group verbatim (`DiagnosticError` for
  -- an error count, `DiffAdd` for an added-lines count). A cell hl is a WHOLE highlight
  -- group, and a client fills an attribute the group leaves unset from the BAR's base
  -- `StatusLine` — not from the section around the cell, which is only the previous cell's
  -- group. Catppuccin defines `DiagnosticError` foreground-only, so its counts rendered on
  -- `mantle` inside a `surface0` section: a dark block in a lighter bar. Each count now
  -- paints its own foreground over the SECTION's background.
  btv.test.it("merges a count's foreground onto the section background", function(t)
    btv.hl.define(0, "DiagnosticError", { fg = "#f38ba8" })
    btv.hl.define(0, "DiagnosticWarn", { fg = "#f9e2af" })
    setup_two_tone({ lualine_b = { "diagnostics" } })
    nudge(t)
    local ns = vim.api.nvim_create_namespace("btvline_diag_bg_test")
    btv.diagnostic.set(ns, 0, {
      { lnum = 0, col = 0, severity = 1, message = "an error" },
      { lnum = 1, col = 0, severity = 2, message = "a warning" },
    })
    line.refresh()
    nudge(t)
    t:wait_for(function()
      return t:statusline():find("E:1")
    end)

    -- the two backgrounds the bug is about really do differ in this session
    btv.test.expect(hl_of(highlights.section_group("b", "normal")).bg).to_be(CATPPUCCIN_B_BG)
    btv.test.expect(hl_of("StatusLine").bg).to_be(CATPPUCCIN_SL_BG)

    local cells = compile._last.BtvLineB
    btv.test.expect(cells[2].text).to_be(" E:1 ")
    btv.test.expect(hl_of(cells[2].hl).fg).to_be(0xf38ba8)
    btv.test.expect(hl_of(cells[2].hl).bg).to_be(CATPPUCCIN_B_BG) -- not StatusLine's
    btv.test.expect(cells[3].text).to_be(" W:1 ")
    btv.test.expect(hl_of(cells[3].hl).fg).to_be(0xf9e2af)
    btv.test.expect(hl_of(cells[3].hl).bg).to_be(CATPPUCCIN_B_BG)
    btv.diagnostic.reset(ns, 0)
  end)

  -- lualine's `create_component_highlight_group` semantics for a component-level `color`:
  -- a colour naming no background is merged over the section's, one that names a
  -- background is a deliberate block and is left whole.
  btv.test.it("a fg-only color takes the section bg, one with a bg is left whole", function(t)
    btv.hl.define(0, "BtvLineTestGroup", { fg = "#00ffff", bg = "#010203" })
    setup_two_tone({
      lualine_b = { { "mode", color = { fg = "#00ff00", gui = "bold" } } },
      lualine_c = { { "mode", color = "BtvLineTestGroup" } },
    })
    nudge(t)
    t:wait_for(function()
      return t:statusline():find("NORMAL")
    end)

    local b = compile._last.BtvLineB[1]
    btv.test.expect(hl_of(b.hl).fg).to_be(0x00ff00)
    btv.test.expect(hl_of(b.hl).bg).to_be(CATPPUCCIN_B_BG)
    btv.test.expect(hl_of(b.hl).bold).to_be(true) -- the gui attrs come along

    local c = compile._last.BtvLineC[1]
    btv.test.expect(c.hl).to_be("BtvLineTestGroup")
  end)
end)

btv.test.describe("bemtvi-line.count colours", function()
  -- The diff counts named `Diff{Add,Change,Delete}` for their colour, but a colorscheme
  -- gives those groups the diff-VIEW background wash and often no foreground at all
  -- (catppuccin: `DiffAdd = { bg = darken(green) }`). Merged onto the section that left
  -- the counts uncoloured. They now read the standard fg-only diff-summary groups first.
  btv.test.it("takes a diff count's colour from Added/Changed/Removed", function(t)
    local buf = btv.buf.current()
    local name = btv.buf.name(buf)
    local k = name ~= "" and name or vim.fn.getcwd()
    local saved_ensure, saved_schedule = git.ensure, git.schedule
    git.ensure, git.schedule = function() end, function() end
    git._cache[k] = { branch = "b", diff = { added = 1, changed = 2, removed = 3 } }
    -- catppuccin's shape: a fg-only summary group AND a bg-only diff-view group
    btv.hl.define(0, "Added", { fg = "#a6e3a1" })
    btv.hl.define(0, "Changed", { fg = "#89b4fa" })
    btv.hl.define(0, "Removed", { fg = "#f38ba8" })
    btv.hl.define(0, "DiffAdd", { bg = "#26343a" })
    btv.hl.define(0, "DiffChange", { bg = "#1e2b40" })
    btv.hl.define(0, "DiffDelete", { bg = "#3a2434" })

    setup_two_tone({ lualine_b = { "diff" } })
    nudge(t)
    t:wait_for(function()
      return t:statusline():find("%+1")
    end)
    local cells = compile._last.BtvLineB
    git.ensure, git.schedule = saved_ensure, saved_schedule
    git._cache[k] = nil

    btv.test.expect(cells[2].text).to_be(" +1 ")
    btv.test.expect(hl_of(cells[2].hl).fg).to_be(0xa6e3a1)
    btv.test.expect(hl_of(cells[2].hl).bg).to_be(CATPPUCCIN_B_BG) -- not DiffAdd's wash
    btv.test.expect(cells[3].text).to_be(" ~2 ")
    btv.test.expect(hl_of(cells[3].hl).fg).to_be(0x89b4fa)
    btv.test.expect(cells[4].text).to_be(" -3 ")
    btv.test.expect(hl_of(cells[4].hl).fg).to_be(0xf38ba8)
  end)

  -- With no group in the chain defined, the count still lands in the ACTIVE theme's
  -- palette (`btv.hl.palette`) rather than a hardcoded hex from some other colorscheme.
  btv.test.it("falls back to the theme's own hue, not a hardcoded colour", function(t)
    for _, g in ipairs({ "DiagnosticError", "DiagnosticSignError" }) do
      btv.hl.define(0, g, {})
    end
    btv.hl.define(0, "ErrorMsg", { fg = "#abcdef" }) -- the palette's `red` chain
    setup_two_tone({ lualine_b = { "diagnostics" } })
    nudge(t)
    local ns = vim.api.nvim_create_namespace("btvline_diag_hue_test")
    btv.diagnostic.set(ns, 0, { { lnum = 0, col = 0, severity = 1, message = "an error" } })
    line.refresh()
    nudge(t)
    t:wait_for(function()
      return t:statusline():find("E:%d")
    end)
    local cells = compile._last.BtvLineB
    btv.test.expect(cells[2].text:match("^ E:%d+ $")).never.to_be_nil()
    btv.test.expect(hl_of(cells[2].hl).fg).to_be(tonumber(btv.hl.palette().red:sub(2), 16))
    btv.test.expect(hl_of(cells[2].hl).fg).to_be(0xabcdef)
    btv.test.expect(hl_of(cells[2].hl).bg).to_be(CATPPUCCIN_B_BG)
    btv.diagnostic.reset(ns, 0)
  end)
end)

btv.test.describe("bemtvi-line.config strictness", function()
  -- A typo'd section key silently dropped every component in it — the config looked
  -- accepted and the bar was just wrong.
  btv.test.it("errors on an unknown section key", function()
    btv.test
      .expect(function()
        line.setup({ sections = { lualine_d = { "mode" } } })
      end)
      .to_error("lualine_d")
  end)

  btv.test.it("errors on an unknown key in inactive_sections and tabline too", function()
    btv.test
      .expect(function()
        line.setup({ inactive_sections = { lualine_q = { "mode" } } })
      end)
      .to_error("lualine_q")
    btv.test
      .expect(function()
        line.setup({ tabline = { nope = { "mode" } } })
      end)
      .to_error("nope")
  end)
end)

btv.test.describe("bemtvi-line.git robustness", function()
  -- `run_fetch` released its slot inline and again from the promise's `catch`. An
  -- `on_update` callback that throws took both paths, so `_active` drifted below zero
  -- and the concurrency cap stopped capping.
  btv.test.it("releases its concurrency slot exactly once when on_update throws", function(t)
    git.deactivate()
    git._cache = {}
    git._active = 0
    git.activate(function()
      error("on_update blew up")
    end)
    git.ensure(btv.buf.current())
    t:wait_for(function()
      return git._active == 0 and next(git._inflight) == nil
    end)
    btv.test.expect(git._active).to_be(0)
    git.deactivate()
  end)

  -- A fetch that fails must still record *something*, or `ensure` (which fires on
  -- every render for an uncached key) re-runs it forever.
  btv.test.it("caches a failed fetch so ensure stops re-running it", function(t)
    git.deactivate()
    git._cache = {}
    git._active = 0
    git._stats.runs = 0
    local head = btv.git.head
    btv.git.head = function()
      return btv.promise(function(_, reject)
        reject("simulated git failure")
      end)
    end
    git.activate(function() end)
    local buf = btv.buf.current()
    git.ensure(buf)
    t:wait_for(function()
      return git._cache[btv.buf.name(buf) ~= "" and btv.buf.name(buf) or vim.fn.getcwd()] ~= nil
    end)
    local runs = git._stats.runs
    for _ = 1, 10 do
      git.ensure(buf)
    end
    btv.test.expect(git._stats.runs).to_be(runs)
    btv.git.head = head
    git.deactivate()
  end)
end)

btv.test.describe("bemtvi-line.icons strictness", function()
  -- A malformed spec used to store `nil`, silently un-registering nothing and leaving
  -- the caller to wonder why their glyph never showed.
  btv.test.it("errors on a malformed glyph spec instead of storing nil", function()
    btv.test
      .expect(function()
        icons.register({ zzz = 42 })
      end)
      .to_error("glyph")
    btv.test
      .expect(function()
        icons.register({ name = { ["Zzzfile"] = {} } })
      end)
      .to_error("glyph")
    -- A well-formed one still registers (both spellings).
    icons.register({ zzz = "\u{f15b}", name = { ["Zzzfile"] = { glyph = "\u{f15c}" } } })
    btv.test.expect(icons._by_ext.zzz).to_be("\u{f15b}")
    btv.test.expect(icons._by_name.Zzzfile).to_be("\u{f15c}")
  end)
end)
