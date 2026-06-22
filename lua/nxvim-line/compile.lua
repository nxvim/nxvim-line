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
-- distinct from the `lualine_<section>_<mode>` HIGHLIGHT groups Phase 4 will define.)

local components = require("nxvim-line.components")
local git = require("nxvim-line.git")
local icons = require("nxvim-line.icons")
local highlights = require("nxvim-line.highlights")

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
local LEFT = { "lualine_a", "lualine_b", "lualine_c" }
local RIGHT = { "lualine_x", "lualine_y", "lualine_z" }

-- The segment names of the most recent build (for refresh()/invalidate_all).
M._active = {}

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

-- Render one section into a flat cell list. Each present component is padded (its own
-- `padding`, else the section default) and the configured component separator glyph sits
-- between adjacent components, drawn in the section's base highlight. An empty separator
-- degrades to just the paddings. `opts = { component_sep, padding }`.
local function render_section(comps, ctx, opts)
  local pieces = {}
  for _, comp in ipairs(comps) do
    local run = component_cells(comp, ctx)
    if #run > 0 then
      pieces[#pieces + 1] = { comp = comp, cells = run }
    end
  end

  local cells = {}
  for i, piece in ipairs(pieces) do
    if i > 1 and opts.component_sep ~= "" then
      cells[#cells + 1] = { text = opts.component_sep }
    end
    local lpad, rpad = resolve_padding(piece.comp, opts.padding)
    local run = piece.cells
    run[1] = { text = string.rep(" ", lpad) .. run[1].text, hl = run[1].hl }
    run[#run] = { text = run[#run].text .. string.rep(" ", rpad), hl = run[#run].hl }
    for _, c in ipairs(run) do
      cells[#cells + 1] = c
    end
  end
  return cells
end

-- The de-duplicated, order-preserving union of a section's components' declared events.
local function union_events(comps)
  local seen, out = {}, {}
  for _, comp in ipairs(comps) do
    for _, ev in ipairs(components.get(comp.name).events) do
      if not seen[ev] then
        seen[ev] = true
        out[#out + 1] = ev
      end
    end
  end
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

local function build_side(config, keys, out, git_segs, component_sep)
  local padding = DEFAULT_PADDING
  local opts = { component_sep = component_sep, padding = padding }
  for _, sec in ipairs(keys) do
    local comps = config.sections[sec]
    if comps and #comps > 0 then
      local segname = SECTION_SEGMENT[sec]
      nx.statusline.segment({
        name = segname,
        events = union_events(comps),
        render = function(ctx)
          return render_section(comps, ctx, opts)
        end,
      })
      out[#out + 1] = segname
      if has_git(comps) then
        git_segs[#git_segs + 1] = segname
      end
    end
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

  -- Left sections use `component_separators.left`, right sections `.right` (lualine).
  local cs = config.options.component_separators
  local left, right = {}, {}
  local git_segs = {}
  build_side(config, LEFT, left, git_segs, cs.left)
  build_side(config, RIGHT, right, git_segs, cs.right)

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
