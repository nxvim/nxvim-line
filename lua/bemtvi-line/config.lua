-- bemtvi-line.config: the lualine-shaped config — defaults, a validated merge, and
-- component-spelling normalization. Pure data; no editor state, no btv.statusline calls.

local components = require("bemtvi-line.components")

local M = {}

-- The lualine section keys: left half (a/b/c) + right half (x/y/z). The native
-- btv.statusline layout takes exactly these two halves.
M.LEFT = { "lualine_a", "lualine_b", "lualine_c" }
M.RIGHT = { "lualine_x", "lualine_y", "lualine_z" }
M.SECTIONS = { "lualine_a", "lualine_b", "lualine_c", "lualine_x", "lualine_y", "lualine_z" }

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

-- The full default config — the whole lualine shape, stable across phases. Only the
-- parts a phase implements are *consumed*: Phase 1 uses `sections` + `globalstatus`.
-- The rest (`theme`, separators, `refresh`, `disabled_filetypes`, `inactive_sections`,
-- `tabline`, `extensions`) are accepted and validated so a complete lualine-style
-- config never errors, and are wired in later phases.
--
-- The default `sections` are lualine's own, plus `lsp` leading `lualine_x`: bemtvi ships
-- LSP in the box, so the attached server belongs on the default bar, and the component
-- collapses to nothing when no client is attached — a buffer with no server looks
-- exactly as it did before.
local DEFAULTS = {
  options = {
    theme = "auto",
    globalstatus = false,
    icons_enabled = true,
    -- lualine's powerline-glyph defaults: section arrows  /  (consumed in Phase 4) and
    -- the thinner component separators  /  (Phase 3). Written as \u escapes so the
    -- source stays ASCII; set to "" to drop them.
    section_separators = { left = "\u{e0b0}", right = "\u{e0b2}" },
    component_separators = { left = "\u{e0b1}", right = "\u{e0b3}" },
    disabled_filetypes = { statusline = {} },
    refresh = { statusline = 1000 },
  },
  sections = {
    lualine_a = { "mode" },
    lualine_b = { "branch", "diff", "diagnostics" },
    lualine_c = { "filename" },
    lualine_x = { "lsp", "encoding", "fileformat", "filetype" },
    lualine_y = { "progress" },
    lualine_z = { "location" },
  },
  inactive_sections = {
    lualine_c = { "filename" },
    lualine_x = { "location" },
  },
  tabline = {},
  extensions = {},
}

-- defaults(): an independent deep copy each call (a caller may mutate its config).
function M.defaults()
  return deepcopy(DEFAULTS)
end

-- Normalize one component entry to `{ name = "...", <per-component opts> }`. A bare string
-- becomes `{ name = s }`; a table carries a string name (a registered component) OR a
-- FUNCTION at `[1]` — the lualine "inline component" spelling, kept on `_inline` and given
-- a synthetic name so the rest of the pipeline (icon / color / cond / fmt / on_click /
-- padding) applies. A bare function is the shorthand for `{ function }`.
function M._normalize_entry(entry, where)
  local norm
  if type(entry) == "string" then
    norm = { name = entry }
  elseif type(entry) == "function" then
    norm = { name = "<inline>", _inline = entry }
  elseif type(entry) == "table" then
    if type(entry[1]) == "function" then
      norm = deepcopy(entry)
      norm._inline = entry[1]
      norm.name = "<inline>"
      norm[1] = nil
    elseif type(entry[1]) == "string" then
      norm = deepcopy(entry)
      norm.name = entry[1]
      norm[1] = nil
    else
      error(
        "bemtvi-line: a component table needs a string name or a function at [1] (" .. where .. ")"
      )
    end
  else
    error(
      "bemtvi-line: a component must be a string, table, or function, got "
        .. type(entry)
        .. " ("
        .. where
        .. ")"
    )
  end
  -- An inline-function component is self-contained — no registry lookup / deferred check.
  if norm._inline == nil then
    local deferred = components.deferred_reason(norm.name)
    if deferred then
      error("bemtvi-line: component '" .. norm.name .. "' is not available yet — " .. deferred)
    end
    if not components.is_known(norm.name) then
      error("bemtvi-line: unknown component '" .. norm.name .. "' (" .. where .. ")")
    end
  end
  return norm
