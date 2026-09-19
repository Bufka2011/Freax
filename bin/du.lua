local fs = require("fs")
local shell = require("shell")

local args, options, reason = shell.parse(...)
if #args == 0 then args[1] = "." end

local VERSION = "du (Freax) 1.0"
local HELP = "Usage: du [OPTION]... [FILE]...\n" ..
  "  -h, --human-readable  print sizes in human readable format (e.g., 1K 234M 2G)\n" ..
  "  -s, --summarize       display only a total for each argument\n" ..
  "      --si              use powers of 1000 (with -h)\n" ..
  "      --help            display this help and exit\n" ..
  "      --version         output version information and exit"
local TRY = "Try 'du --help' for more information."

if options.help then io.write(HELP .. "\n") return true end
if options.version then io.write(VERSION .. "\n") return true end

local function opCheck(shortName, longName)
  local enabled = options[shortName] or options[longName]
  options[shortName] = nil
  options[longName] = nil
  return enabled
end

local bHuman = opCheck('h', 'human-readable')
local bSummary = opCheck('s', 'summarize')
local bSI = opCheck(nil, 'si')

if next(options) then
  for op, v in pairs(options) do
    io.stderr:write(string.format("du: invalid option -- '%s'\n", op))
  end
  io.stderr:write(TRY .. "\n")
  return 1
end

local function fmtSize(size)
  if not bHuman then return tostring(size) end
  local units = {"", "K", "M", "G"}
  local u = 1
  local power = bSI and 1000 or 1024
  while size > power and u < #units do u = u + 1 size = size / power end
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
  return total, dirs
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
