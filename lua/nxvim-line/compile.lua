-- nxvim-line.compile: lower a validated config onto the native nx.statusline segment
-- registry. One custom segment per non-empty lualine section (`NxLineA`..`NxLineZ`);
-- its `render(ctx)` walks the section's components and concatenates their cells.
--
-- nx.statusline owns layout activation AND the event->invalidate wiring: we hand each
-- segment the *union* of its components' declared `events`, and `nx.statusline.setup`
-- registers one invalidating autocmd per (segment, event) and replaces them on every
-- call. So `build()` is idempotent with no bookkeeping here — re-running it overwrites
-- the segments by name and re-activates the layout; a section dropped from the new
-- config is simply no longer referenced.
--
-- (`NxLine*` here are nx.statusline SEGMENT registry names — a private namespace,
-- distinct from the `lualine_<section>_<mode>` HIGHLIGHT groups Phase 4 defines.)
--
-- Phase 4: each section paints in its theme group for the CURRENT mode — a section's
-- nil-highlight cells take `lualine_<section>_<mode>`, the powerline arrows between
-- sections take a colour transition group, and every section also re-renders on
-- `ModeChanged`. A component with its own `color`/`hl` opts out of the section palette.

local components = require("nxvim-line.components")
local git = require("nxvim-line.git")
local icons = require("nxvim-line.icons")
local highlights = require("nxvim-line.highlights")
local themes = require("nxvim-line.themes")

local M = {}

-- lualine's default per-component padding: one space on each side.
local DEFAULT_PADDING = 1

-- The git-backed components: their presence in a layout activates the git data source.
local GIT_COMPONENTS = { branch = true, diff = true }

local SECTION_SEGMENT = {
  lualine_a = "NxLineA",
  lualine_b = "NxLineB",
  lualine_c = "NxLineC",
  lualine_x = "NxLineX",
  lualine_y = "NxLineY",
  lualine_z = "NxLineZ",
}
-- The lualine section LETTER (a..z) for each section key — the theme/transition group key.
local SECTION_LETTER = {
  lualine_a = "a",
  lualine_b = "b",
  lualine_c = "c",
  lualine_x = "x",
  lualine_y = "y",
  lualine_z = "z",
}
-- The fill section between the two halves uses lualine_c's colour (lualine's convention),
-- so a half-edge powerline arrow transitions to/from "c".
local FILL_SECTION = "c"
local LEFT = { "lualine_a", "lualine_b", "lualine_c" }
local RIGHT = { "lualine_x", "lualine_y", "lualine_z" }
local ALL_SECTIONS =
  { "lualine_a", "lualine_b", "lualine_c", "lualine_x", "lualine_y", "lualine_z" }

-- The segment names of the most recent build (for refresh()/invalidate_all).
M._active = {}

-- Introspection seam: the cells each segment most recently emitted, keyed by segment name.
-- The status mirror carries text only, so tests read cell HIGHLIGHTS here (what render
-- produced for the latest window). `_last_win[win][segname]` keeps it per window so a test
-- with a split can read an UNFOCUSED window's cells. Both reset on each build().
M._last = {}
M._last_win = {}

-- The periodic-refresh timer generation. Each build() bumps it; the re-arming one-shot
-- timer stops when its captured generation goes stale (the idempotent-rebuild contract).
M._refresh_gen = 0

