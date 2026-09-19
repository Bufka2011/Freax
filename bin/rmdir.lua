local fs = require("fs")
local shell = require("shell")

local args, options = shell.parse(...)
if options.help then
  io.write("Usage: rmdir [OPTION]... DIRECTORY...\n  -p  remove DIRECTORY and its ancestors\n  -v  verbose\n")
  return
end
if #args == 0 then io.stderr:write("rmdir: missing operand\n") return 1 end

local bRec = options.p or options.parents
local bVerbose = options.v or options.verbose
local bQuiet = options.q or options["ignore-fail-on-non-empty"]
local ec = 0

local function removeEmpty(path)
  if not path then return true end
  if bVerbose then io.write("rmdir: removing directory, " .. path .. "\n") end
  local rpath = shell.resolve(path)
  if not fs.exists(rpath) then
    io.stderr:write("rmdir: cannot remove " .. path .. ": no such file or directory\n")
    ec = 1; return false
  end
  if not fs.isDirectory(rpath) then
    io.stderr:write("rmdir: cannot remove " .. path .. ": not a directory\n")
    ec = 1; return false
  end
  local list = fs.list(rpath)
  if list and #list > 0 then
    if not bQuiet then io.stderr:write("rmdir: failed to remove " .. path .. ": Directory not empty\n") end
    ec = 1; return false
  end
  local ok, err = fs.remove(rpath)
  if not ok then io.stderr:write(tostring(err) .. "\n") ec = 1 return false end
  return true
end

for _, path in ipairs(args) do
  path = path:gsub("/+$", "")
  if bRec then
    local segments = {}
    local prefix = ""
    for part in path:gmatch("[^/]+") do
      prefix = prefix .. part
      table.insert(segments, 1, prefix)
      prefix = prefix .. "/"
    end
    removeEmpty(table.unpack(segments))
  else
    removeEmpty(path)
  end
end
return ec