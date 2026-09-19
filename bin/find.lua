local fs = require("fs")
local shell = require("shell")
local text = require("text")

local USAGE = "Usage: find [path] [--type=dfs] [--[i]name=EXPR]\n  --type  d:directory, f:file, s:symlink\n  --name  glob pattern (case sensitive)\n  --iname glob pattern (case insensitive)\n"

local args, options = shell.parse(...)

if options.help then print(USAGE); return 0 end

if #args > 1 then io.stderr:write(USAGE); return 1 end

local path = #args == 1 and args[1] or "."

local bDirs, bFiles, bSyms = true, true, true

if options.iname and options.name then
  io.stderr:write("find: cannot define both iname and name\n"); return 1
end

if options.type then
  bDirs, bFiles, bSyms = false, false, false
  if options.type == "f" then bFiles = true
  elseif options.type == "d" then bDirs = true
  elseif options.type == "s" then bSyms = true
  else io.stderr:write("find: Unknown argument to type: " .. options.type .. "\n"); return 1 end
end

local fileNamePattern = ""
local bCaseSensitive = true

if options.iname or options.name then
  bCaseSensitive = options.iname == nil
  fileNamePattern = options.iname or options.name
  if type(fileNamePattern) ~= "string" then io.stderr:write("find: missing argument to --name\n"); return 1 end
  if not bCaseSensitive then fileNamePattern = fileNamePattern:lower() end
  fileNamePattern = text.escapeMagic(fileNamePattern)
  fileNamePattern = fileNamePattern:gsub("%%%*", ".*")
end

local function isValidType(spath)
  if not fs.exists(spath) then return false end
  if fileNamePattern ~= "" then
    local name = spath:gsub(".*/", "")
    local cmp = bCaseSensitive and name or name:lower()
    local s, e = cmp:find(fileNamePattern)
    if not s or s ~= 1 or e ~= #cmp then return false end
  end
  if fs.isDirectory(spath) then return bDirs end
  if fs.isLink(spath) then return bSyms end
  return bFiles
end

local function visit(rpath)
  local spath = shell.resolve(rpath)
  if isValidType(spath) then print(rpath:gsub("/+$", "")) end
  if fs.isDirectory(spath) then
    for _, item in ipairs(fs.list(spath) or {}) do
      visit(rpath:gsub("/+$", "") .. "/" .. item)
    end
  end
end

visit(path)