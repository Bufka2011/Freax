-- sort: sort lines from files or stdin (pipe-clean).
-- Flags: -r reverse, -n numeric, -u unique.
local fs = require("fs")
local shell = require("shell")

local args, opts = shell.parse(...)
if opts.help then
  io.write("Usage: sort [-rnu] [FILE...]\n")
  return
end
if #args == 0 then args = { "-" } end

local lines = {}
for _, a in ipairs(args) do
  if a == "-" then
    for line in io.stdin:lines() do lines[#lines + 1] = line end
  else
    local f, err = io.open(shell.resolve(a), "r")
    if not f then
      io.stderr:write("sort: " .. a .. ": " .. tostring(err) .. "\n")
    else
      for line in f:lines() do lines[#lines + 1] = line end
      f:close()
    end
  end
end
if opts.n then
  table.sort(lines, function(x, y)
    return (tonumber(x:match("%d+")) or 0) < (tonumber(y:match("%d+")) or 0)
  end)
else
  table.sort(lines)
end
if opts.r then
  for i = 1, #lines / 2 do
    lines[i], lines[#lines - i + 1] = lines[#lines - i + 1], lines[i]
  end
end
local seen
if opts.u then seen = {} end
for _, l in ipairs(lines) do
  if not seen or not seen[l] then
    if seen then seen[l] = true end
    io.write(l .. "\n")
  end
end
