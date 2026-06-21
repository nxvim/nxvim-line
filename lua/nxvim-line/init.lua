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
--   config.lua      defaults + validated merge of the lualine-shaped config
--   compile.lua     config -> native nx.statusline segments + event wiring (the core)
--   components/      the component library (mode, branch, diff, diagnostics, filename,
--                    filetype, fileformat, encoding, progress, location, lsp, …)
--   highlights.lua   per-section / per-mode highlight groups + section/component seps
--   themes/          theme tables (auto, plus a few bundled) + colorscheme auto-derive
--   git.lua          async branch + diff counts via nx.run, cached + invalidated
--   icons.lua        filetype/extension -> glyph registry (overridable)
--   extensions.lua   per-filetype layout overrides (nxvim-tree, quickfix, …)
--
-- Quick start (init.lua):
--   require("nxvim-line").setup({ theme = "auto" })
--
-- See README.md for the full configuration surface and docs/plans/ for the build order.

local M = {}

-- The effective configuration, rebuilt from defaults on every setup().
M.config = nil

-- nxvim-line is scaffolded; the implementation lands across the phases in
-- docs/plans/2026-06-21-nxvim-line.md. Fail LOUD until Phase 1 wires setup() to the
-- compiler — a stub that quietly no-ops would make a broken statusline look configured
-- (CLAUDE.md: no silent stubs).
function M.setup(_opts)
  error("nxvim-line: not implemented yet — see docs/plans/2026-06-21-nxvim-line.md (Phase 1)")
end

return M
