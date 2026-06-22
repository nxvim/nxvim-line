-- nxvim-line.highlights — per-component colour groups + the gui-attr translation.
--
-- A lualine `color` is either a highlight-group NAME (used as the cell `hl` unchanged —
-- the cell links to it) or a `{ fg, bg, sp, gui }` table. A table is *interned*: defined
-- once as a generated `NxLineColor<N>` group via `nx.hl.define` and cached by a canonical
-- key so repeated renders reuse the same group. `reset()` clears the cache + counter on
-- each fresh setup() so the group names never grow unbounded across rebuilds (the
-- idempotent-setup contract).
--
-- Phase 4 adds the THEME groups: a `lualine_<section>_<mode>` group per (section, mode)
-- from the resolved palette (lualine's own naming, so a colorscheme/user override of those
-- groups just applies), and the SECTION powerline-separator transition groups, whose two
-- colours ARE the adjacent sections' palette backgrounds.

local M = {}

local cache = {} -- canonical color key -> generated group name
local counter = 0
local theme_palette = nil -- the normalized palette of the current build (for transitions)
local sep_cache = {} -- defined transition-group names (idempotency)

-- reset(): drop the interned-colour cache + theme state (start of each build()).
function M.reset()
  cache = {}
  counter = 0
  theme_palette = nil
  sep_cache = {}
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

-- ----- theme groups (Phase 4) ------------------------------------------------

local SECTIONS = { "a", "b", "c", "x", "y", "z" }
local MODES = { "normal", "insert", "visual", "replace", "command", "terminal", "inactive" }

-- Define one `lualine_<section>_<mode>` group from its palette cell: a string cell LINKS
-- to that group, a `{ fg, bg, gui }` cell is concrete (with the gui attrs expanded).
local function define_cell(name, cell)
  if type(cell) == "string" then
    nx.hl.define(0, name, { link = cell })
  elseif type(cell) == "table" then
    local spec = { fg = cell.fg, bg = cell.bg, sp = cell.sp }
    if cell.gui ~= nil then
      apply_gui(spec, cell.gui)
    end
    nx.hl.define(0, name, spec)
  end
end

-- define_theme(palette): predefine every `lualine_<section>_<mode>` group up front from a
-- NORMALIZED palette (themes.normalize), and stash the palette so transition_group can read
-- adjacent section backgrounds. Nothing is created on the hot path after this.
function M.define_theme(palette)
  theme_palette = palette
  for _, mode in ipairs(MODES) do
    local secs = palette[mode]
    if secs then
      for _, sec in ipairs(SECTIONS) do
        define_cell("lualine_" .. sec .. "_" .. mode, secs[sec])
      end
    end
  end
end

-- section_group(sec, mode) -> the lualine group name a section's cells paint in.
function M.section_group(sec, mode)
  return "lualine_" .. sec .. "_" .. mode
end

-- transition_group(from, to, mode) -> a group for a powerline separator cell: its glyph is
-- drawn `fg = from-section bg`, `bg = to-section bg`, so the arrow reads as a solid colour
-- transition. Defined lazily + cached. A string-link palette cell has no readable bg, so
-- the side falls back to nil (a degraded, uncoloured transition) rather than erroring.
function M.transition_group(from, to, mode)
  local name = "NxLineSep_" .. from .. "_" .. to .. "_" .. mode
  if sep_cache[name] then
    return name
  end
  local p = theme_palette and theme_palette[mode]
  local from_cell, to_cell = p and p[from], p and p[to]
  nx.hl.define(0, name, {
    fg = type(from_cell) == "table" and from_cell.bg or nil,
    bg = type(to_cell) == "table" and to_cell.bg or nil,
  })
  sep_cache[name] = true
  return name
end

return M
