-- cat: concatenate files or stdin (pipe-clean).
local fs = require("fs")
local shell = require("shell")

local args, opts = shell.parse(...)
if opts.help then
  io.write("Usage: cat [FILE...]  (no files = stdin, like pipes)\n")
  return
end
if #args == 0 then args = { "-" } end

for _, a in ipairs(args) do
  if a == "-" then
    for line in io.stdin:lines() do io.write(line .. "\n") end
  else
    local path = shell.resolve(a)
    if fs.isDirectory(path) then
      io.stderr:write("cat: " .. a .. ": Is a directory\n")
    else
      local f, err = io.open(path, "r")
      if not f then
        io.stderr:write("cat: " .. a .. ": " .. tostring(err) .. "\n")
      else
        for line in f:lines() do io.write(line .. "\n") end
        f:close()
      end
    end
  end
end
