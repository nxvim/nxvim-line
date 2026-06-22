-- nxvim-line.extensions — per-filetype layout overrides (lualine's `extensions`).
--
-- An extension is `{ filetypes = { "qf", … }, sections = { lualine_a = {...}, … },
-- inactive_sections = {...}? }`: when the rendered window's buffer has one of those
-- filetypes, the extension's section layout REPLACES the normal one for that window (a
-- section the extension doesn't define renders empty). It reuses the ordinary component
-- library — the bundled ones lean on the `label` component for a static title.
--
-- `resolve(list)` turns the config's `extensions` (bundled names and/or inline tables)
-- into normalized entries `{ fts = { [ft]=true }, sections, inactive_sections }`, validating
-- each component the same way `sections` is (an unknown extension name / component errors
-- loud). `register(name, ext)` adds a bundled extension.

local config = require("nxvim-line.config")

local M = {}

-- Bundled extensions. Keyed by lualine-style names; `nxvim-tree` is the native explorer,
-- `nvim-tree` an alias so a ported config's `extensions = { "nvim-tree" }` just works.
local TREE = {
  filetypes = { "nxvim-tree", "NvimTree" },
  sections = { lualine_a = { { "label", text = "\u{f07b} Files" } } },
}
M.bundled = {
  ["nxvim-tree"] = TREE,
  ["nvim-tree"] = TREE,
  quickfix = {
    filetypes = { "qf", "quickfix" },
    sections = {
      lualine_a = { { "label", text = "Quickfix" } },
      lualine_z = { "location" },
    },
  },
}

-- register(name, ext): add a bundled extension (public via register_extension).
function M.register(name, ext)
  if type(name) ~= "string" then
    error("nxvim-line.register_extension: name must be a string")
  end
  if type(ext) ~= "table" or type(ext.filetypes) ~= "table" then
    error("nxvim-line.register_extension: an extension needs a `filetypes` list")
  end
  M.bundled[name] = ext
end

local function deepcopy(v)
  if type(v) ~= "table" then
    return v
  end
  local out = {}
  for k, val in pairs(v) do
    out[k] = deepcopy(val)
  end
  return out
end

-- Normalize one extension entry (a bundled name or an inline table) to
-- `{ fts = { [ft]=true }, sections, inactive_sections }`, validating its components.
local function normalize_one(entry, i)
  local ext
  if type(entry) == "string" then
    ext = M.bundled[entry]
    if not ext then
      error("nxvim-line: unknown extension '" .. entry .. "' (not bundled)")
    end
    ext = deepcopy(ext)
  elseif type(entry) == "table" then
    ext = deepcopy(entry)
  else
    error("nxvim-line: extensions[" .. i .. "] must be a string or a table")
  end
  if type(ext.filetypes) ~= "table" or #ext.filetypes == 0 then
    error("nxvim-line: extension #" .. i .. " needs a non-empty `filetypes` list")
  end
  local fts = {}
  for _, ft in ipairs(ext.filetypes) do
    fts[ft] = true
  end
  ext.sections = ext.sections or {}
  ext.inactive_sections = ext.inactive_sections or {}
  config._normalize_sections(ext.sections, "extension[" .. i .. "].sections")
  config._normalize_sections(ext.inactive_sections, "extension[" .. i .. "].inactive_sections")
  return { fts = fts, sections = ext.sections, inactive_sections = ext.inactive_sections }
end

-- resolve(list) -> a list of normalized extensions (empty for nil / {}).
function M.resolve(list)
  local out = {}
  for i, entry in ipairs(list or {}) do
    out[#out + 1] = normalize_one(entry, i)
  end
  return out
end

return M
