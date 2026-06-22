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

local M = {}

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

-- Render one section: each component contributes one or more cells, padded as a unit
-- (one leading + one trailing space around the whole component's run; the component
-- owns any spacing between its own sub-cells). A component whose `provide` errors
-- becomes a loud ` E:<name> ` cell rather than killing the section; a nil/empty result
-- contributes nothing. (Separators / per-component padding options are Phase 3.)
local function render_section(comps, ctx)
  local cells = {}
  for _, comp in ipairs(comps) do
    local spec = components.get(comp.name)
    local ok, result = pcall(spec.provide, ctx, comp)
    if not ok then
      cells[#cells + 1] = { text = " E:" .. comp.name .. " ", hl = "ErrorMsg" }
    else
      local run = normalize_cells(result)
      if #run > 0 then
        run[1] = { text = " " .. run[1].text, hl = run[1].hl }
        run[#run] = { text = run[#run].text .. " ", hl = run[#run].hl }
        for _, c in ipairs(run) do
          cells[#cells + 1] = c
        end
      end
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

local function build_side(config, keys, out, git_segs)
  for _, sec in ipairs(keys) do
    local comps = config.sections[sec]
    if comps and #comps > 0 then
      local segname = SECTION_SEGMENT[sec]
      nx.statusline.segment({
        name = segname,
        events = union_events(comps),
        render = function(ctx)
          return render_section(comps, ctx)
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
  local left, right = {}, {}
  local git_segs = {}
  build_side(config, LEFT, left, git_segs)
  build_side(config, RIGHT, right, git_segs)

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
