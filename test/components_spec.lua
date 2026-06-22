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
    line.setup({ options = { globalstatus = true }, sections = { lualine_b = { "diagnostics" } } })
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

  nx.test.it("rejects a deferred component with a clear reason", function()
    nx.test
      .expect(function()
        line.setup({ sections = { lualine_x = { "fileformat" } } })
      end)
      .to_error("not available yet")
    nx.test
      .expect(function()
        line.setup({ sections = { lualine_z = { "searchcount" } } })
      end)
      .to_error("not available yet")
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
    t:cmd("edit " .. dir .. "/a.txt")
    local sl = t:wait_for(function()
      local s = t:statusline()
      return s:find("testbranch") and s:find("%+1") and s
    end)
    nx.test.expect(sl).to_contain("testbranch")
    nx.test.expect(sl).to_contain("+1")
  end)
end)