-- Normalize a component's `provide` result into a list of `{ text, hl }` cells: nil ->
-- {}, a single cell `{ text, hl }` -> one cell, a list of cells -> the non-empty ones.
local function normalize_cells(result)
  if type(result) ~= "table" then
    return {}
  end
  if type(result.text) == "string" then
    return result.text ~= "" and { { text = result.text, hl = result.hl } } or {}
  end
  local out = {}
  for _, c in ipairs(result) do
    if type(c) == "table" and type(c.text) == "string" and c.text ~= "" then
      out[#out + 1] = { text = c.text, hl = c.hl }
    end
  end
  return out
end

-- Resolve a component's `padding` opt to (left, right) space counts. lualine accepts a
-- number (both sides) or `{ left =, right = }`; absent → the section default.
local function resolve_padding(comp, default)
  local p = comp.padding
  if p == nil then
    return default, default
  end
  if type(p) == "number" then
    return p, p
  end
  if type(p) == "table" then
    return p.left or default, p.right or default
  end
  return default, default
end

-- A loud error cell, the no-silent-stub fallback when a component's own callback throws.
local function error_cell(name)
  return { { text = "E:" .. name, hl = "ErrorMsg" } }
end

-- The cells for ONE component, applying the full lualine per-component pipeline:
-- `cond` gate → `provide` → `fmt` (text transform) → `icon` (leading glyph) → `color`
-- (highlight override) → `on_click` (the native click handler). A callback error becomes
-- a loud `E:<name>` cell; a hidden/empty result is `{}`.
local function component_cells(comp, ctx)
  -- lualine `cond(ctx)`: gate the whole component (false → render nothing).
  if type(comp.cond) == "function" then
    local ok, show = pcall(comp.cond, ctx)
    if not ok then
      return error_cell(comp.name)
    end
    if not show then
      return {}
    end
  end

  local spec = components.get(comp.name)
  local ok, result = pcall(spec.provide, ctx, comp)
  if not ok then
    return error_cell(comp.name)
  end
  local run = normalize_cells(result)
  if #run == 0 then
    return {}
  end

  -- lualine `fmt(str, ctx)`: post-process the component's text. It operates on a string,
  -- so the run is joined and collapsed to one cell (keeping the first cell's highlight);
  -- a nil/empty return hides the component.
  if type(comp.fmt) == "function" then
    local parts = {}
    for _, c in ipairs(run) do
      parts[#parts + 1] = c.text
    end
    local ok2, out = pcall(comp.fmt, table.concat(parts), ctx)
    if not ok2 then
      return error_cell(comp.name)
    end
    if type(out) ~= "string" or out == "" then
      return {}
    end
    run = { { text = out, hl = run[1].hl } }
  end

  -- lualine `icon`: a leading glyph (string, or `{ glyph, … }`) on the first cell. Honors
  -- icons_enabled; a component's own default icon (branch/filetype/…) is emitted inside
  -- its `provide`, so this is the per-component override/addition on top.
  if icons.enabled() and comp.icon ~= nil then
    local ic = type(comp.icon) == "table" and comp.icon[1] or comp.icon
    if type(ic) == "string" and ic ~= "" then
      run[1] = { text = ic .. " " .. run[1].text, hl = run[1].hl }
    end
  end

  -- lualine component-level `color`: overrides every one of the component's cell hls
  -- (a string group name, or a { fg, bg, gui } table interned by highlights.color_group).
  if comp.color ~= nil then
    local hl = highlights.color_group(comp.color)
    for _, c in ipairs(run) do
      c.hl = hl
    end
  end

  -- lualine `on_click`: thread the native click handler (a `v:lua.<fn>` string resolved
  -- through compile._click) onto every cell. The id was assigned at build time.
  if comp._click_id ~= nil then
    local click = "v:lua.require'nxvim-line.compile'._click(" .. comp._click_id .. ")"
    for _, c in ipairs(run) do
      c.on_click = click
    end
  end

  return run
end

-- Render one section into a flat cell list, picking the layout by FOCUS: a focused window
-- renders `active_comps` in its mode group with the powerline arrows; an unfocused window
-- renders `inactive_comps` in the flat `lualine_<section>_inactive` group with no arrows
-- (lualine's dim inactive bar). Every cell with no highlight of its own takes the section
-- group — a component with its own `color`/per-severity hl keeps it (opts out). A section
-- that renders empty this frame emits nothing.
-- `opts = { section, side, active_comps, inactive_comps, component_sep, padding,
--           sep_glyph, sep_neighbor }`.
local function render_section(ctx, opts)
  local focused = ctx.focused
  local comps = focused and opts.active_comps or opts.inactive_comps
  if not comps or #comps == 0 then
    return {}
  end
  local mode = focused and themes.mode_of(nx.mode().mode) or "inactive"
  local section_hl = highlights.section_group(opts.section, mode)

  local pieces = {}
  for _, comp in ipairs(comps) do
    local run = component_cells(comp, ctx)
    if #run > 0 then
      pieces[#pieces + 1] = { comp = comp, cells = run }
    end
  end
  if #pieces == 0 then
    return {}
  end

  local cells = {}
  local function emit(cell)
    if cell.hl == nil then
      cell.hl = section_hl
    end
    cells[#cells + 1] = cell
  end

  -- The powerline arrows are drawn only for the focused window; inactive bars stay flat.
  local arrows = focused and opts.sep_glyph ~= ""

  -- right half: the leading arrow transitions FROM this section's bg INTO the neighbour.
  if arrows and opts.side == "right" then
    cells[#cells + 1] = {
      text = opts.sep_glyph,
      hl = highlights.transition_group(opts.section, opts.sep_neighbor, mode),
    }
  end

  for i, piece in ipairs(pieces) do
    if i > 1 and opts.component_sep ~= "" then
      emit({ text = opts.component_sep })
    end
    local lpad, rpad = resolve_padding(piece.comp, opts.padding)
    local run = piece.cells
    -- pad in place so the cell keeps its other fields (hl, on_click); run[1] and run[#run]
    -- are the same cell when the component is single-cell (lpad then rpad both apply).
    run[1].text = string.rep(" ", lpad) .. run[1].text
    run[#run].text = run[#run].text .. string.rep(" ", rpad)
    for _, c in ipairs(run) do
      emit(c)
    end
  end

  -- left half: the trailing arrow transitions FROM this section's bg INTO the neighbour.
  if arrows and opts.side == "left" then
    cells[#cells + 1] = {
      text = opts.sep_glyph,
      hl = highlights.transition_group(opts.section, opts.sep_neighbor, mode),
    }
  end
  return cells
end

-- The de-duplicated, order-preserving union of a section's components' declared events,
-- plus `ModeChanged` — every section recolours by mode under the theme, so all must
-- re-render on a mode transition (the single driver the Phase-4 plan calls for).
local function union_events(comps)
  local seen, out = {}, {}
  local function add(ev)
    if not seen[ev] then
      seen[ev] = true
      out[#out + 1] = ev
    end
  end
  for _, comp in ipairs(comps) do
    for _, ev in ipairs(components.get(comp.name).events) do
      add(ev)
    end
  end
  add("ModeChanged")
  return out
end

-- Does a section list contain a git-backed component?
local function has_git(comps)
  for _, comp in ipairs(comps) do
    if GIT_COMPONENTS[comp.name] then
      return true
    end
  end
  return false
end

-- Non-empty?
local function nonempty(list)
  return type(list) == "table" and #list > 0
end

-- The section keys (of one half) present in `sections` (the active layout) — the order
-- the powerline-arrow adjacency is computed over (arrows draw only for the focused window).
local function active_present(config, keys)
  local out = {}
  for _, sec in ipairs(keys) do
    if nonempty(config.sections[sec]) then
      out[#out + 1] = sec
    end
  end
  return out
end

-- The section keys (of one half) present in EITHER `sections` or `inactive_sections` — the
-- segments to register for that half. A section only in `inactive_sections` renders empty
-- when focused and its inactive layout otherwise.
local function any_present(config, keys)
  local out = {}
  for _, sec in ipairs(keys) do
    if nonempty(config.sections[sec]) or nonempty(config.inactive_sections[sec]) then
      out[#out + 1] = sec
    end
  end
  return out
end

-- Register one section's segment, capturing both its active and inactive component lists.
-- `neighbor` is the letter the focused-window powerline arrow transitions into.
local function build_section(config, sec, side, sep_glyph, component_sep, neighbor, out, git_segs)
  local active_comps = config.sections[sec] or {}
  local inactive_comps = config.inactive_sections[sec] or {}
  local both = {}
  for _, c in ipairs(active_comps) do
    both[#both + 1] = c
  end
  for _, c in ipairs(inactive_comps) do
    both[#both + 1] = c
  end

  local segname = SECTION_SEGMENT[sec]
  local opts = {
    section = SECTION_LETTER[sec],
    side = side,
    active_comps = active_comps,
    inactive_comps = inactive_comps,
    component_sep = component_sep,
    padding = DEFAULT_PADDING,
    sep_glyph = sep_glyph,
    sep_neighbor = neighbor,
  }
  nx.statusline.segment({
    name = segname,
    events = union_events(both),
    render = function(ctx)
      local cells = render_section(ctx, opts)
      M._last[segname] = cells
      M._last_win[ctx.win] = M._last_win[ctx.win] or {}
      M._last_win[ctx.win][segname] = cells
      return cells
    end,
  })
  out[#out + 1] = segname
  if has_git(both) then
    git_segs[#git_segs + 1] = segname
  end
end

-- Build one half's segments with powerline adjacency. Left sections arrow INTO the next
-- ACTIVE-present section (or the fill); right sections arrow into the PREVIOUS one (or the
-- fill), so the chevrons point outward from the centre. Adjacency is over the active
-- layout (the only one that draws arrows).
local function build_side(config, keys, side, sep_glyph, component_sep, out, git_segs)
  local segs = any_present(config, keys)
  local active = active_present(config, keys)
  -- map a section key → its index among the ACTIVE present sections of this half
  local active_idx = {}
  for i, sec in ipairs(active) do
    active_idx[sec] = i
  end
  for _, sec in ipairs(segs) do
    local i = active_idx[sec]
    local neighbor = FILL_SECTION
    if i then
      local adj = side == "left" and active[i + 1] or active[i - 1]
      neighbor = adj and SECTION_LETTER[adj] or FILL_SECTION
    end
    build_section(config, sec, side, sep_glyph, component_sep, neighbor, out, git_segs)
  end
end

-- ----- click handlers --------------------------------------------------------

-- The registered per-component `on_click` handlers, keyed by an id assigned at build time;
-- a cell references its handler via a `v:lua.require'nxvim-line.compile'._click(id)` string.
M._clicks = {}

-- _click(id): resolve a component's click handler to a function the native click bridge
-- calls with neovim's `(minwid, clicks, button, mods)`; it's adapted to lualine's
-- `(clicks, button, modifiers)` shape (minwid dropped).
function M._click(id)
  local handler = M._clicks[id]
  if type(handler) ~= "function" then
    return function() end
  end
  return function(_minwid, clicks, button, mods)
    return handler(clicks, button, mods)
  end
end

-- Assign click ids across every component that declares an `on_click` function (in both
-- the active and inactive layouts), storing the handler for _click to resolve. Tags the
-- normalized component entry with `_click_id` (rebuilt each setup, so this is per-build).
local function assign_clicks(config)
  M._clicks = {}
  local next_id = 0
  local function walk(sections)
    for _, sec in ipairs(ALL_SECTIONS) do
      for _, comp in ipairs(sections[sec] or {}) do
        if type(comp.on_click) == "function" then
          next_id = next_id + 1
          M._clicks[next_id] = comp.on_click
          comp._click_id = next_id
        else
          comp._click_id = nil
        end
      end
    end
  end
  walk(config.sections)
  walk(config.inactive_sections)
end

-- ----- periodic refresh ------------------------------------------------------

-- start_refresh(refresh): (re)arm the periodic full-statusline refresh from
-- `options.refresh = { statusline = ms }` (lualine's coarse timer, default 1000ms; for a
-- clock-like component with no event). A re-arming one-shot timer (nx.timer is one-shot)
-- that invalidates every active segment each interval, and stops when a newer build()
-- bumps the generation. `ms` ≤ 0 / non-number disables it (mode colour is event-driven via
-- ModeChanged, so the timer can be coarse without making transitions feel laggy).
local function start_refresh(refresh)
  M._refresh_gen = M._refresh_gen + 1
  local gen = M._refresh_gen
  local ms = type(refresh) == "table" and refresh.statusline or nil
  if type(ms) ~= "number" or ms <= 0 then
    return
  end
  local function tick()
    if gen ~= M._refresh_gen then
      return -- superseded by a later build()
    end
    M.invalidate_all()
    nx.timer(tick, ms)
  end
  nx.timer(tick, ms)
end

-- build(config): (re)build the live statusline. Idempotent — see the module note.
function M.build(config)
  -- Styling configuration consumed by render: icon glyphs on/off + the interned-colour
  -- cache reset (so generated NxLineColor groups don't accumulate across rebuilds).
  icons.configure({
    enabled = config.options.icons_enabled,
    provider = config.options.icon_provider,
  })
  highlights.reset()

  -- Resolve the theme and predefine every lualine_<section>_<mode> group up front (no
  -- highlight work on the hot path — render only picks a group by the current mode).
  highlights.define_theme(themes.resolve(config.options.theme))

  -- Left sections use `component_separators.left` + `section_separators.left`, right
  -- sections the `.right` variants (lualine).
  assign_clicks(config)

  local cs = config.options.component_separators
  local ss = config.options.section_separators
  M._last = {}
  M._last_win = {}
  local left, right = {}, {}
  local git_segs = {}
  build_side(config, LEFT, "left", ss.left, cs.left, left, git_segs)
  build_side(config, RIGHT, "right", ss.right, cs.right, right, git_segs)

  vim.o.laststatus = config.options.globalstatus and 3 or 2
  nx.statusline.setup({ left = left, right = right })

  M._active = {}
  for _, n in ipairs(left) do
    M._active[#M._active + 1] = n
  end
  for _, n in ipairs(right) do
    M._active[#M._active + 1] = n
  end

  -- The git data source runs only when a layout uses branch/diff; on fresh data it
  -- invalidates just the hosting segments.
  if #git_segs > 0 then
    git.activate(function()
      for _, s in ipairs(git_segs) do
        nx.statusline.invalidate(s)
      end
    end)
  else
    git.deactivate()
  end

  start_refresh(config.options.refresh)
end

-- invalidate_all(): force a re-render of every active section (the public refresh()).
function M.invalidate_all()
  for _, name in ipairs(M._active) do
    nx.statusline.invalidate(name)
  end
end

return M
