-- A small sample buffer for the nxvim-line demo.
-- Open it (NXVIM_CONFIG=examples nxvim examples/sample.lua), then switch modes
-- (i / v / :) and move the cursor to watch the statusline react.

local function greet(who)
  return "hello, " .. (who or "world")
end

local people = { "ada", "alan", "grace" }
for _, p in ipairs(people) do
  print(greet(p))
end

return { greet = greet }
