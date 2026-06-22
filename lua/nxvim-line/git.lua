-- nxvim-line.git: the async git data source for the `branch` / `diff` components.
--
-- Runs `git` off the editor tick via `nx.run`, caches the result per directory, and
-- invalidates the hosting segments when fresh data lands. The components' `provide`
-- stays PURE — it only reads the cache; all the side-effecting work (spawning git,
-- busting the cache) is driven by this module's own autocmds, so there is no
-- render→refresh→render loop.
--
-- Phase 2 keeps it deliberately simple (a git run per BufEnter/DirChanged/write, one
-- in-flight per dir). Phase 6 adds debounce / staleness / a watch.

local M = {}

-- dir -> { branch = string|nil, diff = { added, changed, removed } | nil }
M._cache = {}
M._inflight = {} -- dir -> true while a git run is outstanding
M._on_update = nil -- set by compile: invalidate the branch/diff segments
M._au = {} -- our autocmd ids (for idempotent re-activate / deactivate)

-- The directory to run git in for a buffer: its file's directory, else the cwd.
function M.buf_dir(buf)
  local name = nx.buf.name(buf)
  if name ~= "" then
    return name:match("^(.*)/[^/]*$") or "."
  end
  return vim.fn.getcwd()
end

function M.branch_of(buf)
  local c = M._cache[M.buf_dir(buf)]
  return c and c.branch
end

function M.diff_of(buf)
  local c = M._cache[M.buf_dir(buf)]
  return c and c.diff
end

-- Parse `git diff -U0` output into added / changed / removed line counts from the
-- hunk headers `@@ -oldStart[,oldCount] +newStart[,newCount] @@` (count omitted = 1):
-- a hunk with no old lines is a pure add, no new lines a pure delete, otherwise a
-- change (gitsigns-style). Exposed for a pure unit test.
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

-- Recompute branch + per-file diff for `buf`'s directory, off the tick. De-duplicated
-- per dir (one in-flight git at a time); on completion it caches and invalidates the
-- segments. A non-repo / git failure caches `nil` (the components then show nothing).
function M.refresh(buf)
  local dir = M.buf_dir(buf)
  if M._inflight[dir] then
    return
  end
  M._inflight[dir] = true
  local file = nx.buf.name(buf)
  nx.async(function()
    local branch
    local head = nx.await(nx.run({
      cmd = "git",
      args = { "-C", dir, "rev-parse", "--abbrev-ref", "HEAD" },
    }))
    if head.code == 0 then
      branch = head.stdout:gsub("%s+$", "")
      if branch == "" then
        branch = nil
      end
    end
    local diff
    if branch and file ~= "" then
      local d = nx.await(nx.run({
        cmd = "git",
        args = { "-C", dir, "diff", "-U0", "--", file },
      }))
      if d.code == 0 then
        diff = M._parse_diff(d.stdout)
      end
    end
    M._cache[dir] = { branch = branch, diff = diff }
    M._inflight[dir] = nil
    if M._on_update then
      M._on_update()
    end
  end)():catch(function(e)
    M._inflight[dir] = nil
    nx.notify("nxvim-line.git: " .. tostring(e), 4)
  end)
end

-- activate(on_update): (re)install the autocmds that drive refreshes and store the
-- segment-invalidation callback. Idempotent — drops the prior autocmds first. Primes
-- the current buffer immediately. Called by compile when a layout uses branch/diff.
function M.activate(on_update)
  M._on_update = on_update
  for _, id in ipairs(M._au) do
    pcall(nx.autocmd.del, id)
  end
  M._au = {}
  for _, ev in ipairs({ "BufEnter", "DirChanged", "BufWritePost" }) do
    M._au[#M._au + 1] = nx.autocmd.create(ev, {
      callback = function()
        -- Defer to the next loop turn: on a fresh `:edit` the buffer name isn't
        -- settled at BufEnter (the open converges across the tick), so refreshing now
        -- would resolve the wrong directory. Next tick the current buffer's name is
        -- ready (`nx.on_next_tick` — CLAUDE.md's cross-tick primitive).
        nx.on_next_tick(function()
          M.refresh(nx.buf.current())
        end)
      end,
    })
  end
  nx.on_next_tick(function()
    M.refresh(nx.buf.current())
  end)
end

-- deactivate(): drop our autocmds (a re-setup with no branch/diff component).
function M.deactivate()
  for _, id in ipairs(M._au) do
    pcall(nx.autocmd.del, id)
  end
  M._au = {}
  M._on_update = nil
end

return M
