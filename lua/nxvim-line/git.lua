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
-- server's `announced` set). Writes / cwd changes force a re-fetch.
--
-- No render->refresh loop: `ensure` only fires on a cache MISS, so once a fetch caches,
-- the invalidate-driven re-render reads the cache and stops.
-- Phase 6 polish: debounce, a staleness TTL, a repo watch.

local M = {}

M._cache = {} -- key (file path, or cwd for [No Name]) -> { branch, diff }
M._inflight = {}
M._on_update = nil
M._au = {}

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

function M.refresh(buf)
  local k = key(buf)
  if M._inflight[k] then
    return
  end
  M._inflight[k] = true
  local file = nx.buf.name(buf)
  local dir = dir_of(buf)
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
    M._cache[k] = { branch = branch, diff = diff }
    M._inflight[k] = nil
    if M._on_update then
      M._on_update()
    end
  end)():catch(function(e)
    M._inflight[k] = nil
    nx.notify("nxvim-line.git: " .. tostring(e), 4)
  end)
end

function M.ensure(buf)
  local k = key(buf)
  if M._cache[k] == nil and not M._inflight[k] then
    M.refresh(buf)
  end
end

function M.activate(on_update)
  M._on_update = on_update
  for _, id in ipairs(M._au) do
    pcall(nx.autocmd.del, id)
  end
  M._au = {}
  -- Force a re-fetch when a cached file's git state may have changed: a write (diff)
  -- or a cwd change (branch). First loads / switches are handled by ensure() from render.
  for _, ev in ipairs({ "BufWritePost", "DirChanged" }) do
    M._au[#M._au + 1] = nx.autocmd.create(ev, {
      callback = function()
        M.refresh(nx.buf.current())
      end,
    })
  end
end

function M.deactivate()
  for _, id in ipairs(M._au) do
    pcall(nx.autocmd.del, id)
  end
  M._au = {}
  M._on_update = nil
end

return M
