-- bemtvi-line.components: the component registry + the component library.
--
-- A component is `{ events = {...}, provide = function(ctx, opts) -> result }` where
-- `result` is nil (nothing), a single cell `{ text = "...", hl? = "Group" }`, or a
-- LIST of cells `{ {text, hl}, ... }` (e.g. diagnostics / diff, one coloured cell per
-- part). `provide` is PURE — it reads editor state through `btv.*` and returns cells; it
-- runs only when the section is invalidated, never per frame. `events` are the autocmd
-- events that invalidate a section using the component; `compile` unions a section's
-- components' events and hands them to `btv.statusline.segment`. `ctx = { buf, win,
-- focused }` comes from btv.statusline, so a component reads the *rendered window's*
-- buffer/cursor.
--
-- Components emit their own default icons (Phase 3) gated on `icons.enabled()`; the
-- per-severity diagnostic and per-kind diff colours use the editor's existing
-- Diagnostic*/Diff* groups. Per-mode theme colour arrives in Phase 4.

local git = require("bemtvi-line.git")
local highlights = require("bemtvi-line.highlights")
local icons = require("bemtvi-line.icons")
local lspprogress = require("bemtvi-line.lspprogress")

local M = {}

M._registry = {}

-- Components named in the plan but not yet buildable — they need an editor primitive
-- that doesn't exist. Naming one in `sections` errors with the reason (config.lua),
-- rather than silently rendering nothing (CLAUDE.md: no silent stubs). Empty today: the
-- formerly-deferred `fileformat` (now a core `'fileformat'` option) and `searchcount`
-- (computed in-plugin via `btv.buf.search`) are both implemented. The mechanism stays for
-- any future component gated on a core addition.
M._deferred = {}

function M.deferred_reason(name)
  return M._deferred[name]
end

-- register(name, spec): add a component. Public via `require("bemtvi-line").register_component`.
--
-- `spec.always = true` declares that `provide` ALWAYS yields a visible cell (`mode`,
-- `location`, `filename`, … never collapse to nothing). It is a pure optimization for
-- the powerline-arrow neighbour resolution, which only needs to know *whether* a
-- neighbouring section renders: an `always` component answers that with no call at
-- all, so a section is never speculatively rendered just to test it for emptiness.
-- Declaring it on a component that CAN return nil would strand an arrow's background
-- over a collapsed section, so leave it unset unless the component is unconditional.
--
-- `spec.file_only = true` declares that the component describes the FILE behind the
-- buffer, so it renders nothing on a plugin surface (see `is_file_buffer`) — a file tree,
-- a diff pane, the quickfix window, a terminal. `filetype` / `encoding` / `fileformat`
-- set it: a tree has no encoding and no line endings, and its "filetype" is the widget's
-- own tag rather than a language. A config entry overrides the default either way, so
-- `{ "encoding", file_only = false }` forces it on everywhere and
-- `{ "mything", file_only = true }` opts a custom component out of plugin surfaces.
function M.register(name, spec)
  if type(name) ~= "string" then
    error("bemtvi-line.register_component: name must be a string")
  end
  if type(spec) ~= "table" or type(spec.provide) ~= "function" then
    error("bemtvi-line.register_component: spec needs a 'provide' function")
  end
  if spec.events ~= nil and type(spec.events) ~= "table" then
    error("bemtvi-line.register_component: 'events' must be a list of event names")
  end
  M._registry[name] = {
    events = spec.events or {},
    provide = spec.provide,
    always = spec.always == true,
    file_only = spec.file_only == true,
  }
end

-- is_file_buffer(buf) — is `buf` an actual file buffer, as opposed to a plugin surface?
--
-- The canonical editor signal, not a guess: `'buftype'` is `""` only for a real document
-- (including a not-yet-saved `[No Name]`), and names the surface otherwise — `nofile` for
-- an `btv.view` (a file tree, a diff pane, a dock panel), `quickfix`, `terminal`. Reading
-- it here means the rule follows whatever the core models, instead of pattern-matching a
-- buffer's NAME for `[…]`-style placeholders — a heuristic that breaks on a real file
-- literally called `[foo]` and has to be re-invented by every component.
--
-- Any statusline, and any custom component, can key off the same thing: it is a plain
-- buffer option (`btv.bo[buf].buftype`, neovim's `vim.bo[buf].buftype`), nothing
-- bemtvi-line-specific.
--
-- Validity is checked first: a debounced render can land a tick after the buffer went
-- away (`:bd`, a closed panel), and reading an option off a dead handle must not throw.
function M.is_file_buffer(buf)
  return btv.buf.is_valid(buf) and btv.bo[buf].buftype == ""
end

function M.is_known(name)
  return M._registry[name] ~= nil
end

function M.get(name)
  return M._registry[name]
end

-- ----- label -----------------------------------------------------------------

-- A static-text component: `{ "label", text = "Quickfix" }`. The building block for the
-- extension layouts (a tree / quickfix title), and useful in any section.
M.register("label", {
  events = {},
  provide = function(_ctx, opts)
    local text = opts and opts.text
    if type(text) ~= "string" or text == "" then
      return nil
    end
    return { text = text }
  end,
})

-- ----- mode ------------------------------------------------------------------

-- Short mode code (`btv.mode().mode`) -> a lualine-style label. Keep this table in
-- step with `themes.MODE_OF` (which maps the same codes to a palette): a code missing
-- from either one degrades, and they must agree on which codes exist.
local MODE_LABEL = {
  n = "NORMAL",
  i = "INSERT",
  v = "VISUAL",
  V = "V-LINE",
  ["\22"] = "V-BLOCK", -- vim spells visual-block as a raw <C-v>; forward-compat
  R = "REPLACE",
  c = "COMMAND",
  t = "TERMINAL",
  m = "MULTICURSOR", -- bemtvi's multi-cursor placement mode (mode() reports "m")
  -- The `i_CTRL-O` one-shot: Normal for exactly one command, then Insert / Replace
  -- resumes, which `mode()` reports as `niI` / `niR`. lualine labels both NORMAL (it
  -- *is* Normal mode right now). Unmapped these fell through to `code:upper()` and
  -- the bar read "NII" / "NIR".
  niI = "NORMAL",
  niR = "NORMAL",
  -- Helix's selection-first modes (opt-in via `:helix` / btv.helix.enable). mode()
  -- reports "hn"/"hs"; mirror the core's Mode::label() so the bar reads HELIX /
  -- HELIX-SEL rather than the raw code.
  hn = "HELIX",
  hs = "HELIX-SEL",
  -- vim Select mode — charwise ("s") and linewise-gH ("S"). Distinct from Visual
  -- so a snippet tabstop / rename widget shows SELECT, not the raw code.
  s = "SELECT",
  S = "S-LINE",
}

-- The label for a code we don't map (a future editor mode, a `mode()` form added
-- later): the code upper-cased, with control bytes stripped. A raw control byte in a
-- status cell corrupts the bar's column math, so the fallback must stay printable.
local function fallback_label(code)
  local shown = code:upper():gsub("%c", "")
  return shown ~= "" and shown or "?"
end

M.register("mode", {
  events = { "ModeChanged" },
  always = true,
  provide = function()
    local code = btv.mode().mode
    return { text = MODE_LABEL[code] or fallback_label(code) }
  end,
})

-- ----- filename --------------------------------------------------------------

-- opts.path: 0 = tail, 1 = relative to cwd (default), 2 = absolute. The modified /
-- nomodifiable flags ride along ([+] / [-]).
--
-- The default is the cwd-relative path, NOT lualine's bare tail: two open buffers
-- called `mod.rs` are indistinguishable by tail alone, which is the common case in
-- any tree-structured project. Relative rather than absolute keeps the bar short —
-- the leading `/home/you/work/proj/` is the same for every buffer in the session and
-- carries no information. A file outside the cwd still shows its absolute path (there
-- is no relative form to fall back to), and `path = 0` restores the tail.
M.register("filename", {
  events = { "BufEnter", "BufWritePost", "TextChanged", "InsertLeave" },
  always = true, -- an unnamed buffer still shows "[No Name]"
  provide = function(ctx, opts)
    local buf = ctx.buf
    local name = btv.buf.name(buf)
    -- `or` is the right selector here even with a 0 default value: 0 is truthy in
    -- Lua, so an explicit `path = 0` survives and only nil falls through.
    local path_mode = (opts and opts.path) or 1
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
    if btv.bo[buf].modified then
      shown = shown .. " [+]"
    elseif btv.bo[buf].modifiable == false then
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
  -- A plugin surface's "filetype" is the widget's own tag (`btvtree`, `qf`), not a
  -- language worth showing; see `is_file_buffer`.
  file_only = true,
  provide = function(ctx)
    local ft = btv.bo[ctx.buf].filetype
    if not ft or ft == "" then
      return nil
    end
    local glyph = icons.for_name(btv.buf.name(ctx.buf))
    if glyph then
      return { text = glyph .. " " .. ft }
    end
    return { text = ft }
  end,
})

M.register("encoding", {
  events = { "BufEnter", "BufReadPost" },
  file_only = true, -- a plugin surface has no file, so no encoding

  provide = function(ctx)
    local enc = btv.bo[ctx.buf].fileencoding
    if not enc or enc == "" then
      return nil
    end
    return { text = enc }
  end,
})

-- The line-ending style (`btv.bo.fileformat` → unix/dos/mac). `opts.symbols` maps each to a
-- glyph/label; otherwise the bare name shows.
M.register("fileformat", {
  events = { "BufEnter", "BufReadPost", "BufWritePost" },
  file_only = true, -- …and no line endings

  provide = function(ctx, opts)
    local ff = btv.bo[ctx.buf].fileformat
    if not ff or ff == "" then
      return nil
    end
    local sym = opts and opts.symbols
    return { text = (sym and sym[ff]) or ff }
  end,
})

-- ----- location / progress ---------------------------------------------------

M.register("location", {
  events = { "CursorMoved", "CursorMovedI" },
  always = true,
  provide = function(ctx)
    local c = btv.cursor.get(ctx.win) -- { row (1-based), col (0-based) }
    return { text = string.format("%d:%d", c[1], (c[2] or 0) + 1) }
  end,
})

M.register("progress", {
  events = { "CursorMoved", "CursorMovedI" },
  always = true,
  provide = function(ctx)
    local row = btv.cursor.get(ctx.win)[1]
    local total = btv.buf.line_count(ctx.buf)
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
-- trailing space separating glyph from count); with icons off, readable letters.
local DIAG_GLYPHS =
  { error = "\u{f057} ", warn = "\u{f071} ", info = "\u{f05a} ", hint = "\u{f0eb} " }
local DIAG_LETTERS = { error = "E:", warn = "W:", info = "I:", hint = "H:" }

-- Each count takes its FOREGROUND from the editor's own group for that severity, per
-- severity 1..4, ending in the theme's hue when it defines none (see `highlights.accent`);
-- the surrounding section supplies the background.
local DIAG_HL = {
  { { "DiagnosticError", "DiagnosticSignError" }, "red" },
  { { "DiagnosticWarn", "DiagnosticSignWarn" }, "yellow" },
  { { "DiagnosticInfo", "DiagnosticSignInfo" }, "blue" },
  { { "DiagnosticHint", "DiagnosticSignHint" }, "cyan" },
}

M.register("diagnostics", {
  events = { "LspDiagnostics", "BufEnter" },
  provide = function(ctx, opts)
    local sym = (opts and opts.symbols) or (icons.enabled() and DIAG_GLYPHS or DIAG_LETTERS)
    local syms = { sym.error, sym.warn, sym.info, sym.hint }
    local counts = { 0, 0, 0, 0 } -- ERROR, WARN, INFO, HINT (severity 1..4)
    for _, d in ipairs(btv.diagnostic.get(ctx.buf)) do
      local s = d.severity
      if type(s) == "number" and counts[s] ~= nil then
        counts[s] = counts[s] + 1
      end
    end
    local cells = {}
    -- Padded on both sides in the severity's own colour, like the diff counts above.
    for i = 1, 4 do
      if counts[i] > 0 then
        cells[#cells + 1] = {
          text = " " .. syms[i] .. counts[i] .. " ",
          hl = highlights.accent(DIAG_HL[i][1], DIAG_HL[i][2]),
        }
      end
    end
    if #cells == 0 then
      return nil
    end
    return cells
  end,
})

-- ----- lsp -------------------------------------------------------------------

-- Truncate a server-authored string to `max` display-ish characters (byte-counted;
-- these are paths and counters, near always ASCII), marking the cut with an ellipsis.
--
-- The bound is not cosmetic: `message` is whatever the SERVER decided to send, and a
-- long one (a full absolute path per file, which rust-analyzer and gopls both emit)
-- would push every other section off the bar for the duration of an index. A
-- statusline component must be bounded by something the editor controls.
local function clip(s, max)
  if type(s) ~= "string" or #s <= max then
    return s
  end
  return s:sub(1, math.max(1, max - 1)) .. "\u{2026}"
end

-- One task rendered as `<spinner> <title> <message> <pct>%` — whichever of those the
-- server actually gave. A task with no percentage is indeterminate (the spinner IS
-- the progress); one with no title came from a server that reported without
-- beginning, and shows its message alone rather than a bare spinner.
local function progress_text(task, opts)
  local parts = { lspprogress.frame(opts and opts.spinner) }
  if task.title ~= "" then
    parts[#parts + 1] = task.title
  end
  if task.message then
    parts[#parts + 1] = clip(task.message, (opts and opts.max_message) or 30)
  end
  if task.percentage then
    parts[#parts + 1] = task.percentage .. "%"
  end
  return table.concat(parts, " ")
end

-- The LSP clients attached to the buffer, plus what they are BUSY with — lualine's
-- `lsp_status`. Names alone answer "is a server attached"; the progress half answers
-- "is it ready yet", which is the question during the first seconds in a large
-- project, and the one a bare name list silently gets wrong (an indexing server looks
-- identical to a finished one).
--
-- Progress is filtered to THIS buffer's clients (`btv.lsp.progress({ bufnr })`): a
-- server busy in another project's window is not this buffer's status. Only the
-- first task renders, with `(+N)` for the rest — a server may run several at once
-- (rust-analyzer routinely does) and rendering them all would be unbounded.
--
-- Opts: `progress = false` for names only; `spinner` replaces the frame list;
-- `max_message` (default 30) bounds the server's detail line.
M.register("lsp", {
  events = { "LspAttach", "LspDetach", "LspProgress", "BufEnter" },
  provide = function(ctx, opts)
    local names = {}
    for _, c in ipairs(btv.lsp.clients({ bufnr = ctx.buf }) or {}) do
      if c.name then
        names[#names + 1] = c.name
      end
    end
    if #names == 0 then
      return nil
    end
    -- Space-separated, not comma: a comma reads as one compound name
    -- (`pyright,ruff`), while spacing lets each server stand as its own word.
    local text = table.concat(names, " ")
    if not (opts and opts.progress == false) then
      local tasks = btv.lsp.progress({ bufnr = ctx.buf })
      if #tasks > 0 then
        text = text .. " " .. progress_text(tasks[1], opts)
        if #tasks > 1 then
          text = text .. " (+" .. (#tasks - 1) .. ")"
        end
      end
    end
    return { text = text }
  end,
})

-- ----- searchcount -----------------------------------------------------------

-- The match index / total for the last search pattern (vim's `searchcount()`), e.g.
-- `[3/12]`. Pure-Lua: the pattern is the read-only `/` register; matches are enumerated
-- with positions via the native `btv.buf.search`, so the cursor's index is exact. Bounded
-- by `opts.maxcount` (default 99 — vim's default) so a buffer with very many matches
-- never makes a render unbounded; beyond it the total shows as `99+`. Nothing is shown
-- when there is no pattern or no match in the buffer. Rides `CursorMoved` (a search,
-- `n`, `N` all move the cursor onto a match).
--
-- The enumeration is CACHED per buffer against `btv.buf.changedtick` — the canonical
-- "did the text change" signal — plus the pattern and the bound. That matters because
-- enumerating costs a full buffer text scan (each `btv.buf.search` runs from the previous
-- match to the next one, so the walk sweeps the buffer once, compiling the pattern per
-- call), and this component rides `CursorMoved`: recomputing per keystroke would make
-- every `j` in a large buffer O(buffer), exactly the freeze CLAUDE.md's per-event rule
-- forbids. With the cache a cursor move is a binary search over the cached starts.

-- buf -> { tick, pattern, maxcount, starts = { { line, col }, … } } for the last scan.
M._searchcount_cache = {}
-- Introspection/tests: how many actual enumerations ran (the cache-miss count).
M._searchcount_stats = { scans = 0 }

-- The enumerated match starts for `buf`, reusing the cached list when the buffer text,
-- the pattern, and the bound are all unchanged.
local function search_starts(buf, pattern, maxcount)
  local tick = btv.buf.changedtick(buf)
  local hit = M._searchcount_cache[buf]
  if hit and hit.tick == tick and hit.pattern == pattern and hit.maxcount == maxcount then
    return hit.starts
  end
  M._searchcount_stats.scans = M._searchcount_stats.scans + 1
  -- The pattern came from the `/` register, so it is written in the buffer's EFFECTIVE
  -- `'regexsyntax'` dialect — which defaults to `pcre`, not vim. Hardcoding the vim
  -- engine here silently mismatched every pattern whose spelling differs (`fo+` matched
  -- nothing), so the bar showed no count for a search the editor had just performed.
  local engine = btv.bo[buf].regexsyntax
  if engine ~= "vim" and engine ~= "pcre" then
    engine = "pcre"
  end
  local starts = {}
  local from = { line = 1, col = 0 }
  while #starts < maxcount do
    local m = btv.buf.search(buf, pattern, { engine = engine, from = from })
    if not m then
      break
    end
    starts[#starts + 1] = { line = m.line, col = m.col }
    -- advance past this match; bump by one on a zero-width match so we can't spin
    local ecol = m.end_col
    if ecol <= m.col then
      ecol = m.col + 1
    end
    from = { line = m.line, col = ecol }
  end
  -- One entry per buffer, so pruning the dead ones on each miss keeps this tiny.
  for b in pairs(M._searchcount_cache) do
    if b ~= buf and not btv.buf.is_valid(b) then
      M._searchcount_cache[b] = nil
    end
  end
  M._searchcount_cache[buf] =
    { tick = tick, pattern = pattern, maxcount = maxcount, starts = starts }
  return starts
end

-- The 1-based index of the last match starting at or before (row, col), or 0 when the
-- cursor sits before every match. `starts` is in buffer order, so this is a bisection —
-- what keeps a cursor move off the O(buffer) enumeration path.
local function index_at(starts, row, col)
  local lo, hi, found = 1, #starts, 0
  while lo <= hi do
    local mid = (lo + hi) // 2
    local s = starts[mid]
    if s.line < row or (s.line == row and s.col <= col) then
      found = mid
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return found
end

M.register("searchcount", {
  events = { "CursorMoved", "CursorMovedI" },
  provide = function(ctx, opts)
    local pattern = vim.fn.getreg("/")
    if not pattern or pattern == "" then
      return nil
    end
    local maxcount = (opts and opts.maxcount) or 99
    local starts = search_starts(ctx.buf, pattern, maxcount)
    local total = #starts
    if total == 0 then
      return nil
    end
    local cur = btv.cursor.get(ctx.win) -- { row (1-based), col (0-based) }
    local current = index_at(starts, cur[1], cur[2] or 0)
    local shown = (total >= maxcount) and (maxcount .. "+") or tostring(total)
    return { text = string.format("[%d/%s]", current, shown) }
  end,
})

-- ----- branch / diff (git, async via bemtvi-line.git) -------------------------

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
  file_only = true, -- a scratch panel must not inherit the session repo's branch

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

-- The FOREGROUND each count paints in, most specific group first (see
-- `highlights.accent`). `Added`/`Changed`/`Removed` are the standard fg-only diff-summary
-- groups every theme carries; `Diff{Add,Change,Delete}` come last because a colorscheme
-- typically gives them only the diff-VIEW background wash (catppuccin defines them with no
-- foreground at all), which is a line highlight, not a colour for a count on the bar. When
-- a theme defines none of them, the theme's own hue closes the chain.
local DIFF_ADD_HL = { "Added", "DiffAdded", "GitSignsAdd", "DiffAdd" }
local DIFF_CHANGE_HL = { "Changed", "DiffChanged", "GitSignsChange", "DiffChange" }
local DIFF_DELETE_HL = { "Removed", "DiffRemoved", "GitSignsDelete", "DiffDelete" }

M.register("diff", {
  events = { "BufEnter", "TextChanged" },
  file_only = true, -- likewise: no file, no diff against one

  provide = function(ctx)
    git.ensure(ctx.buf)
    local c = git.get(ctx.buf)
    local d = c and c.diff
    if not d then
      return nil
    end
    local cells = {}
    -- Each count owns the space on BOTH sides of it, in its own colour: the gap between
    -- two counts is then half one colour and half the other, so a count whose group
    -- carries a background reads as an evenly padded block instead of one count's colour
    -- leaking into the space before the next. (The component's OUTER padding stays
    -- neutral — compile emits it as its own cell, see `pad_run`.)
    local function push(n, prefix, hl)
      if n > 0 then
        cells[#cells + 1] = { text = " " .. prefix .. n .. " ", hl = hl }
      end
    end
    push(d.added, "+", highlights.accent(DIFF_ADD_HL, "green"))
    push(d.changed, "~", highlights.accent(DIFF_CHANGE_HL, "yellow"))
    push(d.removed, "-", highlights.accent(DIFF_DELETE_HL, "red"))
    if #cells == 0 then
      return nil
    end
    return cells
  end,
})

-- ----- daemon ----------------------------------------------------------------

-- Remote-daemon connection status (`btv.daemon.status()`), coloured per phase so a glance
-- tells you the link's health: connected green, reconnecting yellow, disconnected red —
-- the editor's existing Diagnostic{Ok,Warn,Error} groups (so a colorscheme override of
-- those just applies). A local (non-daemon) session reports nil, and the component renders
-- nothing, hiding itself. The server pushes the phase + fires `User DaemonStatusChanged`
-- (the declared event) on every change, so the section re-renders the moment the link's
-- state moves.
local DAEMON = {
  connected = { icon = "\u{f1e6}", label = "connected", hl = "DiagnosticOk" },
  reconnecting = { icon = "\u{f021}", label = "reconnecting", hl = "DiagnosticWarn" },
  disconnected = { icon = "\u{f127}", label = "disconnected", hl = "DiagnosticError" },
}

M.register("daemon", {
  events = { "User DaemonStatusChanged" },
  provide = function(_ctx, opts)
    local status = btv.daemon and btv.daemon.status()
    if not status then
      return nil -- a local (non-daemon) session: nothing to show
    end
    local d = DAEMON[status]
    if not d then
      -- An unknown phase (forward-compat): show it plainly rather than crash or hide.
      return { text = status, hl = "DiagnosticWarn" }
    end
    -- opts.label = false drops the word (icon only); a string overrides it; nil keeps the
    -- default phase word.
    local label = d.label
    if opts and opts.label ~= nil then
      label = opts.label or ""
    end
    local text = label
    if icons.enabled() and d.icon ~= "" then
      text = label == "" and d.icon or (d.icon .. " " .. label)
    end
    if text == "" then
      return nil
    end
    return { text = text, hl = d.hl }
  end,
})

return M
