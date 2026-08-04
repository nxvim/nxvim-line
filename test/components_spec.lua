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

  -- The default `path` is 1 (relative to cwd), not lualine's bare tail: two buffers
  -- named `mod.rs` are indistinguishable by tail alone. `path = 0` still opts back in,
  -- and the 0 must survive the `or`-default (0 is truthy in Lua, so it does).
  nx.test.it("filename defaults to the cwd-relative path, not the tail", function(t)
    local dir = nx.test.tempdir()
    nx.await(nx.fs.mkdir(dir .. "/sub"))
    nx.await(nx.fs.write(dir .. "/sub/deep.txt", "hi\n"))
    line.setup({ options = { globalstatus = true }, sections = { lualine_c = { "filename" } } })
    t:feed(":cd " .. dir .. "<CR>")
    t:feed(":edit sub/deep.txt<CR>")
    local sl = t:wait_for(function()
      local s = t:statusline()
      return s:find("sub/deep%.txt") and s
    end)
    nx.test.expect(sl).to_contain("sub/deep.txt")

    -- and an explicit `path = 0` still renders the tail alone
    local cell = components.get("filename").provide({
      buf = nx.buf.current(),
      win = nx.win.current(),
    }, { path = 0 })
    nx.test.expect(cell.text).to_be("deep.txt")
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

  nx.test.it("a synthetic panel (:messages) resolves no git branch", function(t)
    -- A scratch listing like :messages carries a bracketed placeholder name
    -- ([Messages]) — never a real file path. It must NOT inherit the launch
    -- directory's branch (the old dir_of fell back to "." = cwd for a slash-less
    -- name, so a session started inside a repo leaked that repo's branch onto the
    -- panel). Statusline without branch so opening the panel doesn't itself fetch;
    -- we drive git.ensure directly — exactly what the branch component does per render.
    line.setup({ options = { globalstatus = true }, sections = { lualine_c = { "filename" } } })
    t:feed(":messages<CR>")
    local cur = nx.buf.current()
    -- The panel is a nofile scratch surface — the neovim-idiomatic signal the git
    -- source gates on so it never resolves a branch for a non-file buffer.
    nx.test.expect(nx.bo[cur].buftype).to_be("nofile")
    -- Clear any git-module state left by earlier tests (shared per-process) so this
    -- measures ONLY what ensure() does for [Messages]: a bare cache/inflight/debounce,
    -- a free concurrency slot, no lingering autocmds.
    git.deactivate()
    git._cache, git._inflight, git._queue, git._active = {}, {}, {}, 0
    local before = git._stats.runs
    git.ensure(cur)
    nx.test.expect(git._stats.runs).to_be(before) -- no git run kicked for a synthetic buffer
    nx.test.expect(git.get(cur)).to_be_nil()
    -- and the branch component renders nothing on it
    local cell = components.get("branch").provide({ buf = cur, win = nx.win.current() })
    nx.test.expect(cell).to_be_nil()
  end)
end)

-- A plugin surface (a file tree, a diff pane, a panel, the quickfix window, a terminal)
-- is not a file, and the file-describing components have nothing true to say about it:
-- its filetype is the widget's own tag, and it has no encoding and no line endings. They
-- opt out declaratively with `file_only`, resolved against the CANONICAL editor signal —
-- `'buftype'`, which the core reports as `nofile` for an `nx.view` — rather than by
-- sniffing the buffer's name. The buffer's NAME still shows: that is what labels the pane.
nx.test.describe("nxvim-line file-only components", function()
  -- Build a view (the surface every plugin pane is made of) and focus it, so the global
  -- bar renders against a `buftype = "nofile"` buffer.
  -- Every view a test opens, torn down in after_each. Cleanup must NOT sit at the end of
  -- each test: a failing assertion aborts the body, and a leaked view window then renders
  -- the global bar for the wrong buffer, cascading failures through the whole suite.
  local opened = {}

  nx.test.after_each(function()
    for _, vw in ipairs(opened) do
      pcall(function()
        vw:close()
      end)
    end
    opened = {}
    nx.layer.main()
  end)

  local function open_view(t, name)
    local vw = nx.view.create({ name = name or "ourpane", filetype = "ourpane" })
    opened[#opened + 1] = vw
    vw:set_lines({ "one", "two" })
    vw:mount({ split = "vsplit" })
    vw:focus()
    t:wait_for(function()
      return nx.buf.current() == vw:bufnr()
    end)
    t:feed("<Esc>")
    return vw
  end

  nx.test.it("reports a view as a non-file buffer via 'buftype'", function(t)
    local vw = open_view(t)
    -- The canonical signal, straight from the core — no name matching anywhere.
    nx.test.expect(nx.bo[vw:bufnr()].buftype).to_be("nofile")
    nx.test.expect(components.is_file_buffer(vw:bufnr())).to_be(false)
    nx.test.expect(components.is_file_buffer(nx.buf.current())).to_be(false)
  end)

  nx.test.it("drops filetype / encoding / fileformat on a plugin surface", function(t)
    line.setup({
      options = { globalstatus = true },
      sections = {
        lualine_c = { "filename" },
        lualine_x = { "encoding", "fileformat", "filetype" },
      },
    })
    nudge(t)
    -- On a real file buffer they all render.
    local file_bar = t:wait_for(function()
      local s = t:statusline()
      return s:find("utf%-8") and s
    end)
    nx.test.expect(file_bar).to_contain("utf-8")

    -- On the view: the name stays, the file-describing three are gone.
    local vw = open_view(t)
    local bar = t:wait_for(function()
      local s = t:statusline()
      return s:find("ourpane") and s
    end)
    nx.test.expect(bar).to_contain("ourpane") -- the pane's NAME still labels it
    nx.test.expect(bar).never.to_contain("utf-8") -- encoding
    nx.test.expect(bar).never.to_contain("unix") -- line endings
  end)

  nx.test.it("lets a component opt back in with file_only = false", function(t)
    line.setup({
      options = { globalstatus = true },
      sections = { lualine_x = { { "encoding", file_only = false } } },
    })
    nudge(t)
    local vw = open_view(t)
    local bar = t:wait_for(function()
      local s = t:statusline()
      return s:find("utf%-8") and s
    end)
    nx.test.expect(bar).to_contain("utf-8")
  end)

  nx.test.it("lets a custom component opt IN with file_only = true", function(t)
    components.register("mytag", {
      events = { "BufEnter" },
      provide = function()
        return { text = "MYTAG" }
      end,
    })
    line.setup({
      options = { globalstatus = true },
      sections = { lualine_x = { { "mytag", file_only = true } } },
    })
    nudge(t)
    local on_file = t:wait_for(function()
      local s = t:statusline()
      return s:find("MYTAG") and s
    end)
    nx.test.expect(on_file).to_contain("MYTAG")

    local vw = open_view(t)
    t:wait_for(function()
      return not t:statusline():find("MYTAG")
    end)
    nx.test.expect(t:statusline()).never.to_contain("MYTAG")
  end)
end)
