-- Config merge + validation + component normalization. Pure (no editor state).
--
--     bemtvi --test-plugin ~/work/bemtvi-plugins/bemtvi-line

local config = require("bemtvi-line.config")
local line = require("bemtvi-line")

btv.test.describe("bemtvi-line.config", function()
  btv.test.it("defaults() hands out an independent copy each call", function()
    local a = config.defaults()
    local b = config.defaults()
    a.options.globalstatus = true
    a.sections.lualine_a = { "location" }
    btv.test.expect(b.options.globalstatus).to_be(false)
    btv.test.expect(b.sections.lualine_a[1]).to_be("mode")
  end)

  btv.test.it("merges options key-by-key and keeps untouched defaults", function()
    local cfg = config.merge(config.defaults(), {
      options = { globalstatus = true },
    })
    btv.test.expect(cfg.options.globalstatus).to_be(true)
    btv.test.expect(cfg.options.theme).to_be("auto")
  end)

  -- `lsp` leads the default `lualine_x`: bemtvi ships LSP in the box, so the attached
  -- server is on the bar without any config. It collapses to nothing with no client
  -- attached, so a server-less buffer is unchanged.
  btv.test.it("ships lsp first in the default lualine_x", function()
    local cfg = config.merge(config.defaults(), {})
    local names = {}
    for i, c in ipairs(cfg.sections.lualine_x) do
      names[i] = c.name
    end
    btv.test.expect(table.concat(names, ",")).to_be("lsp,encoding,fileformat,filetype")
  end)

  btv.test.it("replaces a section wholesale, leaves others at default", function()
    local cfg = config.merge(config.defaults(), {
      sections = { lualine_c = { "filetype", "location" } },
    })
    btv.test.expect(cfg.sections.lualine_c[1].name).to_be("filetype")
    btv.test.expect(cfg.sections.lualine_c[2].name).to_be("location")
    -- an untouched section keeps its default (normalized to a {name=} entry)
    btv.test.expect(cfg.sections.lualine_a[1].name).to_be("mode")
  end)

  btv.test.it("normalizes the string and table component spellings", function()
    local cfg = config.merge(config.defaults(), {
      sections = { lualine_c = { "filename", { "location" } } },
    })
    btv.test.expect(cfg.sections.lualine_c[1].name).to_be("filename")
    btv.test.expect(cfg.sections.lualine_c[2].name).to_be("location")
  end)

  btv.test.it("keeps a component table's per-component options", function()
    local cfg = config.merge(config.defaults(), {
      sections = { lualine_c = { { "filename", path = 1, icon = "f" } } },
    })
    local c = cfg.sections.lualine_c[1]
    btv.test.expect(c.name).to_be("filename")
    btv.test.expect(c.path).to_be(1)
    btv.test.expect(c.icon).to_be("f")
    -- the positional name slot is consumed, not left dangling
    btv.test.expect(c[1]).to_be_nil()
  end)

  btv.test.it("rejects an unknown component (fails loud)", function()
    btv.test
      .expect(function()
        config.merge(config.defaults(), { sections = { lualine_a = { "nope" } } })
      end)
      .to_error("unknown component")
  end)

  btv.test.it("normalizes an inline function component onto _inline", function()
    local fn = function()
      return "x"
    end
    local cfg = config.merge(config.defaults(), {
      sections = { lualine_a = { fn, { fn, color = "WarningMsg" } } },
    })
    -- a bare function and a `{ fn, opts }` table both keep the function on `_inline`
    btv.test.expect(cfg.sections.lualine_a[1]._inline).to_be(fn)
    btv.test.expect(cfg.sections.lualine_a[2]._inline).to_be(fn)
    btv.test.expect(cfg.sections.lualine_a[2].color).to_be("WarningMsg")
  end)

  btv.test.it("accepts a registered custom component", function()
    line.register_component("btvline_test_clock", {
      provide = function()
        return { text = "clock" }
      end,
    })
    local cfg = config.merge(config.defaults(), {
      sections = { lualine_a = { "btvline_test_clock" } },
    })
    btv.test.expect(cfg.sections.lualine_a[1].name).to_be("btvline_test_clock")
  end)
end)
