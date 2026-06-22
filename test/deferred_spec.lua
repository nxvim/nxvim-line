-- Previously-deferred features now implemented: inline-function components and the
-- searchcount component (pure-Lua via the read-only `/` register + nx.buf.search).
--
--     nxvim --test-plugin ~/work/nxvim-plugins/nxvim-line

local line = require("nxvim-line")

local function nudge(t)
  t:feed("<Esc>")
end

nx.test.describe("nxvim-line.inline", function()
  nx.test.it("an inline function component renders its returned text", function(t)
    line.setup({
      options = { globalstatus = true },
      sections = {
        lualine_c = {
          function()
            return "INLINE-X"
          end,
        },
      },
    })
    nudge(t)
    local sl = t:wait_for(function()
      local s = t:statusline()
      return s:find("INLINE%-X") and s
    end)
    nx.test.expect(sl).to_contain("INLINE-X")
  end)

  nx.test.it("an inline function table honours its options (fmt)", function(t)
    line.setup({
      options = { globalstatus = true },
      sections = {
        lualine_c = {
          {
            function()
              return "ABC"
            end,
            fmt = function(s)
              return s:lower()
            end,
          },
        },
      },
    })
    nudge(t)
    local sl = t:wait_for(function()
      local s = t:statusline()
      return s:find("abc") and s
    end)
    nx.test.expect(sl).to_contain("abc")
  end)
end)

nx.test.describe("nxvim-line.searchcount", function()
  nx.test.it("shows nothing with no search pattern", function()
    -- Pure: the `/` register starts empty in a fresh session → no cell.
    local components = require("nxvim-line.components")
    if vim.fn.getreg("/") == "" then
      local cell = components.get("searchcount").provide({
        buf = nx.buf.current(),
        win = nx.win.current(),
      }, {})
      nx.test.expect(cell).to_be_nil()
    end
  end)

  nx.test.it("shows the match index and total for the last search", function(t)
    line.setup({
      options = { globalstatus = true },
      sections = { lualine_z = { "searchcount" } },
    })
    nudge(t)
    nx.await(nx.buf.set_lines(0, 0, -1, false, { "foo one", "two foo", "foo three" }))
    t:feed("gg")
    t:feed("/foo<CR>") -- three matches; cursor lands on one of them
    local sl = t:wait_for(function()
      local s = t:statusline()
      return s:find("%[%d/3%]") and s
    end)
    nx.test.expect(sl).to_contain("/3]")
    t:feed("<Esc>")
  end)
end)

nx.test.describe("nxvim-line.fileformat", function()
  nx.test.it("shows the buffer's line-ending style (dos for a CRLF file)", function(t)
    local dir = nx.test.tempdir()
    nx.await(nx.fs.write(dir .. "/crlf.txt", "one\r\ntwo\r\n"))
    line.setup({
      options = { globalstatus = true },
      sections = { lualine_x = { "fileformat" } },
    })
    nudge(t)
    t:feed(":edit " .. dir .. "/crlf.txt<CR>")
    local sl = t:wait_for(function()
      local s = t:statusline()
      return s:find("dos") and s
    end)
    nx.test.expect(sl).to_contain("dos")
  end)
end)
