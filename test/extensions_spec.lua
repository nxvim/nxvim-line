-- Phase 7 — extensions, disabled filetypes, and tabline lowering. A buffer's filetype is
-- set with btv.bo and the bar re-rendered with line.refresh(); the tabline `%`-format is
-- read off compile._tabline() and the wired options.
--
--     bemtvi --test-plugin ~/work/bemtvi-plugins/bemtvi-line

local line = require("bemtvi-line")
local compile = require("bemtvi-line.compile")

local function nudge(t)
  t:feed("<Esc>")
end

-- fresh_slate reuses the [No Name] buffer between tests, so a filetype set here would leak
-- into the next test; reset it explicitly when a test is done with it.
local function clear_ft()
  btv.bo[0].filetype = ""
end

btv.test.describe("bemtvi-line.extensions", function()
  btv.test.it("a disabled filetype renders an empty bar", function(t)
    line.setup({
      options = { globalstatus = true, disabled_filetypes = { statusline = { "qf" } } },
      sections = { lualine_a = { "mode" } },
    })
    nudge(t)
    t:wait_for(function()
      return t:statusline():find("NORMAL")
    end)
    -- mark the buffer 'qf' (a disabled filetype) and re-render: the bar goes blank
    btv.bo[0].filetype = "qf"
    line.refresh()
    nudge(t)
    t:wait_for(function()
      return not t:statusline():find("NORMAL")
    end)
    btv.test.expect(t:statusline()).never.to_contain("NORMAL")
    clear_ft()
  end)

  btv.test.it("an extension layout replaces the sections for its filetype", function(t)
    line.setup({
      options = { globalstatus = true },
      sections = { lualine_a = { "mode" } },
      extensions = { "quickfix" },
    })
    nudge(t)
    t:wait_for(function()
      return t:statusline():find("NORMAL")
    end)
    -- a quickfix buffer shows the extension's label, not the base `mode` component
    btv.bo[0].filetype = "qf"
    line.refresh()
    nudge(t)
    local sl = t:wait_for(function()
      local s = t:statusline()
      return s:find("Quickfix") and s
    end)
    btv.test.expect(sl).to_contain("Quickfix")
    btv.test.expect(sl).never.to_contain("NORMAL")
    clear_ft()
  end)

  btv.test.it("an unknown extension name errors loud", function()
    btv.test
      .expect(function()
        line.setup({ extensions = { "no-such-extension" } })
      end)
      .to_error("unknown extension")
  end)

  btv.test.it("a custom extension is honoured", function(t)
    line.setup({
      options = { globalstatus = true },
      sections = { lualine_a = { "mode" } },
      extensions = {
        { filetypes = { "myft" }, sections = { lualine_a = { { "label", text = "MINE" } } } },
      },
    })
    nudge(t)
    t:wait_for(function()
      return t:statusline():find("NORMAL")
    end)
    btv.bo[0].filetype = "myft"
    line.refresh()
    nudge(t)
    local sl = t:wait_for(function()
      local s = t:statusline()
      return s:find("MINE") and s
    end)
    btv.test.expect(sl).to_contain("MINE")
    clear_ft()
  end)
end)

btv.test.describe("bemtvi-line.tabline", function()
  btv.test.it("lowers the tabline config onto a %-format dispatcher", function(t)
    line.setup({
      options = { globalstatus = true },
      sections = { lualine_a = { "mode" } },
      tabline = { lualine_a = { { "label", text = "TABTITLE" } }, lualine_z = { "location" } },
    })
    nudge(t)
    -- the 'tabline' option points at our live dispatcher, and showtabline is on
    btv.test.expect(vim.o.tabline:find("_tabline")).never.to_be_nil()
    btv.test.expect(vim.o.tabline:find("v:lua")).never.to_be_nil()
    btv.test.expect(vim.o.showtabline).to_be(2)
    -- the rendered %-format carries the component text + a %#group# highlight run and a %=
    local fmt = compile._tabline()
    btv.test.expect(fmt:find("TABTITLE")).never.to_be_nil()
    btv.test.expect(fmt:find("#lualine_a")).never.to_be_nil()
    btv.test.expect(fmt:find("%%=")).never.to_be_nil()
  end)

  btv.test.it("clears its tabline when reconfigured without one", function(t)
    line.setup({
      options = { globalstatus = true },
      sections = { lualine_a = { "mode" } },
      tabline = { lualine_a = { { "label", text = "X" } } },
    })
    nudge(t)
    btv.test.expect(vim.o.tabline).never.to_be("")
    line.setup({ options = { globalstatus = true }, sections = { lualine_a = { "mode" } } })
    nudge(t)
    btv.test.expect(vim.o.tabline).to_be("")
  end)
end)
