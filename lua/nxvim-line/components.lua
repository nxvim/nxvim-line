-- nxvim-line.components: the component registry + the component library.
--
-- A component is `{ events = {...}, provide = function(ctx, opts) -> result }` where
-- `result` is nil (nothing), a single cell `{ text = "...", hl? = "Group" }`, or a
-- LIST of cells `{ {text, hl}, ... }` (e.g. diagnostics / diff, one coloured cell per
-- part). `provide` is PURE — it reads editor state through `nx.*` and returns cells; it
-- runs only when the section is invalidated, never per frame. `events` are the autocmd
-- events that invalidate a section using the component; `compile` unions a section's
-- components' events and hands them to `nx.statusline.segment`. `ctx = { buf, win,
-- focused }` comes from nx.statusline, so a component reads the *rendered window's*
-- buffer/cursor.
--
-- Components emit their own default icons (Phase 3) gated on `icons.enabled()`; the
-- per-severity diagnostic and per-kind diff colours use the editor's existing
-- Diagnostic*/Diff* groups. Per-mode theme colour arrives in Phase 4.

local git = require("nxvim-line.git")
local icons = require("nxvim-line.icons")

local M = {}

M._registry = {}

-- Components named in the plan but not yet buildable — they need an editor primitive
-- that doesn't exist. Naming one in `sections` errors with the reason (config.lua),
-- rather than silently rendering nothing (CLAUDE.md: no silent stubs).
M._deferred = {
  fileformat = "needs a core 'fileformat' option (unix/dos/mac is not modelled yet)",
  searchcount = "needs core search-count state (last pattern + match count)",
}

function M.deferred_reason(name)
  return M._deferred[name]
end

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

-- ----- mode ------------------------------------------------------------------

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

-- ----- filename --------------------------------------------------------------

-- opts.path: 0 = tail (default), 1 = relative to cwd, 2 = absolute. The modified /
-- nomodifiable flags ride along ([+] / [-]).
M.register("filename", {
  events = { "BufEnter", "BufWritePost", "TextChanged", "InsertLeave" },
  provide = function(ctx, opts)
    local buf = ctx.buf
    local name = nx.buf.name(buf)
    local path_mode = (opts and opts.path) or 0
    local shown
    if name == "" then
      shown = "[No Name]"
    elseif path_mode == 1 then
      local cwd = vim.fn.getcwd()
      if cwd ~= "" and name:sub(1, #cwd + 1) == cwd .. "/" then
        shown = name:sub(#cwd + 2)
      else
        shown = name
      end
    elseif path_mode == 2 then
      shown = name
    else
      shown = name:match("[^/]*$") or name
    end
    if nx.bo[buf].modified then
      shown = shown .. " [+]"
    elseif nx.bo[buf].modifiable == false then
      shown = shown .. " [-]"
    end
    return { text = shown }
  end,
})

-- ----- filetype / encoding ---------------------------------------------------

-- The devicon is resolved from the buffer's *filename* (extension/exact name), the same
-- as lualine's nvim-web-devicons lookup; the glyph rides in the cell and inherits the
-- section highlight. With icons disabled (`icons_enabled = false`) the name shows plain.
M.register("filetype", {
  events = { "FileType", "BufEnter" },
  provide = function(ctx)
    local ft = nx.bo[ctx.buf].filetype
    if not ft or ft == "" then
      return nil
    end
    local glyph = icons.for_name(nx.buf.name(ctx.buf))
    if glyph then
      return { text = glyph .. " " .. ft }
    end
    return { text = ft }
  end,
})

M.register("encoding", {
  events = { "BufEnter", "BufReadPost" },
  provide = function(ctx)
    local enc = nx.bo[ctx.buf].fileencoding
    if not enc or enc == "" then
      return nil
    end
    return { text = enc }
  end,
})

-- ----- location / progress ---------------------------------------------------

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

-- ----- diagnostics -----------------------------------------------------------

-- opts.symbols overrides the per-severity prefix. With icons on, Nerd-Font glyphs (a
-- trailing space separating glyph from count); with icons off, readable letters. Each
-- count is coloured with the editor's existing Diagnostic* groups.
local DIAG_GLYPHS =
  { error = "\u{f057} ", warn = "\u{f071} ", info = "\u{f05a} ", hint = "\u{f0eb} " }
local DIAG_LETTERS = { error = "E:", warn = "W:", info = "I:", hint = "H:" }
local DIAG_HL = { "DiagnosticError", "DiagnosticWarn", "DiagnosticInfo", "DiagnosticHint" }

M.register("diagnostics", {
  events = { "LspDiagnostics", "BufEnter" },
  provide = function(ctx, opts)
    local sym = (opts and opts.symbols) or (icons.enabled() and DIAG_GLYPHS or DIAG_LETTERS)
    local syms = { sym.error, sym.warn, sym.info, sym.hint }
    local counts = { 0, 0, 0, 0 } -- ERROR, WARN, INFO, HINT (severity 1..4)
    for _, d in ipairs(nx.diagnostic.get(ctx.buf)) do
      local s = d.severity
      if type(s) == "number" and counts[s] ~= nil then
        counts[s] = counts[s] + 1
      end
    end
    local cells = {}
    for i = 1, 4 do
      if counts[i] > 0 then
        local prefix = #cells > 0 and " " or ""
        cells[#cells + 1] = { text = prefix .. syms[i] .. counts[i], hl = DIAG_HL[i] }
      end
    end
    if #cells == 0 then
      return nil
    end
    return cells
  end,
})

-- ----- lsp -------------------------------------------------------------------

M.register("lsp", {
  events = { "LspAttach", "BufEnter" },
  provide = function(ctx)
    local names = {}
    for _, c in ipairs(nx.lsp.clients({ bufnr = ctx.buf }) or {}) do
      if c.name then
        names[#names + 1] = c.name
      end
    end
    if #names == 0 then
      return nil
    end
    return { text = table.concat(names, ",") }
  end,
})

-- ----- branch / diff (git, async via nxvim-line.git) -------------------------

-- These depend on the window's buffer, so they re-render on the events that signal a
-- buffer change: `BufEnter` (a switch) and `TextChanged` (a fresh `:edit` reuses the
-- empty initial buffer — same id, so no `BufEnter` — but loading the file advances the
-- changedtick, firing `TextChanged`). On each render `git.ensure` does a one-shot
-- cache-miss fetch, then `git`'s own update invalidates the segment to paint the result.
-- compile activates/deactivates the git module based on whether either is in the layout.

-- The branch glyph (nf-pl-branch ) when icons are on; the bare name otherwise.
local BRANCH_ICON = "\u{e0a0} "

M.register("branch", {
  events = { "BufEnter", "TextChanged" },
  provide = function(ctx)
    git.ensure(ctx.buf)
    local c = git.get(ctx.buf)
    local b = c and c.branch
    if not b or b == "" then
      return nil
    end
    return { text = (icons.enabled() and BRANCH_ICON or "") .. b }
  end,
})

M.register("diff", {
  events = { "BufEnter", "TextChanged" },
  provide = function(ctx)
    git.ensure(ctx.buf)
    local c = git.get(ctx.buf)
    local d = c and c.diff
    if not d then
      return nil
    end
    local cells = {}
    local function push(n, prefix, hl)
      if n > 0 then
        local sep = #cells > 0 and " " or ""
        cells[#cells + 1] = { text = sep .. prefix .. n, hl = hl }
      end
    end
    push(d.added, "+", "DiffAdd")
    push(d.changed, "~", "DiffChange")
    push(d.removed, "-", "DiffDelete")
    if #cells == 0 then
      return nil
    end
    return cells
  end,
})

return M
