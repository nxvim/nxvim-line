-- nxvim-line.components: the component registry + the Phase-1 component library.
--
-- A component is `{ events = {...}, provide = function(ctx, opts) -> cell | nil }`:
--   * `provide` is PURE — it reads editor state through `nx.*` and returns a single
--     cell `{ text = "...", hl? = "Group", icon? = "..." }` (or nil for nothing). It
--     runs only when the section is invalidated, never per frame.
--   * `events` are the autocmd events that should invalidate a section using this
--     component. `compile` unions a section's components' events and hands them to
--     `nx.statusline.segment`, which wires the invalidation.
--   * `ctx = { buf, win, focused }` comes from nx.statusline, so a component reads the
--     *rendered window's* buffer/cursor, not just the current one.
--
-- Phase 2+ splits these into components/<name>.lua and adds branch/diff/encoding/
-- fileformat/lsp/searchcount; icons + per-component colour arrive in Phase 3/4.

local M = {}

M._registry = {}

-- register(name, spec): add a component. Public via `require("nxvim-line").register_component`.
function M.register(name, spec)
  if type(name) ~= "string" then
    error("nxvim-line.register_component: name must be a string")
  end
  if type(spec) ~= "table" or type(spec.provide) ~= "function" then
    error("nxvim-line.register_component: spec needs a 'provide' function")
  end
  if spec.events ~= nil and type(spec.events) ~= "table" then
    error("nxvim-line.register_component: 'events' must be a list of event names")
  end
  M._registry[name] = { events = spec.events or {}, provide = spec.provide }
end

function M.is_known(name)
  return M._registry[name] ~= nil
end

function M.get(name)
  return M._registry[name]
end

-- ----- the Phase-1 components ------------------------------------------------

-- Short mode code (`nx.mode().mode`) -> a lualine-style label.
local MODE_LABEL = {
  n = "NORMAL",
  i = "INSERT",
  v = "VISUAL",
  V = "V-LINE",
  R = "REPLACE",
  c = "COMMAND",
  t = "TERMINAL",
}

M.register("mode", {
  events = { "ModeChanged" },
  provide = function()
    local code = nx.mode().mode
    return { text = MODE_LABEL[code] or code:upper() }
  end,
})

M.register("filename", {
  events = { "BufEnter", "BufWritePost" },
  provide = function(ctx)
    local name = nx.buf.name(ctx.buf)
    if name == "" then
      return { text = "[No Name]" }
    end
    -- Phase 1: the tail only. Phase 2 adds path modes + [+]/[-]/[RO] flags.
    return { text = name:match("[^/]*$") or name }
  end,
})

M.register("filetype", {
  events = { "FileType", "BufEnter" },
  provide = function(ctx)
    local ft = nx.bo[ctx.buf].filetype
    if not ft or ft == "" then
      return nil
    end
    return { text = ft }
  end,
})

M.register("location", {
  events = { "CursorMoved", "CursorMovedI" },
  provide = function(ctx)
    local c = nx.cursor.get(ctx.win) -- { row (1-based), col (0-based) }
    return { text = string.format("%d:%d", c[1], (c[2] or 0) + 1) }
  end,
})

M.register("progress", {
  events = { "CursorMoved", "CursorMovedI" },
  provide = function(ctx)
    local row = nx.cursor.get(ctx.win)[1]
    local total = nx.buf.line_count(ctx.buf)
    if total <= 1 or row <= 1 then
      return { text = "Top" }
    end
    if row >= total then
      return { text = "Bot" }
    end
    return { text = string.format("%d%%", math.floor((row - 1) / (total - 1) * 100)) }
  end,
})

M.register("diagnostics", {
  events = { "LspDiagnostics", "BufEnter" },
  provide = function(ctx)
    local counts = { 0, 0, 0, 0 } -- ERROR, WARN, INFO, HINT (severity 1..4)
    for _, d in ipairs(nx.diagnostic.get(ctx.buf)) do
      local s = d.severity
      if type(s) == "number" and counts[s] ~= nil then
        counts[s] = counts[s] + 1
      end
    end
    -- Phase 1: plain "E:n W:n …" text. Phase 2 adds icons + per-severity colours.
    local labels = { "E", "W", "I", "H" }
    local parts = {}
    for i = 1, 4 do
      if counts[i] > 0 then
        parts[#parts + 1] = labels[i] .. ":" .. counts[i]
      end
    end
    if #parts == 0 then
      return nil
    end
    return { text = table.concat(parts, " ") }
  end,
})

return M
