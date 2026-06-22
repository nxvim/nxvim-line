-- nxvim-line.git: the async git data source for the `branch` / `diff` components.
--
-- Runs `git` off the editor tick via `nx.run`, caches per file, and invalidates the
-- hosting segments when fresh data lands. The components' `provide` calls `ensure(buf)`
-- (kick a fetch if nothing is cached for this file yet) and reads `get(buf)`. Because a
-- custom segment re-renders whenever its window's buffer changes — a switch, OR a fresh
-- `:edit` into the reused initial buffer (the statusline updates on `:edit` even when no
-- autocmd fires) — `ensure` reliably kicks the first fetch WITHOUT depending on a load
-- event. That matters: a no-filetype `:edit` fires neither `BufEnter` (the empty buffer
-- is reused, same id) nor `FileType` nor `BufReadPost` (gated once-per-buffer by the
-- server's `announced` set).
--
-- Phase 6 polish (the "editor must never freeze" rule applied to a slow repo):
--   * DEBOUNCE — event/watch-driven refreshes coalesce per key (a burst of writes, or a
--     flurry of `.git` change events, collapses to one git run).
--   * BOUNDED RUNNER — at most `_max` git fetches run at once; the rest queue (deduped by
--     key), so opening many buffers never spawns an unbounded pile of `git` processes.
--   * A `.git` WATCH — an external commit / checkout / stage (HEAD or index changing on
--     disk) refreshes the visible bar, not just an editor event.
-- `ensure` (the cache-miss first paint) runs immediately; everything else is debounced.

local M = {}

M._cache = {} -- key (file path, or cwd for [No Name]) -> { branch, diff }
M._inflight = {} -- key -> true while its fetch is running
M._on_update = nil
M._au = {}
M._debounce = {} -- key -> pending debounce timer handle
M._watches = {} -- absolute git-dir -> nx.fs.watch handle
M._queue = {} -- bounded-runner backlog: { { k, file, dir }, … } (deduped by key)
M._active = 0 -- git fetches currently running
M._max = 4 -- concurrency cap
M._stats = { runs = 0 } -- introspection/tests: actual git fetches executed

-- Coalesce window for a debounced refresh.
M.debounce_ms = 120

local function key(buf)
  local name = nx.buf.name(buf)
  return name ~= "" and name or vim.fn.getcwd()
end

local function dir_of(buf)
  local name = nx.buf.name(buf)
  if name ~= "" then
    return name:match("^(.*)/[^/]*$") or "."
  end
  return vim.fn.getcwd()
end

function M.get(buf)
  return M._cache[key(buf)]
end

function M._parse_diff(out)
  local added, changed, removed = 0, 0, 0
  for line in (out .. "\n"):gmatch("(.-)\n") do
    local o, n = line:match("^@@ %-(%S+) %+(%S+) @@")
    if o then
      local oc = tonumber(o:match(",(%d+)$") or "1")
      local nc = tonumber(n:match(",(%d+)$") or "1")
      if oc == 0 then
        added = added + nc
      elseif nc == 0 then
        removed = removed + oc
      else
        changed = changed + math.max(oc, nc)
      end
    end
  end
  return { added = added, changed = changed, removed = removed }
end

-- Forward declarations (the runner, the watch, and the submit path reference each other).
local run_fetch, pump, ensure_watch

-- pump(): start queued fetches up to the concurrency cap, skipping any whose key went
-- inflight (a same-key request that raced in).
function pump()
  while M._active < M._max and #M._queue > 0 do
    local req = table.remove(M._queue, 1)
    if not M._inflight[req.k] then
      run_fetch(req.k, req.file, req.dir)
    end
  end
end

-- run_fetch(k, file, dir): the actual git work — branch (rev-parse) + per-file diff,
-- under the concurrency cap. On success caches the result, sets up the repo watch, fires
-- on_update; always releases its slot and pumps the queue (success or error).
function run_fetch(k, file, dir)
  M._inflight[k] = true
  M._active = M._active + 1
  M._stats.runs = M._stats.runs + 1
  local function release()
    M._inflight[k] = nil
    M._active = M._active - 1
    pump()
  end
  nx.async(function()
    local branch
    local head =
      nx.await(nx.run({ cmd = "git", args = { "-C", dir, "rev-parse", "--abbrev-ref", "HEAD" } }))
    if head.code == 0 then
      branch = head.stdout:gsub("%s+$", "")
      if branch == "" then
        branch = nil
      end
    end
    local diff
    if branch and file ~= "" then
      local d = nx.await(nx.run({ cmd = "git", args = { "-C", dir, "diff", "-U0", "--", file } }))
      if d.code == 0 then
        diff = M._parse_diff(d.stdout)
      end
    end
    -- Publish the result FIRST (release the slot, fire on_update) so a slow / failing watch
    -- setup can never starve the data path of its invalidation.
    M._cache[k] = { branch = branch, diff = diff }
    release()
    if M._on_update then
      M._on_update()
    end
    -- Best-effort: set up (once) a watch on this repo's .git so an external HEAD/index
    -- change (commit / checkout / stage) refreshes the bar. Any failure is swallowed.
    if branch then
      pcall(function()
        local gd =
          nx.await(nx.run({ cmd = "git", args = { "-C", dir, "rev-parse", "--absolute-git-dir" } }))
        if gd.code == 0 then
          ensure_watch(gd.stdout:gsub("%s+$", ""))
        end
      end)
    end
  end)():catch(function(e)
    release()
    nx.notify("nxvim-line.git: " .. tostring(e), 4)
  end)
end

-- do_refresh(buf): run a fetch now, or enqueue it (deduped by key) when at the cap. A key
-- already inflight is a no-op (its result will land).
local function do_refresh(buf)
  local k = key(buf)
  if M._inflight[k] then
    return
  end
  local file, dir = nx.buf.name(buf), dir_of(buf)
  if M._active >= M._max then
    for _, r in ipairs(M._queue) do
      if r.k == k then
        return
      end
    end
    M._queue[#M._queue + 1] = { k = k, file = file, dir = dir }
    return
  end
  run_fetch(k, file, dir)
end

-- schedule(buf): a DEBOUNCED refresh — restart the per-key timer; the fetch fires once the
-- key goes quiet for `debounce_ms`. Used by every event/watch trigger so a burst collapses.
function M.schedule(buf)
  local k = key(buf)
  local h = M._debounce[k]
  if h then
    h:stop()
  end
  M._debounce[k] = nx.timer(function()
    M._debounce[k] = nil
    do_refresh(buf)
  end, M.debounce_ms)
end

-- ensure(buf): the cache-miss FIRST paint — fetch immediately (no debounce) so the bar
-- shows git data on first render, but only when nothing is cached, inflight, or pending.
function M.ensure(buf)
  local k = key(buf)
  if M._cache[k] == nil and not M._inflight[k] and not M._debounce[k] then
    do_refresh(buf)
  end
end

-- ensure_watch(gitdir): start (once per git-dir) a non-recursive watch on `.git`; an event
-- (HEAD / index / packed-refs changing — a commit, checkout, or stage) schedules a
-- debounced refresh of the current buffer. The watch reads only; our own git reads never
-- write `.git`, so this can't self-trigger.
function ensure_watch(gitdir)
  if gitdir == "" or M._watches[gitdir] then
    return
  end
  local w = nx.fs.watch(gitdir, { recursive = false })
  M._watches[gitdir] = w
  local function loop()
    w:next()
      :and_then(function(ev)
        if ev == nil then
          return -- stopped
        end
        M.schedule(nx.buf.current())
        loop()
      end)
      :catch(function()
        M._watches[gitdir] = nil -- watch errored out; drop it (a later fetch re-arms)
      end)
  end
  loop()
end

function M.activate(on_update)
  M._on_update = on_update
  for _, id in ipairs(M._au) do
    pcall(nx.autocmd.del, id)
  end
  M._au = {}
  -- A write (diff) or cwd change (branch) force a re-fetch; BufEnter arms the repo watch
  -- for a newly-visited file's repo. All debounced so a burst collapses.
  for _, ev in ipairs({ "BufWritePost", "DirChanged", "BufEnter" }) do
    M._au[#M._au + 1] = nx.autocmd.create(ev, {
      callback = function()
        M.schedule(nx.buf.current())
      end,
    })
  end
end

function M.deactivate()
  for _, id in ipairs(M._au) do
    pcall(nx.autocmd.del, id)
  end
  M._au = {}
  for k, h in pairs(M._debounce) do
    h:stop()
    M._debounce[k] = nil
  end
  for k, w in pairs(M._watches) do
    pcall(function()
      w:stop()
    end)
    M._watches[k] = nil
  end
  M._queue = {}
  M._on_update = nil
end

return M
