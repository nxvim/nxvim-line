-- nxvim-line — a fully-featured, lualine-style statusline for nxvim, built entirely
-- on the native `nx.statusline` segment registry (ADR 0002): no buffer mutation, no
-- native widget, no per-frame Lua.
--
-- It is a COMPILER, not a renderer. The editor already owns the statusline: the
-- `nx.statusline` primitive composes ordered *segments* (built-in ones that resolve
-- natively every frame — `mode`/`location`/`diagnostics`/… — and custom Lua segments
-- that run `render(ctx)` only when invalidated) into the styled `status` arrays every
-- client already paints. nxvim-line takes a familiar lualine-shaped config —
-- sections `a..z`, components with icons / separators / colors / conditions / themes —
-- and LOWERS it onto that primitive: it registers the custom segments, defines the
-- highlight groups, and wires the invalidation events. The hot path stays in Rust.
--
-- Module map (one concern each — filled in across the phased plan in
-- docs/plans/2026-06-21-nxvim-line.md):
--   config.lua      defaults + validated merge of the lualine-shaped config  (Phase 1 ✅)
--   compile.lua     config -> native nx.statusline segments + event wiring   (Phase 1 ✅)
--   components.lua  the component registry + library                         (Phase 1 ✅, grows)
--   highlights.lua  per-section / per-mode highlight groups + separators      (Phase 3/4)
--   themes/         theme tables + colorscheme auto-derive                    (Phase 4)
--   git.lua         async branch + diff counts via nx.run                     (Phase 6)
--   icons.lua       filetype/extension -> glyph registry                      (Phase 3)
--   extensions.lua  per-filetype layout overrides                            (Phase 7)
--
-- Quick start (init.lua):
--   require("nxvim-line").setup({ options = { theme = "auto" } })

local config = require("nxvim-line.config")
local compile = require("nxvim-line.compile")
local components = require("nxvim-line.components")
local icons = require("nxvim-line.icons")
local themes = require("nxvim-line.themes")
local extensions = require("nxvim-line.extensions")

local M = {}

-- The effective configuration, rebuilt from defaults on every setup().
M.config = nil

-- setup(opts): merge `opts` over the defaults, validate, and lower the result onto
-- nx.statusline. Idempotent — calling it again tears down the prior layout/events and
-- rebuilds (no second statusline). Fails loud on a bad config (unknown component, …).
function M.setup(opts)
  M.config = config.merge(config.defaults(), opts)
  compile.build(M.config)
  -- Re-derive and re-apply the theme whenever the colorscheme changes — like real
  -- lualine. This matters for two reasons: the colorscheme may load AFTER us (so a
  -- `theme = "auto"` resolve at setup saw no `colors_name` yet and fell back to the
  -- synthesized palette), and the user can switch it live (`:colorscheme
  -- catppuccin-latte`). Wired once, even across repeated setup() calls.
  if not M._colorscheme_au then
    M._colorscheme_au = nx.on("ColorScheme", {}, function()
      if M.config then
        compile.build(M.config)
      end
    end)
  end
  return M
end

-- refresh(): force a re-render of every active section (e.g. after changing external
-- state a component reads but has no event for).
function M.refresh()
  if not M.config then
    error("nxvim-line: setup() must be called before refresh()")
  end
  compile.invalidate_all()
end

-- register_component(name, spec): add a custom component (`spec = { events = {...},
-- provide = function(ctx, opts) -> { text=, hl?, icon? } | nil }`) usable by name in
-- `sections`. Register it BEFORE setup() so config validation sees it.
function M.register_component(name, spec)
  components.register(name, spec)
  return M
end

-- register_icons(map): extend the filetype/extension glyph registry (`{ rs = "",
-- name = { ["Makefile"] = "" } }`). Call BEFORE setup() so the new glyphs are live
-- when sections first render. A devicons-equivalent can instead be wired wholesale via
-- `setup{ options = { icon_provider = fn } }`.
function M.register_icons(map)
  icons.register(map)
  return M
end

-- register_theme(name, palette): add a bundled theme (a lualine-shaped per-mode palette
-- table). Call BEFORE setup() so `options.theme = name` resolves it. The palette follows
-- lualine's shape — `{ normal = { a, b, c }, insert = {...}, … }` — with x/y/z and missing
-- modes filled in at resolution (see themes.lua).
function M.register_theme(name, palette)
  themes.register(name, palette)
  return M
end

-- register_extension(name, ext): add a bundled extension — a per-filetype layout override
-- `{ filetypes = { "ft", … }, sections = {...}, inactive_sections = {...}? }`. Call BEFORE
-- setup() so `extensions = { name }` resolves it.
function M.register_extension(name, ext)
  extensions.register(name, ext)
  return M
end

return M
