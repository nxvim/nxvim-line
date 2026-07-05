-- nxvim-line.themes — lualine-shaped theme tables, their resolution, and the
-- colorscheme auto-derive.
--
-- A theme is a per-mode palette in lualine's EXACT shape so an existing lualine theme (or
-- a colorscheme's lualine integration, e.g. catppuccin) drops in unchanged:
--
--   { normal = { a = {fg,bg,gui}, b = {...}, c = {...} }, insert = {...}, visual,
--     replace, command, terminal, inactive }
--
-- Per lualine's rules, applied by `normalize`: x/y/z default to c/b/a, any unspecified
-- mode defaults to `normal`, and a section cell may be a `{fg,bg,gui}` table OR a string
-- naming a highlight group to LINK to (highlights.define_theme honors both).
--
-- Resolution (`resolve`): a table is used as-is; a string name resolves bundled →
-- `require("lualine.themes.<name>")` → hard error; `"auto"` derives a palette from the
-- active colorscheme via `nx.hl.get`. `register(name, table)` adds a bundled theme.

local M = {}

local ALL_MODES = { "normal", "insert", "visual", "replace", "command", "terminal", "inactive" }

-- nx.mode() short code → the theme's mode key. Visual-block (`\22` = <C-v>) maps to
-- visual; anything unrecognized falls back to `normal` (lualine's behaviour).
local MODE_OF = {
  n = "normal",
  i = "insert",
  v = "visual",
  V = "visual",
  ["\22"] = "visual",
  R = "replace",
  c = "command",
  t = "terminal",
  -- nxvim's multi-cursor placement mode. lualine themes have no multicursor
  -- palette, so reuse `visual` (the closest multi-selection colour) — distinct
  -- from normal, and defined by every theme.
  m = "visual",
}

function M.mode_of(code)
  return MODE_OF[code] or "normal"
end

-- ----- bundled themes --------------------------------------------------------

-- A clean powerline-dark default so a bare `setup()` (or a no-colorscheme session) reads
-- well. Only `a` recolours per mode; b/c are shared (normalize fills them in).
M.bundled = {
  default = {
    normal = {
      a = { fg = "#1c1c1c", bg = "#5fafff", gui = "bold" },
      b = { fg = "#c6c6c6", bg = "#3a3a3a" },
      c = { fg = "#c6c6c6", bg = "#1c1c1c" },
    },
    insert = { a = { fg = "#1c1c1c", bg = "#5faf5f", gui = "bold" } },
    visual = { a = { fg = "#1c1c1c", bg = "#d787d7", gui = "bold" } },
    replace = { a = { fg = "#1c1c1c", bg = "#ff5f5f", gui = "bold" } },
    command = { a = { fg = "#1c1c1c", bg = "#ffaf00", gui = "bold" } },
    terminal = { a = { fg = "#1c1c1c", bg = "#5fd7af", gui = "bold" } },
    inactive = {
      a = { fg = "#888888", bg = "#1c1c1c" },
      b = { fg = "#888888", bg = "#1c1c1c" },
      c = { fg = "#888888", bg = "#1c1c1c" },
    },
  },
}

-- register(name, table): add a bundled theme (public via register_theme).
function M.register(name, palette)
  if type(name) ~= "string" then
    error("nxvim-line.register_theme: name must be a string")
  end
  if type(palette) ~= "table" then
    error("nxvim-line.register_theme: palette must be a table")
  end
  M.bundled[name] = palette
end

-- ----- normalize (fill in lualine's defaults) --------------------------------

-- normalize(palette): produce a full table with every mode and every section a..z. x/y/z
-- default to c/b/a; an unspecified mode inherits `normal`; `normal` itself must carry at
-- least `a` (b/c fall back to a). A section cell is copied by reference (it stays either a
-- {fg,bg,gui} table or a group-name string — define_theme handles each).
function M.normalize(palette)
  if type(palette) ~= "table" or type(palette.normal) ~= "table" then
    error("nxvim-line: a theme needs a `normal` palette with at least section `a`")
  end
  local base = palette.normal
  local base_a = base.a or error("nxvim-line: a theme's `normal` palette needs section `a`")
  local base_b = base.b or base_a
  local base_c = base.c or base_b
  local out = {}
  for _, mode in ipairs(ALL_MODES) do
    local m = palette[mode] or {}
    local a = m.a or base_a
    local b = m.b or base_b
    local c = m.c or base_c
    out[mode] = {
      a = a,
      b = b,
      c = c,
      x = m.x or c,
      y = m.y or b,
      z = m.z or a,
    }
  end
  return out
end

-- ----- auto-derive from the active colorscheme -------------------------------

local function hl(name)
  return nx.hl.get(0, { name = name, link = false }) or {}
end

-- A 0xRRGGBB int (nx.hl.get's colour form) → "#rrggbb", or the fallback when absent.
local function hex(v, fallback)
  if type(v) == "number" then
    return string.format("#%06x", v)
  end
  return fallback
end

-- derive_auto(): read a handful of canonical groups and assemble a powerline palette —
-- the section-a accent per mode comes from a semantic group (Function/String/…), b/c from
-- StatusLine/Normal. Every read has a fallback so this never yields a nil cell.
function M.derive_auto()
  local normal, statusline = hl("Normal"), hl("StatusLine")
  local bg = hex(normal.bg, "#1c1c1c")
  local fg = hex(normal.fg, "#c6c6c6")
  local sl_bg = hex(statusline.bg, "#3a3a3a")
  local sl_fg = hex(statusline.fg, fg)
  local function accent(group, fallback)
    return hex(hl(group).fg, fallback)
  end
  local function a(acc)
    return { fg = bg, bg = acc, gui = "bold" }
  end
  return {
    normal = {
      a = a(accent("Function", "#5fafff")),
      b = { fg = fg, bg = sl_bg },
      -- The fill (c) — and every section defaulting to it (x) — rides the
      -- StatusLine background, NOT Normal, so the bar reads as a distinct strip
      -- rather than blending into the document (e.g. catppuccin's mantle vs base).
      c = { fg = sl_fg, bg = sl_bg },
    },
    insert = { a = a(accent("String", "#5faf5f")) },
    visual = { a = a(accent("Statement", "#d787d7")) },
    replace = { a = a(accent("Error", "#ff5f5f")) },
    command = { a = a(accent("Constant", "#ffaf00")) },
    terminal = { a = a(accent("Type", "#5fd7af")) },
    -- The inactive (unfocused-window) bar is flat but still on the StatusLine
    -- background, so it too stays distinct from the document.
    inactive = {
      a = { fg = sl_fg, bg = sl_bg },
      b = { fg = sl_fg, bg = sl_bg },
      c = { fg = sl_fg, bg = sl_bg },
    },
  }
end

-- ----- resolve ---------------------------------------------------------------

-- resolve(theme) -> a normalized palette. A table is used as-is; `"auto"` derives;
-- a name resolves bundled → lualine.themes.<name> → hard error (no silent fallback).
function M.resolve(theme)
  if type(theme) == "table" then
    return M.normalize(theme)
  end
  if theme == "auto" then
    return M.normalize(M.derive_auto())
  end
  if type(theme) == "string" then
    if M.bundled[theme] then
      return M.normalize(M.bundled[theme])
    end
    local ok, mod = pcall(require, "lualine.themes." .. theme)
    if ok and type(mod) == "table" then
      return M.normalize(mod)
    end
    error(
      "nxvim-line: unknown theme '"
        .. theme
        .. "' (not bundled, and require('lualine.themes."
        .. theme
        .. "') failed)"
    )
  end
  error('nxvim-line: `theme` must be a string name, "auto", or a palette table')
end

return M
