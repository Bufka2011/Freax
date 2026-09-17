-- tree: directory tree (M2).
local function out(s) io.write(tostring(s) .. "\n") end
local fs = require("fs")
local shell = require("shell")

local args, opts = shell.parse(...)
local roots = #args > 0 and args or { "." }
if opts.help then
  out("Usage: tree [DIR...]")
  return
end

local function show(path, prefix)
  local list = fs.list(path) or {}
  table.sort(list)
  for i, n in ipairs(list) do
    local last = i == #list
    out(prefix .. (last and "'-- " or "|-- ") .. n)
    local full = fs.concat(path, n:gsub("/$", ""))
    if fs.isDirectory(full) then
      show(full, prefix .. (last and "    " or "|   "))
    end
  end
end

for _, r in ipairs(roots) do
  local path = shell.resolve(r)
  out(r)
  if not fs.exists(path) then
    io.stderr:write("tree: " .. r .. ": no such file\n")
  else
    show(path, "")
  end
end
