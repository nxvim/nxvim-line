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

-- The segment names of the most recent build (for refresh()/invalidate_all).
M._active = {}

-- Introspection seam: the cells each segment most recently emitted, keyed by segment name.
-- The status mirror carries text only, so tests read cell HIGHLIGHTS here (what render
-- produced for the latest window). Reset on each build().
M._last = {}

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

-- The cells for ONE component: run `provide`, then apply the lualine per-component
-- styling that is NOT padding/separators — a leading `icon` glyph and a `color` override.
-- A `provide` error becomes a loud `E:<name>` cell (CLAUDE.md no-silent-stub); a nil /
-- empty result is `{}`.
local function component_cells(comp, ctx)
  local spec = components.get(comp.name)
  local ok, result = pcall(spec.provide, ctx, comp)
  if not ok then
    return { { text = "E:" .. comp.name, hl = "ErrorMsg" } }
  end
  local run = normalize_cells(result)
  if #run == 0 then
    return {}
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
  return run
end

-- Render one section into a flat cell list. The whole section paints in its theme group
-- for the CURRENT mode (`lualine_<section>_<mode>`): every cell with no highlight of its
-- own takes it — a component with its own `color`/per-severity hl keeps it (opts out).
-- Components are padded and joined by the component separator (drawn in the section
-- group). The powerline section arrow is appended (left half) / prepended (right half) as
-- a colour-transition cell into the neighbouring section. A section that renders empty
-- this frame emits nothing (no stray separators).
-- `opts = { section, side, component_sep, padding, sep_glyph, sep_neighbor }`.
local function render_section(comps, ctx, opts)
  local mode = themes.mode_of(nx.mode().mode)
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

  -- right half: the leading arrow transitions FROM this section's bg INTO the neighbour.
  if opts.side == "right" and opts.sep_glyph ~= "" then
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
    run[1] = { text = string.rep(" ", lpad) .. run[1].text, hl = run[1].hl }
    run[#run] = { text = run[#run].text .. string.rep(" ", rpad), hl = run[#run].hl }
    for _, c in ipairs(run) do
      emit(c)
    end
  end

  -- left half: the trailing arrow transitions FROM this section's bg INTO the neighbour.
  if opts.side == "left" and opts.sep_glyph ~= "" then
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

-- The section keys with a non-empty component list, in order — the present sections of
-- one half. Adjacency for the powerline arrows is computed over these.
local function present_sections(config, keys)
  local out = {}
  for _, sec in ipairs(keys) do
    local comps = config.sections[sec]
    if comps and #comps > 0 then
      out[#out + 1] = sec
    end
  end
  return out
end

-- Register one section's segment. `neighbor` is the letter the powerline arrow transitions
-- into (the adjacent present section, or the FILL_SECTION across a half edge).
local function build_section(config, sec, side, sep_glyph, component_sep, neighbor, out, git_segs)
  local comps = config.sections[sec]
  local segname = SECTION_SEGMENT[sec]
  local opts = {
    section = SECTION_LETTER[sec],
    side = side,
    component_sep = component_sep,
    padding = DEFAULT_PADDING,
    sep_glyph = sep_glyph,
    sep_neighbor = neighbor,
  }
  nx.statusline.segment({
    name = segname,
    events = union_events(comps),
    render = function(ctx)
      local cells = render_section(comps, ctx, opts)
      M._last[segname] = cells
      return cells
    end,
  })
  out[#out + 1] = segname
  if has_git(comps) then
    git_segs[#git_segs + 1] = segname
  end
end

-- Build one half's segments with powerline adjacency. Left sections arrow INTO the next
-- present section (or the fill); right sections arrow into the PREVIOUS present section
-- (or the fill), so the chevrons point outward from the centre on both halves.
local function build_side(config, keys, side, sep_glyph, component_sep, out, git_segs)
  local secs = present_sections(config, keys)
  for i, sec in ipairs(secs) do
    local neighbor
    if side == "left" then
      neighbor = secs[i + 1] and SECTION_LETTER[secs[i + 1]] or FILL_SECTION
    else
      neighbor = secs[i - 1] and SECTION_LETTER[secs[i - 1]] or FILL_SECTION
    end
    build_section(config, sec, side, sep_glyph, component_sep, neighbor, out, git_segs)
  end
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
  local cs = config.options.component_separators
  local ss = config.options.section_separators
  M._last = {}
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
end

-- invalidate_all(): force a re-render of every active section (the public refresh()).
function M.invalidate_all()
  for _, name in ipairs(M._active) do
    nx.statusline.invalidate(name)
  end
end

return M
