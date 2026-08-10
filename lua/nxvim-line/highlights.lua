-- nxvim-line.highlights — per-component colour groups + the gui-attr translation.
--
-- A lualine `color` is either a highlight-group NAME (used as the cell `hl` unchanged —
-- the cell links to it) or a `{ fg, bg, sp, gui }` table. A table is *interned*: defined
-- once as a generated `NxLineColor<N>` group via `nx.hl.define` and cached by a canonical
-- key so repeated renders reuse the same group. `reset()` clears the cache + counter on
-- each fresh setup() so the group names never grow unbounded across rebuilds (the
-- idempotent-setup contract).
--
-- A cell that carries its own colour (a diff count, a diagnostic count) names a
-- foreground through `accent`, and `fg_on_section` puts it on the surrounding section's
-- background — a cell hl is a whole group, and a client fills what it leaves unset from
-- the bar's `StatusLine`, not from the section.
--
-- Phase 4 adds the THEME groups: a `lualine_<section>_<mode>` group per (section, mode)
-- from the resolved palette (lualine's own naming, so a colorscheme/user override of those
-- groups just applies), and the SECTION powerline-separator transition groups, whose two
-- colours ARE the adjacent sections' palette backgrounds.

local M = {}

local cache = {} -- canonical color key -> generated group name
local fg_cache = {} -- "<group>|<section>" -> generated merged group name
local accent_cache = {} -- "<group,group,…>|<hue>" -> generated accent group name
-- One counter per generated-group FAMILY: a family's names must not shift because a
-- sibling family interned something first (each is `<prefix><n>`, numbered from 1 per
-- build, so a given colour keeps a stable name across renders).
local counter = 0
local fg_counter = 0
local accent_counter = 0
local theme_palette = nil -- the normalized palette of the current build (for transitions)
local sep_cache = {} -- defined transition-group names (idempotency)

-- reset(): drop the interned-colour cache + theme state (start of each build()).
function M.reset()
  cache = {}
  fg_cache = {}
  accent_cache = {}
  counter = 0
  fg_counter = 0
  accent_counter = 0
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

-- ----- cells that carry their own colour -------------------------------------

-- The gui attrs a cell inherits from the group it borrows its foreground from.
local FG_ATTRS = { "bold", "italic", "underline", "undercurl", "strikethrough", "reverse" }

-- accent(chain, hue) -> a generated FOREGROUND-ONLY group holding the colour the active
-- theme means for a semantic count (an added-lines count, an error count).
--
-- `chain` is the canonical groups that carry that meaning, most specific first; the first
-- one defining a foreground wins. When the theme defines none of them the colour comes
-- from `nx.hl.palette()[hue]` — the editor's own reading of the theme's hues, each
-- resolved through its own chain — so the count still lands in the running colorscheme's
-- palette instead of a hardcoded hex belonging to some other theme.
--
-- Only the FOREGROUND is taken, which is the whole point: `DiffAdd` is a diff-view
-- background wash (catppuccin defines it with no foreground at all) and would paint the
-- count as a coloured block on the bar. The group returned here is foreground-only by
-- construction, so `fg_on_section` below can put it on the section's background. This is
-- lualine's `extract_color_from_hllist` + `create_component_highlight_group` pair, with
-- the palette standing in for lualine's hardcoded default colours.
function M.accent(chain, hue)
  local key = table.concat(chain, ",") .. "|" .. hue
  if accent_cache[key] then
    return accent_cache[key]
  end
  local fg
  for _, name in ipairs(chain) do
    local def = nx.hl.get(0, { name = name, link = false })
    if type(def.fg) == "number" then
      fg = def.fg
      break
    end
  end
  accent_counter = accent_counter + 1
  local name = "NxLineAccent" .. accent_counter
  nx.hl.define(0, name, { fg = fg or nx.hl.palette()[hue] })
  accent_cache[key] = name
  return name
end

-- fg_on_section(group, section) -> the group a cell carrying its OWN colour must paint in:
-- `group`'s FOREGROUND (plus its gui attrs) over `section`'s BACKGROUND. Interned + cached
-- per (group, section) pair, so a render is a lookup.
--
-- A cell hl is a whole highlight group, and a client paints an attribute the group leaves
-- unset from the BAR's base group (`StatusLine`) — not from the section around the cell,
-- which is only the previous cell's group. So a foreground-only group used verbatim
-- rendered its cell on the StatusLine background: a dark block inside a lighter section
-- for every theme whose section bg differs from StatusLine's (catppuccin: `surface0` over
-- `mantle`). Real lualine has exactly this constraint and answers it the same way — its
-- component highlights merge a colour over the theme's section colours.
--
-- A group that names a BACKGROUND is left alone: it means to paint a block, and the block
-- is the point (a `color = { fg =, bg = }`, a custom component's badge). Two degenerate
-- cases fall back rather than generate a group: a section with no readable background (a
-- string-link palette cell) leaves the cell's own group alone, and a group with neither
-- colour contributes nothing, so the section's own group is strictly better.
function M.fg_on_section(group, section)
  if type(group) ~= "string" or type(section) ~= "string" or group == section then
    return group
  end
  local k = group .. "|" .. section
  if fg_cache[k] then
    return fg_cache[k]
  end
  local src = nx.hl.get(0, { name = group, link = false })
  local sec = nx.hl.get(0, { name = section, link = false })
  if src.bg ~= nil or sec.bg == nil then
    fg_cache[k] = group
    return group
  end
  if src.fg == nil then
    fg_cache[k] = section
    return section
  end
  fg_counter = fg_counter + 1
  local name = "NxLineFg" .. fg_counter
  local spec = { fg = src.fg, bg = sec.bg, sp = src.sp }
  for _, attr in ipairs(FG_ATTRS) do
    if src[attr] then
      spec[attr] = true
    end
  end
  nx.hl.define(0, name, spec)
  fg_cache[k] = name
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
-- adjacent section backgrounds.
--
-- This covers every group a section's CELLS can take, so picking a highlight by mode is
-- pure lookup on the hot path. The powerline TRANSITION groups stay lazy instead: the full
-- product is 6 sections x 6 neighbours x 7 modes = 252 groups, of which a given layout uses
-- a handful, so `transition_group` defines each on first use and caches it (one definition
-- per build, then lookups).
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
