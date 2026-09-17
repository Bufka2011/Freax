-- head: first lines of files or stdin (pipe-clean).
-- Usage: head [-n N] [FILE...]
local fs = require("fs")
local shell = require("shell")

local args, opts = shell.parse(...)
local n = tonumber(opts.n) or 10
if opts.help then
  io.write("Usage: head [-n N] [FILE...]\n")
  return
end
if #args == 0 then args = { "-" } end

for _, a in ipairs(args) do
  local iter, close, err
  if a == "-" then
    iter = io.stdin:lines()
  else
    local path = shell.resolve(a)
    local f
    f, err = io.open(path, "r")
    if f then
      iter = f:lines()
      close = f
    end
  end
  if not iter then
    io.stderr:write("head: " .. a .. ": " .. tostring(err) .. "\n")
  else
    local c = 0
    for line in iter do
      if c >= n then break end
      if #args > 1 and c == 0 then io.write("==> " .. a .. " <==\n") end
      io.write(line .. "\n")
      c = c + 1
    end
    if close then close:close() end
  end
end