end

-- The valid section keys, as a set — for the unknown-key check below.
local IS_SECTION = {}
for _, sec in ipairs(M.SECTIONS) do
  IS_SECTION[sec] = true
end

-- Normalize + validate every component list in a `sections`-shaped table in place.
-- A key that isn't one of the six sections is a HARD ERROR: only `lualine_a..c` /
-- `lualine_x..z` are rendered, so a typo (`lualine_d`, `lualine_ b`) used to drop every
-- component in it while the config still looked accepted — a silently wrong bar with
-- nothing to point at (CLAUDE.md: no silent stubs or skips).
function M._normalize_sections(sections, where)
  for key in pairs(sections) do
    if not IS_SECTION[key] then
      error(
        "bemtvi-line.setup: unknown section '"
          .. tostring(key)
          .. "' in "
          .. where
          .. " (expected one of "
          .. table.concat(M.SECTIONS, ", ")
          .. ")"
      )
    end
  end
  for _, sec in ipairs(M.SECTIONS) do
    local list = sections[sec]
    if list ~= nil then
      if type(list) ~= "table" then
        error("bemtvi-line.setup: " .. where .. "." .. sec .. " must be a list of components")
      end
      for i, entry in ipairs(list) do
        list[i] = M._normalize_entry(entry, where .. "." .. sec)
      end
    end
  end
end

-- Normalize a separator option to `{ left = …, right = … }`. lualine accepts the bare
-- string shorthand (`component_separators = "|"` → both sides) and the explicit table;
-- `""` / nil mean "no separator". Anything else errors loud rather than rendering oddly.
function M._normalize_separators(s)
  if s == nil then
    return { left = "", right = "" }
  end
  if type(s) == "string" then
    return { left = s, right = s }
  end
  if type(s) == "table" then
    return { left = s.left or "", right = s.right or "" }
  end
  error("bemtvi-line.setup: a separator option must be a string or { left =, right = } table")
end

-- merge(base, opts): deep-merge `opts` over `base`, then normalize + validate. A user
-- `sections`/`inactive_sections` entry REPLACES that section's default list wholesale
-- (lualine semantics — you redefine a section, you don't merge its component list);
-- `options` merges key-by-key. Returns the effective config; fails loud on a malformed
-- entry or an unknown component.
function M.merge(base, opts)
  opts = opts or {}
  if type(opts) ~= "table" then
    error("bemtvi-line.setup: expected a table, got " .. type(opts))
  end
  local cfg = deepcopy(base)

  if opts.options ~= nil then
    if type(opts.options) ~= "table" then
      error("bemtvi-line.setup: 'options' must be a table")
    end
    for k, v in pairs(opts.options) do
      cfg.options[k] = deepcopy(v)
    end
  end

  local function take_sections(key)
    if opts[key] ~= nil then
      if type(opts[key]) ~= "table" then
        error("bemtvi-line.setup: '" .. key .. "' must be a table")
      end
      for sec, list in pairs(opts[key]) do
        cfg[key][sec] = deepcopy(list)
      end
    end
  end
  take_sections("sections")
  take_sections("inactive_sections")
  if opts.tabline ~= nil then
    cfg.tabline = deepcopy(opts.tabline)
  end
  if opts.extensions ~= nil then
    cfg.extensions = deepcopy(opts.extensions)
  end

  M._normalize_sections(cfg.sections, "sections")
  M._normalize_sections(cfg.inactive_sections, "inactive_sections")
  M._normalize_sections(cfg.tabline, "tabline")

  cfg.options.section_separators = M._normalize_separators(cfg.options.section_separators)
  cfg.options.component_separators = M._normalize_separators(cfg.options.component_separators)

  return cfg
end

return M
