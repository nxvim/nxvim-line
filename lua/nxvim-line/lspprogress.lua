-- The spinner clock behind the `lsp` component's progress half.
--
-- The DATA needs no help: `nx.lsp.progress()` is a mirror the editor keeps current,
-- and every update fires `LspProgress`, which the component already declares as an
-- invalidation event. What needs a clock is only the ANIMATION — a server that
-- reports once and then works quietly for ten seconds would otherwise show a frozen
-- spinner frame, which reads as "hung" rather than "busy".
--
-- So the timer exists solely to advance the frame, and it runs ONLY while some task
-- is in flight: armed on the first `LspProgress`, and it stops itself the moment
-- `nx.lsp.progress()` comes back empty. An always-on animation timer would be a
-- permanent wakeup for a bar that is idle almost all of the time.
--
--     nxvim --test-plugin ~/work/nxvim-plugins/nxvim-line

local M = {}

-- Braille dots — plain Unicode (U+2800 block), not a Nerd Font glyph, so they render
-- without a patched font and are NOT gated on `icons_enabled`. Written as \u escapes
-- to keep the source ASCII. `opts.spinner` on the component replaces the list.
M.FRAMES = {
  "\u{280b}",
  "\u{2819}",
  "\u{2839}",
  "\u{2838}",
  "\u{283c}",
  "\u{2834}",
  "\u{2826}",
  "\u{2827}",
  "\u{2807}",
  "\u{280f}",
}

-- Milliseconds per frame. Fast enough to read as motion, coarse enough that a whole
-- statusline re-render per frame is nothing next to the work the server is doing.
M.INTERVAL = 100

-- The current frame index (1-based into a frame list), advanced by the tick.
M._frame = 1
-- Whether a tick is armed. Guards against arming a second loop per event — a server
-- reporting per file fires `LspProgress` dozens of times a second.
M._ticking = false
-- Bumped by every activate/deactivate so an in-flight tick from a previous layout
-- retires instead of animating a segment that no longer exists (the same generation
-- guard `compile.start_refresh` uses).
M._gen = 0
M._on_update = nil
M._au = {}

-- The spinner glyph for this render, out of `frames` (default `M.FRAMES`). Reading
-- the frame is pure — the tick owns advancing it — so two components sharing the
-- clock stay in phase.
function M.frame(frames)
  frames = (type(frames) == "table" and #frames > 0) and frames or M.FRAMES
  return frames[(M._frame - 1) % #frames + 1]
end

-- Is any server running a task right now? The tick's stop condition, and the guard
-- that keeps the clock off entirely for a session whose servers are idle.
function M.busy()
  return #nx.lsp.progress() > 0
end

-- Arm the frame clock if it isn't already running. Self-stopping: the tick re-arms
-- only while work remains, so the timer disappears with the last `end`.
local function ensure_tick()
  if M._ticking or not M.busy() then
    return
  end
  M._ticking = true
  local gen = M._gen
  local function tick()
    if gen ~= M._gen then
      M._ticking = false
      return -- superseded by a later activate()/deactivate()
    end
    if not M.busy() then
      M._ticking = false
      return -- nothing left to animate
    end
    M._frame = M._frame + 1
    if M._on_update then
      M._on_update()
    end
    nx.timer(tick, M.INTERVAL)
  end
  nx.timer(tick, M.INTERVAL)
end

-- activate(on_update): drive the spinner for a layout that renders progress.
-- `on_update` invalidates the hosting segments (compile.lua passes it, exactly as it
-- does for the git source). Idempotent — re-activating drops the previous autocmd and
-- retires any in-flight tick.
function M.activate(on_update)
  M.deactivate()
  M._on_update = on_update
  M._au[#M._au + 1] = nx.autocmd.create("LspProgress", {
    callback = function()
      -- The event itself already invalidates the segment (the component declares it),
      -- so this only has to make sure the clock is running between events.
      ensure_tick()
    end,
  })
  -- A layout can be (re)built while a server is already mid-task — a `:source` of the
  -- config during an index. Nothing would fire until that task's next report, so start
  -- from whatever is in flight right now.
  ensure_tick()
end

-- deactivate(): stop driving. The in-flight tick retires on its generation check
-- rather than being cancelled, since `nx.timer` is one-shot and there is at most one
-- outstanding frame.
function M.deactivate()
  M._gen = M._gen + 1
  for _, id in ipairs(M._au) do
    pcall(nx.autocmd.del, id)
  end
  M._au = {}
  M._on_update = nil
end

return M
