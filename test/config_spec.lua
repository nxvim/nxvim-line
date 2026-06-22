-- Config merge + validation + component normalization. Pure (no editor state).
--
--     nxvim --test-plugin ~/work/nxvim-plugins/nxvim-line

local config = require("nxvim-line.config")
local line = require("nxvim-line")

nx.test.describe("nxvim-line.config", function()
  nx.test.it("defaults() hands out an independent copy each call", function()
    local a = config.defaults()
    local b = config.defaults()
    a.options.globalstatus = true
    a.sections.lualine_a = { "location" }
    nx.test.expect(b.options.globalstatus).to_be(false)
    nx.test.expect(b.sections.lualine_a[1]).to_be("mode")
  end)

  nx.test.it("merges options key-by-key and keeps untouched defaults", function()
    local cfg = config.merge(config.defaults(), {
      options = { globalstatus = true },
    })
    nx.test.expect(cfg.options.globalstatus).to_be(true)
    nx.test.expect(cfg.options.theme).to_be("auto")
  end)

  nx.test.it("replaces a section wholesale, leaves others at default", function()
    local cfg = config.merge(config.defaults(), {
      sections = { lualine_c = { "filetype", "location" } },
    })
    nx.test.expect(cfg.sections.lualine_c[1].name).to_be("filetype")
    nx.test.expect(cfg.sections.lualine_c[2].name).to_be("location")
    -- an untouched section keeps its default (normalized to a {name=} entry)
    nx.test.expect(cfg.sections.lualine_a[1].name).to_be("mode")
  end)

  nx.test.it("normalizes the string and table component spellings", function()
    local cfg = config.merge(config.defaults(), {
      sections = { lualine_c = { "filename", { "location" } } },
    })
    nx.test.expect(cfg.sections.lualine_c[1].name).to_be("filename")
    nx.test.expect(cfg.sections.lualine_c[2].name).to_be("location")
  end)

  nx.test.it("keeps a component table's per-component options", function()
    local cfg = config.merge(config.defaults(), {
      sections = { lualine_c = { { "filename", path = 1, icon = "f" } } },
    })
    local c = cfg.sections.lualine_c[1]
    nx.test.expect(c.name).to_be("filename")
    nx.test.expect(c.path).to_be(1)
    nx.test.expect(c.icon).to_be("f")
    -- the positional name slot is consumed, not left dangling
    nx.test.expect(c[1]).to_be_nil()
  end)

  nx.test.it("rejects an unknown component (fails loud)", function()
    nx.test
      .expect(function()
        config.merge(config.defaults(), { sections = { lualine_a = { "nope" } } })
      end)
      .to_error("unknown component")
  end)

  nx.test.it("normalizes an inline function component onto _inline", function()
    local fn = function()
      return "x"
    end
    local cfg = config.merge(config.defaults(), {
      sections = { lualine_a = { fn, { fn, color = "WarningMsg" } } },
    })
    -- a bare function and a `{ fn, opts }` table both keep the function on `_inline`
    nx.test.expect(cfg.sections.lualine_a[1]._inline).to_be(fn)
    nx.test.expect(cfg.sections.lualine_a[2]._inline).to_be(fn)
    nx.test.expect(cfg.sections.lualine_a[2].color).to_be("WarningMsg")
  end)

  nx.test.it("accepts a registered custom component", function()
    line.register_component("nxline_test_clock", {
      provide = function()
        return { text = "clock" }
      end,
    })
    local cfg = config.merge(config.defaults(), {
      sections = { lualine_a = { "nxline_test_clock" } },
    })
    nx.test.expect(cfg.sections.lualine_a[1].name).to_be("nxline_test_clock")
  end)
end)
