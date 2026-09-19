local fs = require("fs")
local shell = require("shell")

local args, options, reason = shell.parse(...)
if #args == 0 then args[1] = "." end

if options.help then io.write("Usage: du [OPTION]... [FILE]...\n  -h  human-readable\n  -s  summarize only\n") return true end

local bHuman = options.h or options["human-readable"]
local bSummary = options.s or options.summarize

if next(options) then
  for op in pairs(options) do io.stderr:write("du: invalid option -- " .. op .. "\n") end
  return 1
end

local function fmtSize(size)
  if not bHuman then return tostring(size) end
  local units = {"", "K", "M", "G"}
  local u = 1
  while size > 1024 and u < #units do u = u + 1 size = size / 1024 end
  return math.floor(size * 10) / 10 .. units[u]
end

local function visitor(rpath)
  local total = 0
  local dirs = 0
  local spath = shell.resolve(rpath)
  if fs.isDirectory(spath) then
    local entries = fs.list(spath) or {}
    for _, entry in ipairs(entries) do
      local st, sd = visitor(rpath:gsub("/+$", "") .. "/" .. entry)
      total = total + st
      dirs = dirs + sd
    end
    if dirs == 0 and not bSummary then
      io.write(string.format("%-12s%s\n", fmtSize(total), rpath))
    end
  elseif not fs.isLink(spath) then
    total = fs.size(spath)
  end
  return total, dirs + (fs.isDirectory(spath) and 1 or 0)
end

for _, arg in ipairs(args) do
  local spath = shell.resolve(arg)
  if not fs.exists(spath) then
    io.stderr:write("du: cannot access '" .. arg .. "': no such file or directory\n")
    return 1
  end
  if fs.isDirectory(spath) then
    local total = visitor(arg)
    if bSummary then io.write(string.format("%-12s%s\n", fmtSize(total), arg)) end
  elseif fs.isLink(spath) then
    io.write(string.format("%-12s%s\n", "0", arg))
  else
    io.write(string.format("%-12s%s\n", fmtSize(fs.size(spath)), arg))
  end
end
return true