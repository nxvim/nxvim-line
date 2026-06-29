-- The Phase-2 component library: filename flags, encoding, diagnostics, lsp, and the
-- git branch/diff source. Rendering is observed through the global bar (`t:statusline()`
-- mirrors `laststatus=3`), so these use `globalstatus = true`; some pure logic is
-- exercised directly.
--
--     nxvim --test-plugin ~/work/nxvim-plugins/nxvim-line

local line = require("nxvim-line")
local components = require("nxvim-line.components")
local git = require("nxvim-line.git")

local function nudge(t)
  t:feed("<Esc>")
end

nx.test.describe("nxvim-line.components", function()
  nx.test.it("filename shows [No Name] and the [+] modified flag", function(t)
    line.setup({ options = { globalstatus = true }, sections = { lualine_c = { "filename" } } })
    nudge(t)
    t:wait_for(function()
      return t:statusline():find("No Name")
    end)
    -- editing marks the buffer modified -> the [+] flag appears (on TextChanged)
    t:feed("ihello<Esc>")
    local sl = t:wait_for(function()
      local s = t:statusline()
      return s:find("%[%+%]") and s
    end)
    nx.test.expect(sl).to_contain("[+]")
  end)

  nx.test.it("encoding shows the file encoding", function(t)
    line.setup({ options = { globalstatus = true }, sections = { lualine_x = { "encoding" } } })
    nudge(t)
    local sl = t:wait_for(function()
      local s = t:statusline()
      return s:find("utf%-8") and s
    end)
    nx.test.expect(sl).to_contain("utf-8")
  end)

  nx.test.it("diagnostics counts injected diagnostics per severity", function(t)
    -- icons_enabled = false keeps the readable E:/W: letters (default is glyphs now).
    line.setup({
      options = { globalstatus = true, icons_enabled = false },
      sections = { lualine_b = { "diagnostics" } },
    })
    nudge(t)
    local ns = vim.api.nvim_create_namespace("nxline_diag_test")
    nx.diagnostic.set(ns, 0, {
      { lnum = 0, col = 0, severity = 1, message = "an error" },
      { lnum = 1, col = 0, severity = 2, message = "a warning" },
      { lnum = 2, col = 0, severity = 2, message = "another warning" },
    })
    line.refresh()
    nudge(t)
    local sl = t:wait_for(function()
      local s = t:statusline()
      return s:find("E:1") and s
    end)
    nx.test.expect(sl).to_contain("E:1")
    nx.test.expect(sl).to_contain("W:2")
    nx.diagnostic.reset(ns, 0)
  end)

  nx.test.it("lsp renders nothing when no client is attached", function()
    -- Pure: no LSP in the test session, so the component yields nil (no fake text).
    local cell = components.get("lsp").provide({ buf = nx.buf.current(), win = nx.win.current() })
    nx.test.expect(cell).to_be_nil()
  end)

  nx.test.it("daemon colours the connection phase and hides on a local session", function()
    -- Pure: drive `nx.daemon.status()` through its mirror and assert the per-phase colour.
    local daemon = components.get("daemon")
    nx._daemon_status = nil
    nx.test.expect(daemon.provide({})).to_be_nil() -- local session: nothing to show
    nx._daemon_status = "connected"
    local c = daemon.provide({})
    nx.test.expect(c.hl).to_equal("DiagnosticOk") -- green
    nx.test.expect(c.text:find("connected") ~= nil).to_equal(true)
    nx._daemon_status = "reconnecting"
    nx.test.expect(daemon.provide({}).hl).to_equal("DiagnosticWarn") -- yellow
    nx._daemon_status = "disconnected"
    nx.test.expect(daemon.provide({}).hl).to_equal("DiagnosticError") -- red
    nx._daemon_status = nil
  end)

  nx.test.it("daemon status shows in the bar and refreshes on DaemonStatusChanged", function(t)
    line.setup({
      options = { globalstatus = true, icons_enabled = false },
      sections = { lualine_x = { "daemon" } },
    })
    nudge(t)
    -- The server mirrors the phase + fires `User DaemonStatusChanged`; the section's
    -- declared event invalidates it, so the bar re-renders on the next tick.
    nx._set_daemon_status("connected")
    nudge(t)
    nx.test
      .expect(t:wait_for(function()
        local s = t:statusline()
        return s:find("connected") and s
      end))
      .to_contain("connected")
    -- A status change re-renders via the same event (proving the live update path).
    nx._set_daemon_status("disconnected")
    nudge(t)
    nx.test
      .expect(t:wait_for(function()
        local s = t:statusline()
        return s:find("disconnected") and s
      end))
      .to_contain("disconnected")
    nx._daemon_status = nil
  end)
end)

