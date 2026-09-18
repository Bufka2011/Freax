-- ls: list directory (pipe-clean: data via io).
-- Usage: ls [-a] [-l] [path...]
local fs = require("fs")
local shell = require("shell")

local args, opts = shell.parse(...)
if opts.help then
  io.write("Usage: ls [-a] [-l] [FILE]...\n")
  return
end
if #args == 0 then args = { "." } end

local ec = 0
for _, a in ipairs(args) do
  local path = shell.resolve(a)
  local isDir = fs.isDirectory(path)
  if isDir == nil then
    ec = 1
    io.stderr:write("ls: cannot access " .. a .. ": no such file\n")
  elseif not isDir then
    local isLink, target = fs.isLink(path)
    if opts.l and isLink then
      io.write(string.format("l %6d %s -> %s\n", fs.size(path), a, tostring(target)))
    else
      io.write(a .. "\n")
    end
  else
    local list, err = fs.list(path)
    if not list then
      ec = 1
      io.stderr:write("ls: " .. a .. ": " .. tostring(err) .. "\n")
    else
      local names = {}
      for _, n in ipairs(list) do
        if opts.a or n:sub(1, 1) ~= "." then names[#names + 1] = n end
      end
      table.sort(names)
      if #args > 1 then io.write(a .. ":\n") end
      for _, n in ipairs(names) do
        if opts.l then
          local full = fs.concat(path, n:gsub("/$", ""))
          local isLink, target = fs.isLink(full)
          local dir = fs.isDirectory(full)
          local sz = dir and 0 or fs.size(full)
          if isLink then
            io.write(string.format("l %6d %s -> %s\n", sz, n, tostring(target)))
          else
            io.write(string.format("%s %6d %s\n", dir and "d" or "f", sz, n))
          end
        else
          io.write(n .. "\n")
        end
      end
    end
  end
end
return ec
