-- nxvim-line.icons — the filename/extension → glyph registry for the `filetype`
-- component (and any component that wants a leading icon).
--
-- A pure-Lua lookup seeded with common file kinds, sharing nxvim-tree's Nerd-Font v3
-- codepoints so the two plugins agree on glyphs. Glyphs are written as `\u{...}` escapes
-- so the source stays plain ASCII and survives any transport that mangles raw PUA bytes;
-- each encodes to a 3-byte UTF-8 sequence the renderer measures by byte length.
--
-- Icon COLOUR is out of scope here: a glyph rides inside its component's cell and inherits
-- the section highlight. (Splitting the icon into its own coloured cell — lualine's
-- `colored` filetype option — is a later refinement; this module only describes glyphs.)
--
-- Resolution order in `for_name`: a user-supplied provider hook (`configure{ provider =
-- fn }`, a devicons-equivalent) → exact filename → extension → the default file glyph.
-- With icons disabled (`configure{ enabled = false }`, lualine's `icons_enabled = false`)
-- every lookup returns nil so components render plain text — the no-Nerd-Font path.

local M = {}

local FILE_DEFAULT = "\u{f15b}" -- nf-fa-file

-- Exact-filename lookup (highest priority).
local by_name = {
  ["Cargo.toml"] = "\u{e7a8}",
  ["Cargo.lock"] = "\u{f023}",
  ["package.json"] = "\u{e718}",
  ["package-lock.json"] = "\u{f023}",
  ["tsconfig.json"] = "\u{e628}",
  [".gitignore"] = "\u{e702}",
  [".gitattributes"] = "\u{e702}",
  [".gitmodules"] = "\u{e702}",
  ["README.md"] = "\u{f48a}",
  ["LICENSE"] = "\u{f0219}",
  ["Makefile"] = "\u{e779}",
  ["Dockerfile"] = "\u{f308}",
}

-- Lowercased-extension lookup (second priority).
local by_ext = {
  rs = "\u{e7a8}",
  lua = "\u{e620}",
  js = "\u{e74e}",
  mjs = "\u{e74e}",
  cjs = "\u{e74e}",
  jsx = "\u{e7ba}",
  ts = "\u{e628}",
  tsx = "\u{e7ba}",
  json = "\u{e60b}",
  toml = "\u{e6b2}",
  yaml = "\u{e6a8}",
  yml = "\u{e6a8}",
  md = "\u{f48a}",
  markdown = "\u{f48a}",
  py = "\u{e606}",
  go = "\u{e627}",
  c = "\u{e61e}",
  h = "\u{f0fd}",
  cpp = "\u{e61d}",
  hpp = "\u{f0fd}",
  sh = "\u{f489}",
  bash = "\u{f489}",
  zsh = "\u{f489}",
  fish = "\u{f489}",
  html = "\u{e736}",
  css = "\u{e749}",
  scss = "\u{e749}",
  png = "\u{f1c5}",
  jpg = "\u{f1c5}",
  jpeg = "\u{f1c5}",
  gif = "\u{f1c5}",
  svg = "\u{f1c5}",
  txt = "\u{f15c}",
  lock = "\u{f023}",
}

local enabled = true
local provider = nil

-- configure{ enabled = bool, provider = fn }: set from `options.icons_enabled` /
-- `options.icon_provider` on each setup(). `provider(basename) -> glyph` (a
-- devicons-equivalent) wins over the built-in tables when it returns a non-empty string.
function M.configure(opts)
  opts = opts or {}
  enabled = opts.enabled ~= false
  provider = type(opts.provider) == "function" and opts.provider or nil
end

-- enabled(): whether glyphs are on (components consult this to choose glyph vs plain).
function M.enabled()
  return enabled
end

-- Accept a glyph as a bare string or as a `{ glyph = … }` / `{ … }` table (the
-- nxvim-tree spelling), so a shared icon map drops in.
local function glyph_of(v)
  if type(v) == "string" then
    return v
  end
  if type(v) == "table" then
    return v.glyph or v[1]
  end
  return nil
end

-- register(map) — extend the registry. Top-level keys are extensions (`{ rs = "" }`);
-- a `name = { ["exact.file"] = "" }` (or `by_name` / `by_ext`) sub-table extends the
-- exact-name / extension tables. Surfaced as `require("nxvim-line").register_icons(...)`.
function M.register(map)
  for k, v in pairs(map or {}) do
    if k == "name" or k == "by_name" then
      for n, spec in pairs(v) do
        by_name[n] = glyph_of(spec)
      end
    elseif k == "by_ext" then
      for e, spec in pairs(v) do
        by_ext[e:lower()] = glyph_of(spec)
      end
    else
      by_ext[tostring(k):lower()] = glyph_of(v)
    end
  end
end

-- for_name(name) -> glyph string | nil. `name` may be a full path; the basename is used.
-- nil when icons are disabled or `name` is empty.
function M.for_name(name)
  if not enabled or name == nil or name == "" then
    return nil
  end
  local base = name:match("[^/]*$") or name
  if provider then
    local ok, g = pcall(provider, base)
    if ok and type(g) == "string" and g ~= "" then
      return g
    end
  end
  local exact = by_name[base]
  if exact then
    return exact
  end
  local ext = base:match("%.([%w]+)$")
  local e = ext and by_ext[ext:lower()]
  if e then
    return e
  end
  return FILE_DEFAULT
end

-- Test/introspection seam: the live tables (read-only by convention).
M._by_name = by_name
M._by_ext = by_ext

return M
