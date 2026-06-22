-- nxvim-line.highlights — per-component colour groups + the gui-attr translation.
--
-- A lualine `color` is either a highlight-group NAME (used as the cell `hl` unchanged —
-- the cell links to it) or a `{ fg, bg, sp, gui }` table. A table is *interned*: defined
-- once as a generated `NxLineColor<N>` group via `nx.hl.define` and cached by a canonical
-- key so repeated renders reuse the same group. `reset()` clears the cache + counter on
-- each fresh setup() so the group names never grow unbounded across rebuilds (the
-- idempotent-setup contract).
--
-- Scope note: SECTION-level powerline separators — whose two colours ARE the adjacent
-- sections' background colours — depend on the theme's `lualine_<section>_<mode>` groups,
-- which land in Phase 4; they ship there. Phase 3 owns COMPONENT separators (drawn in the
-- section's own highlight), padding, icons, and this per-component `color`.

local M = {}

local cache = {} -- canonical color key -> generated group name
local counter = 0

-- reset(): drop the interned-colour cache (called at the start of each build()).
function M.reset()
  cache = {}
  counter = 0
end

-- lualine's `gui = "bold,italic"` string → the nx.hl boolean attrs.
local GUI_ATTRS = {
  bold = true,
  italic = true,
  underline = true,
  undercurl = true,
  strikethrough = true,
  reverse = true,
}
local function apply_gui(spec, gui)
  for attr in tostring(gui):gmatch("[^, ]+") do
    if GUI_ATTRS[attr] then
      spec[attr] = true
    end
  end
end

local function key_of(color)
  return table.concat({
    tostring(color.fg or ""),
    tostring(color.bg or ""),
    tostring(color.sp or ""),
    tostring(color.gui or ""),
  }, "|")
end

-- color_group(color) -> a highlight-group name for a cell `hl`. `color` is a string (a
-- group name, returned as-is) or a `{ fg, bg, sp, gui }` table (interned + defined).
function M.color_group(color)
  if type(color) == "string" then
    return color
  end
  if type(color) ~= "table" then
    error("nxvim-line: a component `color` must be a string (group) or a { fg, bg, gui } table")
  end
  local k = key_of(color)
  if cache[k] then
    return cache[k]
  end
  counter = counter + 1
  local name = "NxLineColor" .. counter
  local spec = { fg = color.fg, bg = color.bg, sp = color.sp }
  if color.gui ~= nil then
    apply_gui(spec, color.gui)
  end
  nx.hl.define(0, name, spec)
  cache[k] = name
  return name
end

return M