nx.test.describe("nxvim-line.git", function()
  -- Pure: hunk headers -> added/changed/removed.
  nx.test.it("_parse_diff classifies hunks", function()
    local out = table.concat({
      "@@ -0,0 +1,3 @@", -- 3 added
      "@@ -5,2 +7,0 @@", -- 2 removed
      "@@ -10,2 +12,2 @@", -- 2 changed
      "@@ -20 +22 @@", -- 1 changed (counts omitted = 1)
    }, "\n")
    local d = git._parse_diff(out)
    nx.test.expect(d.added).to_be(3)
    nx.test.expect(d.removed).to_be(2)
    nx.test.expect(d.changed).to_be(3)
  end)

  nx.test.it("branch + diff render for a real repo", function(t)
    local dir = nx.test.tempdir()
    local function g(...)
      local r = nx.await(nx.run({ cmd = "git", args = { "-C", dir, ... } }))
      if r.code ~= 0 then
        error("git " .. table.concat({ ... }, " ") .. " failed: " .. r.stderr, 0)
      end
    end
    g("init", "-q")
    g("config", "user.email", "t@example.com")
    g("config", "user.name", "Test")
    nx.await(nx.fs.write(dir .. "/a.txt", "one\ntwo\n"))
    g("add", "a.txt")
    g("commit", "-q", "-m", "init")
    g("branch", "-m", "testbranch") -- deterministic name (not master/main)
    -- a working-tree change vs HEAD: one added line
    nx.await(nx.fs.write(dir .. "/a.txt", "one\ntwo\nthree\n"))

    line.setup({
      options = { globalstatus = true },
      sections = { lualine_b = { "branch", "diff" } },
    })
    -- Drive :edit through the real input path so the lifecycle fires: loading the file
    -- advances the changedtick -> TextChanged -> the branch/diff segment re-renders ->
    -- git.ensure does the cache-miss fetch. (t:cmd bypasses that lifecycle path. a.txt
    -- has no filetype, so FileType does NOT fire here — TextChanged is the trigger.)
    t:feed(":edit " .. dir .. "/a.txt<CR>")
    local sl = t:wait_for(function()
      local s = t:statusline()
      return s:find("testbranch") and s:find("%+1") and s
    end)
    nx.test.expect(sl).to_contain("testbranch")
    nx.test.expect(sl).to_contain("+1")
  end)

  nx.test.it("debounce collapses a burst of refreshes into one git run", function(t)
    local dir = nx.test.tempdir()
    local function g(...)
      local r = nx.await(nx.run({ cmd = "git", args = { "-C", dir, ... } }))
      if r.code ~= 0 then
        error("git " .. table.concat({ ... }, " ") .. " failed: " .. r.stderr, 0)
      end
    end
    g("init", "-q")
    g("config", "user.email", "t@example.com")
    g("config", "user.name", "Test")
    nx.await(nx.fs.write(dir .. "/a.txt", "one\n"))
    g("add", "a.txt")
    g("commit", "-q", "-m", "init")
    g("branch", "-m", "burstbranch")

    line.setup({ options = { globalstatus = true }, sections = { lualine_b = { "branch" } } })
    t:feed(":edit " .. dir .. "/a.txt<CR>")
    -- let the first (immediate) fetch land so the cache is warm and nothing is inflight
    t:wait_for(function()
      return t:statusline():find("burstbranch")
    end)

    -- a burst of scheduled refreshes within the debounce window collapses to ONE fetch
    local before = git._stats.runs
    for _ = 1, 6 do
      git.schedule(nx.buf.current())
    end
    t:wait_for(function()
      return git._stats.runs > before
    end)
    nx.test.expect(git._stats.runs - before).to_be(1)
  end)

  nx.test.it("a non-repo buffer stays clean — no branch, no error", function(t)
    local dir = nx.test.tempdir() -- not a git repo
    nx.await(nx.fs.write(dir .. "/plain.txt", "hello\n"))
    line.setup({ options = { globalstatus = true }, sections = { lualine_b = { "branch" } } })
    t:feed(":edit " .. dir .. "/plain.txt<CR>")
    -- the fetch completes and caches an empty result (no repo) without erroring
    t:wait_for(function()
      return git.get(nx.buf.current()) ~= nil
    end)
    nx.test.expect(git.get(nx.buf.current()).branch).to_be_nil()
    -- and the branch component renders nothing
    local cell = components.get("branch").provide({
      buf = nx.buf.current(),
      win = nx.win.current(),
    })
    nx.test.expect(cell).to_be_nil()
  end)
end)
