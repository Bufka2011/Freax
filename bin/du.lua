-- du: disk usage walk (M2). Flag: -h human-readable.
local function out(s) io.write(tostring(s) .. "\n") end
local fs = require("fs")
local shell = require("shell")

local args, opts = shell.parse(...)
if #args == 0 then args = { "." } end
if opts.help then
  out("Usage: du [-h] DIR...")
  return
end

local function fmt(n)
  if not opts.h then return tostring(n) end
  local u = { "", "K", "M" }
  local i = 1
  while n >= 1024 and i < #u do n = n / 1024 i = i + 1 end
  return string.format("%.1f%s", n, u[i])
end

local function walk(path)
  local total = 0
  local isDir = fs.isDirectory(path)
  if not isDir then return fs.size(path) end
  for _, n in ipairs(fs.list(path) or {}) do
    total = total + walk(fs.concat(path, n:gsub("/$", "")))
  end
  return total
end

for _, a in ipairs(args) do
  local path = shell.resolve(a)
  if not fs.exists(path) then
    io.stderr:write("du: " .. a .. ": no such file\n")
  else
    out(fmt(walk(path)) .. " " .. a)
  end
end
