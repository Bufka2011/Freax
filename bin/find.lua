local fs = require("fs")
local shell = require("shell")

local args, options = shell.parse(...)
if options.help or (#args > 1) then
  io.write("Usage: find [path] [--type=dfs] [--name=EXPR] [--iname=EXPR]\n")
  return
end

local path = #args == 1 and args[1] or "."
local bDirs, bFiles, bSyms = true, true, true
if options.type then
  bDirs = options.type == "d"
  bFiles = options.type == "f"
  bSyms = options.type == "s"
  if not (bDirs or bFiles or bSyms) then
    io.stderr:write("find: Unknown argument to type: " .. options.type .. "\n")
    return 1
  end
end

local pattern = options.iname or options.name or ""
local caseSensitive = not options.iname
if pattern ~= "" and not caseSensitive then
  pattern = pattern:lower()
end
pattern = pattern:gsub("%.", "%%."):gsub("%*", ".*")

local function matches(fname)
  if pattern == "" then return true end
  local name = fname:gsub(".*/", "")
  if not caseSensitive then name = name:lower() end
  return name:match("^" .. pattern .. "$")
end

local function validType(spath)
  if not fs.exists(spath) then return false end
  if fs.isDirectory(spath) then return bDirs end
  if fs.isLink(spath) then return bSyms end
  return bFiles
end

local function visit(rpath)
  local spath = shell.resolve(rpath)
  if matches(rpath) and validType(spath) then
    io.write(rpath:gsub("/+$", "") .. "\n")
  end
  if fs.isDirectory(spath) then
    local entries = fs.list(spath) or {}
    for _, entry in ipairs(entries) do
      visit(rpath:gsub("/+$", "") .. "/" .. entry)
    end
  end
end

visit(path)