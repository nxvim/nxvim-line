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
--     nxvim --test-plugin ~/work/nxvim-plugins/nxvim-line

local line = require("nxvim-line")
local components = require("nxvim-line.components")
local compile = require("nxvim-line.compile")
local themes = require("nxvim-line.themes")
local git = require("nxvim-line.git")
local icons = require("nxvim-line.icons")

local function nudge(t)
  t:feed("<Esc>")
end

nx.test.describe("nxvim-line.mode-codes", function()
  -- `mode()` reports `niI` / `niR` while an `i_CTRL-O` one-shot is pending (Normal for
  -- exactly one command, then Insert / Replace resumes). Unmapped, the label fell
  -- through to `code:upper()` and the bar read "NII" / "NIR".
  nx.test.it("labels the i_CTRL-O one-shot modes instead of upper-casing the code", function()
    local mode = components.get("mode")
    local saved = nx._cur_mode
    nx._cur_mode = "niI"
    nx.test.expect(mode.provide({}).text).to_be("NORMAL")
    nx._cur_mode = "niR"
    nx.test.expect(mode.provide({}).text).to_be("NORMAL")
    nx._cur_mode = saved
  end)

  nx.test.it("maps the i_CTRL-O one-shot modes to the normal palette", function()
    nx.test.expect(themes.mode_of("niI")).to_be("normal")
    nx.test.expect(themes.mode_of("niR")).to_be("normal")
  end)

  -- Whatever an unknown/future code is, the label must be printable text — never a
  -- raw control character smuggled into the bar by `code:upper()` (a control byte in a
  -- status cell corrupts the bar's column math).
  nx.test.it("falls back to a printable label for an unknown mode code", function()
    local mode = components.get("mode")
    local saved = nx._cur_mode
    nx._cur_mode = "zz" -- no such mode: upper-cased passthrough
    nx.test.expect(mode.provide({}).text).to_be("ZZ")
    nx._cur_mode = "\1" -- an unmapped CONTROL code must not reach the bar raw
    local text = mode.provide({}).text
    nx.test.expect(text:find("%c") == nil).to_be(true)
    nx.test.expect(#text > 0).to_be(true)
    nx._cur_mode = saved
  end)

  -- The label table and the palette table must cover the same codes, or a mode gets a
  -- name with the wrong colour (or vice versa) — the drift that produced "NII".
  nx.test.it("every labelled mode code also resolves to a palette", function()
    local codes = { "n", "i", "v", "V", "R", "c", "t", "m", "niI", "niR", "hn", "hs", "s", "S" }
    for _, code in ipairs(codes) do
      local label = components.get("mode").provide
      nx._cur_mode = code
      nx.test.expect(label({}).text:find("%c") == nil).to_be(true)
      -- a real palette key, not the unknown-code fallback for a code we claim to know
      nx.test.expect(themes.mode_of(code)).to_be_truthy()
    end
    nx._cur_mode = "n"
  end)
end)

-- Put the cursor on line `n`, column 0. `nx.win.set_cursor` QUEUES a window op the
-- server drains after the Lua chunk, so a test can't set the cursor and read it back in
-- one go — drive it with keys and wait for the mirror to catch up.
local function goto_line(t, n)
  t:feed("gg")
  if n > 1 then
    t:feed(tostring(n) .. "G")
  end
  t:wait_for(function()
    return nx.cursor.get(0)[1] == n
  end)
end

nx.test.describe("nxvim-line.searchcount (cached)", function()
  -- The count is derived from an enumerated match list; enumerating it costs a full
  -- buffer scan. It may be recomputed only when the buffer text or the pattern
  -- changes — NOT on a cursor move, which is the event the component rides.
  nx.test.it("re-uses the enumerated matches across cursor moves", function(t)
    line.setup({
      options = { globalstatus = true },
      sections = { lualine_z = { "searchcount" } },
    })
    nudge(t)
    nx.await(nx.buf.set_lines(0, 0, -1, false, { "foo a", "foo b", "foo c", "foo d" }))
    t:feed("gg")
    t:feed("/foo<CR>")
    t:wait_for(function()
      return t:statusline():find("/4%]")
    end)

    local buf, win = nx.buf.current(), nx.win.current()
    local ctx = { buf = buf, win = win, focused = true }
    local sc = components.get("searchcount")

    -- First call may scan; every later call at an unchanged (buf, tick, pattern) must not.
    sc.provide(ctx, {})
    local before = components._searchcount_stats.scans
    for _ = 1, 20 do
      sc.provide(ctx, {})
    end
    nx.test.expect(components._searchcount_stats.scans).to_be(before)

    -- ...and the cached list still answers the cursor's index correctly. One match per
    -- line, so line 3 is the third match and line 1 the first — all from the same list,
    -- with no further scans.
    local scans = components._searchcount_stats.scans
    goto_line(t, 3)
    nx.test.expect(sc.provide({ buf = buf, win = win, focused = true }, {}).text).to_be("[3/4]")
    goto_line(t, 1)
    nx.test.expect(sc.provide({ buf = buf, win = win, focused = true }, {}).text).to_be("[1/4]")
    nx.test.expect(components._searchcount_stats.scans).to_be(scans)

    -- An edit invalidates it: the tick moved, so the next call re-scans and the new
    -- total shows.
    nx.await(nx.buf.set_lines(0, 4, 4, false, { "foo e" }))
    local before_edit = components._searchcount_stats.scans
    nx.test.expect(sc.provide({ buf = buf, win = win, focused = true }, {}).text).to_be("[1/5]")
    nx.test.expect(components._searchcount_stats.scans > before_edit).to_be(true)
    t:feed("<Esc>")
  end)

  nx.test.it("a changed pattern re-scans even at the same changedtick", function(t)
    nudge(t)
    nx.await(nx.buf.set_lines(0, 0, -1, false, { "aa bb", "aa bb", "bb" }))
    local buf, win = nx.buf.current(), nx.win.current()
    local sc = components.get("searchcount")
    -- The `/` register is read-only, so the pattern is set the way a user sets it.
    t:feed("gg")
    t:feed("/aa<CR>")
    t:wait_for(function()
      return vim.fn.getreg("/") == "aa"
    end)
    goto_line(t, 1)
    local scans = components._searchcount_stats.scans
    nx.test.expect(sc.provide({ buf = buf, win = win, focused = true }, {}).text).to_be("[1/2]")
    t:feed("/bb<CR>")
    t:wait_for(function()
      return vim.fn.getreg("/") == "bb"
    end)
    goto_line(t, 1)
    -- The text never changed, so the tick is identical — the PATTERN change alone must
    -- invalidate, or the bar would keep showing the old pattern's total.
    nx.test.expect(sc.provide({ buf = buf, win = win, focused = true }, {}).text).to_be("[0/3]")
    nx.test.expect(components._searchcount_stats.scans > scans).to_be(true)
    t:feed("<Esc>")
  end)

  -- `'regexsyntax'` defaults to `pcre`, so the `/` register holds a PCRE pattern. The
  -- enumeration used to hardcode the VIM engine, where `fo+` is a literal `fo+` — it
  -- matched nothing, and the bar showed no count for a search the editor had just run.
  nx.test.it("enumerates with the buffer's effective 'regexsyntax', not always vim", function(t)
    nudge(t)
    nx.await(nx.buf.set_lines(0, 0, -1, false, { "foo a", "fo b", "foooo c" }))
    local buf, win = nx.buf.current(), nx.win.current()
    nx.test.expect(nx.bo[buf].regexsyntax).to_be("pcre")
    t:feed("gg")
    t:feed("/fo+<CR>") -- a PCRE quantifier: three matches. Vim-escaped, it matches none.
    t:wait_for(function()
      return vim.fn.getreg("/") == "fo+"
    end)
    goto_line(t, 1)
    local cell = components.get("searchcount").provide({ buf = buf, win = win, focused = true }, {})
    nx.test.expect(cell).to_be_truthy()
    nx.test.expect(cell.text).to_be("[1/3]")
    t:feed("<Esc>")
  end)
end)

nx.test.describe("nxvim-line.compile hygiene", function()
  -- `_last_win` is the per-window introspection seam; it was only ever cleared by a
  -- fresh build(), so a session that opened and closed windows leaked one cell-list
  -- entry per dead window id.
  nx.test.it("drops _last_win entries for windows that no longer exist", function(t)
    line.setup({
      options = { globalstatus = false },
      sections = { lualine_c = { "filename" } },
    })
    nudge(t)
    t:feed(":split<CR>")
    local split = t:wait_for(function()
      return #nx.win.list() > 1 and nx.win.current()
    end)
    -- The split rendered, so it has an entry.
    t:wait_for(function()
      return compile._last_win[split] ~= nil
    end)
    t:feed(":close<CR>")
    t:wait_for(function()
      return #nx.win.list() == 1
    end)
    line.refresh()
    nudge(t)
    t:wait_for(function()
      return compile._last_win[split] == nil
    end)
    nx.test.expect(compile._last_win[split]).to_be_nil()
  end)

  -- Clearing our tabline restored `'tabline'` but left `'showtabline'` at 2, so an
  -- empty bar kept occupying a screen row.
  nx.test.it("restores 'showtabline' when the tabline is configured away", function(t)
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
    nx.test.expect(vim.o.showtabline).to_be(2)
    line.setup({
      options = { globalstatus = true },
      sections = { lualine_c = { "filename" } },
    })
    nudge(t)
    nx.test.expect(vim.o.tabline).to_be("")
    nx.test.expect(vim.o.showtabline).to_be(before)
  end)
end)

nx.test.describe("nxvim-line.config strictness", function()
  -- A typo'd section key silently dropped every component in it — the config looked
  -- accepted and the bar was just wrong.
  nx.test.it("errors on an unknown section key", function()
    nx.test
      .expect(function()
        line.setup({ sections = { lualine_d = { "mode" } } })
      end)
      .to_error("lualine_d")
  end)

  nx.test.it("errors on an unknown key in inactive_sections and tabline too", function()
    nx.test
      .expect(function()
        line.setup({ inactive_sections = { lualine_q = { "mode" } } })
      end)
      .to_error("lualine_q")
    nx.test
      .expect(function()
        line.setup({ tabline = { nope = { "mode" } } })
      end)
      .to_error("nope")
  end)
end)

nx.test.describe("nxvim-line.git robustness", function()
  -- `run_fetch` released its slot inline and again from the promise's `catch`. An
  -- `on_update` callback that throws took both paths, so `_active` drifted below zero
  -- and the concurrency cap stopped capping.
  nx.test.it("releases its concurrency slot exactly once when on_update throws", function(t)
    git.deactivate()
    git._cache = {}
    git._active = 0
    git.activate(function()
      error("on_update blew up")
    end)
    git.ensure(nx.buf.current())
    t:wait_for(function()
      return git._active == 0 and next(git._inflight) == nil
    end)
    nx.test.expect(git._active).to_be(0)
    git.deactivate()
  end)

  -- A fetch that fails must still record *something*, or `ensure` (which fires on
  -- every render for an uncached key) re-runs it forever.
  nx.test.it("caches a failed fetch so ensure stops re-running it", function(t)
    git.deactivate()
    git._cache = {}
    git._active = 0
    git._stats.runs = 0
    local head = nx.git.head
    nx.git.head = function()
      return nx.promise(function(_, reject)
        reject("simulated git failure")
      end)
    end
    git.activate(function() end)
    local buf = nx.buf.current()
    git.ensure(buf)
    t:wait_for(function()
      return git._cache[nx.buf.name(buf) ~= "" and nx.buf.name(buf) or vim.fn.getcwd()] ~= nil
    end)
    local runs = git._stats.runs
    for _ = 1, 10 do
      git.ensure(buf)
    end
    nx.test.expect(git._stats.runs).to_be(runs)
    nx.git.head = head
    git.deactivate()
  end)
end)

nx.test.describe("nxvim-line.icons strictness", function()
  -- A malformed spec used to store `nil`, silently un-registering nothing and leaving
  -- the caller to wonder why their glyph never showed.
  nx.test.it("errors on a malformed glyph spec instead of storing nil", function()
    nx.test
      .expect(function()
        icons.register({ zzz = 42 })
      end)
      .to_error("glyph")
    nx.test
      .expect(function()
        icons.register({ name = { ["Zzzfile"] = {} } })
      end)
      .to_error("glyph")
    -- A well-formed one still registers (both spellings).
    icons.register({ zzz = "\u{f15b}", name = { ["Zzzfile"] = { glyph = "\u{f15c}" } } })
    nx.test.expect(icons._by_ext.zzz).to_be("\u{f15b}")
    nx.test.expect(icons._by_name.Zzzfile).to_be("\u{f15c}")
  end)
end)
