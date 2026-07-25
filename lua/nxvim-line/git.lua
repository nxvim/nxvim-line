-- nxvim-line.git: the async git data source for the `branch` / `diff` components.
--
-- Queries git off the editor tick via the native `nx.git.*` API, caches per file, and invalidates the
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

-- Should this buffer resolve git data at all? Only a real file buffer (`buftype == ""`)
-- does — a named file resolves against its own dir, and the empty No Name buffer against
-- cwd like lualine. A scratch surface (`buftype ~= ""`: a `nofile` panel/listing like
-- `:messages`, the quickfix window, a terminal, …) has no file backing, so it must NOT
-- inherit the launch directory's branch. This is the neovim-idiomatic guard; before the
-- core modelled `nofile`, `dir_of` saw a panel's slash-less placeholder name and fell
-- back to `"."` (cwd), leaking the session's repo branch onto every scratch panel.
local function is_git_buffer(buf)
  -- A debounced refresh lands a tick or more after it was scheduled, by which time the
  -- buffer may be gone (`:bd`, a closed panel). Validity is checked here rather than at
  -- each call site so no path can resolve `nx.buf.name` on a dead buffer and fall back
  -- to cwd — which would fetch the SESSION's branch under a key nothing displays.
  return nx.buf.is_valid(buf) and nx.bo[buf].buftype == ""
end

function M.get(buf)
  return M._cache[key(buf)]
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
  -- The slot is released inline (as soon as the data is published) AND from the
  -- promise's `catch`, because anything after the inline release — notably the
  -- `on_update` callback — can still throw. Guard it so those two paths can't both
  -- decrement: an `on_update` that errors used to drive `_active` below zero, which
  -- silently UNCAPS the runner (`_active < _max` stays true forever) and lets an
  -- unbounded pile of git fetches run at once.
  local released = false
  local function release()
    if released then
      return
    end
    released = true
    M._inflight[k] = nil
    M._active = M._active - 1
    pump()
  end
  nx.async(function()
    -- Branch via the native `nx.git.head` (replaces `git rev-parse --abbrev-ref HEAD`).
    -- A path outside a repo REJECTS (ENOREPO) — swallow it and leave `branch` nil, the
    -- old "code ~= 0 → no branch" behavior. An unborn HEAD still reports its branch name.
    local branch
    local ok_head, head = pcall(nx.await, nx.git.head(dir))
    if ok_head and head.branch and head.branch ~= "" then
      branch = head.branch
    end
    -- Per-file working-tree-vs-HEAD counts via the native `nx.git.diff_file` (replaces
    -- `git diff -U0` + the hand-rolled `@@`-hunk parser). It resolves right to
    -- { added, changed, removed } — the exact shape the components read.
    local diff
    if branch and file ~= "" then
      local ok_diff, d = pcall(nx.await, nx.git.diff_file(dir, file))
      if ok_diff then
        diff = d
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
    -- `nx.git.discover` gives the absolute git-dir (replaces `rev-parse --absolute-git-dir`).
    if branch then
      pcall(function()
        local disc = nx.await(nx.git.discover(dir))
        ensure_watch(disc.git_dir)
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
  if not is_git_buffer(buf) then
    return
  end
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
  if not is_git_buffer(buf) then
    return -- nothing to coalesce; don't key a timer off a dead buffer's cwd fallback
  end
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
  if not is_git_buffer(buf) then
    return
  end
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
