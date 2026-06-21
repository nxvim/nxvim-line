-- nxvim-line.compile: lower a validated config onto the native nx.statusline segment
-- registry. One custom segment per non-empty lualine section (`NxLineA`..`NxLineZ`);
-- its `render(ctx)` walks the section's components and concatenates their cells.
--
-- nx.statusline owns layout activation AND the event->invalidate wiring: we hand each
-- segment the *union* of its components' declared `events`, and `nx.statusline.setup`
-- registers one invalidating autocmd per (segment, event) and replaces them on every
-- call. So `build()` is idempotent with no bookkeeping here — re-running it overwrites
-- the segments by name and re-activates the layout; a section dropped from the new
-- config is simply no longer referenced.
--
-- (`NxLine*` here are nx.statusline SEGMENT registry names — a private namespace,
-- distinct from the `lualine_<section>_<mode>` HIGHLIGHT groups Phase 4 will define.)

local components = require("nxvim-line.components")

local M = {}

local SECTION_SEGMENT = {
  lualine_a = "NxLineA",
  lualine_b = "NxLineB",
  lualine_c = "NxLineC",
  lualine_x = "NxLineX",
  lualine_y = "NxLineY",
  lualine_z = "NxLineZ",
}
local LEFT = { "lualine_a", "lualine_b", "lualine_c" }
local RIGHT = { "lualine_x", "lualine_y", "lualine_z" }

-- The segment names of the most recent build (for refresh()/invalidate_all).
M._active = {}

-- Render one section: each component -> a padded cell (` text `). A component whose
-- `provide` errors becomes a loud ` E:<name> ` cell rather than killing the whole
-- section; a nil/empty result contributes nothing. (Per-side padding / separators are
-- Phase 3; Phase 1 pads each component by one space, lualine's default.)
local function render_section(comps, ctx)
  local cells = {}
  for _, comp in ipairs(comps) do
    local spec = components.get(comp.name)
    local ok, cell = pcall(spec.provide, ctx, comp)
    if not ok then
      cells[#cells + 1] = { text = " E:" .. comp.name .. " ", hl = "ErrorMsg" }
    elseif type(cell) == "table" and type(cell.text) == "string" and cell.text ~= "" then
      cells[#cells + 1] = { text = " " .. cell.text .. " ", hl = cell.hl }
    end
  end
  return cells
end

-- The de-duplicated, order-preserving union of a section's components' declared events.
local function union_events(comps)
  local seen, out = {}, {}
  for _, comp in ipairs(comps) do
    for _, ev in ipairs(components.get(comp.name).events) do
      if not seen[ev] then
        seen[ev] = true
        out[#out + 1] = ev
      end
    end
  end
  return out
end

local function build_side(config, keys, out)
  for _, sec in ipairs(keys) do
    local comps = config.sections[sec]
    if comps and #comps > 0 then
      local segname = SECTION_SEGMENT[sec]
      nx.statusline.segment({
        name = segname,
        events = union_events(comps),
        render = function(ctx)
          return render_section(comps, ctx)
        end,
      })
      out[#out + 1] = segname
    end
  end
end

-- build(config): (re)build the live statusline. Idempotent — see the module note.
function M.build(config)
  local left, right = {}, {}
  build_side(config, LEFT, left)
  build_side(config, RIGHT, right)

  vim.o.laststatus = config.options.globalstatus and 3 or 2
  nx.statusline.setup({ left = left, right = right })

  M._active = {}
  for _, n in ipairs(left) do
    M._active[#M._active + 1] = n
  end
  for _, n in ipairs(right) do
    M._active[#M._active + 1] = n
  end
end

-- invalidate_all(): force a re-render of every active section (the public refresh()).
function M.invalidate_all()
  for _, name in ipairs(M._active) do
    nx.statusline.invalidate(name)
  end
end

return M
