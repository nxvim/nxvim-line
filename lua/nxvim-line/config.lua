-- nxvim-line.config: the lualine-shaped config — defaults, a validated merge, and
-- component-spelling normalization. Pure data; no editor state, no nx.statusline calls.

local components = require("nxvim-line.components")

local M = {}

-- The lualine section keys: left half (a/b/c) + right half (x/y/z). The native
-- nx.statusline layout takes exactly these two halves.
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
-- config never errors, and are wired in later phases. The default sections use only
-- the components that exist in Phase 1.
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
    lualine_x = { "encoding", "filetype" }, -- `fileformat` deferred (no core option yet)
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

-- Normalize one component entry to `{ name = "...", <per-component opts> }`. A bare
-- string becomes `{ name = s }`; a table must carry a string name at `[1]` (its other
-- keys are kept as the component's options). A function entry is the lualine "inline
-- component" spelling — not supported until Phase 5, so it errors loud rather than
-- being silently dropped (CLAUDE.md: no silent stubs).
function M._normalize_entry(entry, where)
  local norm
  if type(entry) == "string" then
    norm = { name = entry }
  elseif type(entry) == "function" then
    error("nxvim-line: function components land in Phase 5 (" .. where .. ")")
  elseif type(entry) == "table" then
    if type(entry[1]) == "function" then
      error("nxvim-line: function components land in Phase 5 (" .. where .. ")")
    end
    if type(entry[1]) ~= "string" then
      error("nxvim-line: a component table needs a string name at [1] (" .. where .. ")")
    end
    norm = deepcopy(entry)
    norm.name = entry[1]
    norm[1] = nil
  else
    error(
      "nxvim-line: a component must be a string or table, got "
        .. type(entry)
        .. " ("
        .. where
        .. ")"
    )
  end
  local deferred = components.deferred_reason(norm.name)
  if deferred then
    error("nxvim-line: component '" .. norm.name .. "' is not available yet — " .. deferred)
  end
  if not components.is_known(norm.name) then
    error("nxvim-line: unknown component '" .. norm.name .. "' (" .. where .. ")")
  end
  return norm
end

-- Normalize + validate every component list in a `sections`-shaped table in place.
function M._normalize_sections(sections, where)
  for _, sec in ipairs(M.SECTIONS) do
    local list = sections[sec]
    if list ~= nil then
      if type(list) ~= "table" then
        error("nxvim-line.setup: " .. where .. "." .. sec .. " must be a list of components")
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
  error("nxvim-line.setup: a separator option must be a string or { left =, right = } table")
end

-- merge(base, opts): deep-merge `opts` over `base`, then normalize + validate. A user
-- `sections`/`inactive_sections` entry REPLACES that section's default list wholesale
-- (lualine semantics — you redefine a section, you don't merge its component list);
-- `options` merges key-by-key. Returns the effective config; fails loud on a malformed
-- entry or an unknown component.
function M.merge(base, opts)
  opts = opts or {}
  if type(opts) ~= "table" then
    error("nxvim-line.setup: expected a table, got " .. type(opts))
  end
  local cfg = deepcopy(base)

  if opts.options ~= nil then
    if type(opts.options) ~= "table" then
      error("nxvim-line.setup: 'options' must be a table")
    end
    for k, v in pairs(opts.options) do
      cfg.options[k] = deepcopy(v)
    end
  end

  local function take_sections(key)
    if opts[key] ~= nil then
      if type(opts[key]) ~= "table" then
        error("nxvim-line.setup: '" .. key .. "' must be a table")
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
