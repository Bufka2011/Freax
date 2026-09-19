local fs = require("fs")
local shell = require("shell")

local args, options = shell.parse(...)
if #args == 0 or options.help then
  io.write("Usage: rm [options] <file>...\n  -r  recursive\n  -f  force (no prompts, no errors on missing)\n  -i  prompt before each removal\n  -I  prompt once when removing more than 3 files\n  -v  verbose\n  -d  remove empty directories\n")
  return 1
end

local bRec = options.r or options.R
local bForce = options.f or options.force
local bVerbose = options.v or options.verbose
local bEmpty = options.d or options.dir
local promptLevel = (options.I and 3) or ((options.i or options.interactive) and 1) or 0
local ec = 0

promptLevel = bForce and 0 or promptLevel

local function confirm(msg)
  io.stderr:write(msg .. "? ")
  local r = io.stdin:read("*l")
  return r == "y" or r == "yes"
end

local function removeRec(path, rel)
  if not fs.exists(path) then
    if not bForce then io.stderr:write("rm: " .. rel .. ": no such file\n"); ec = 1 end
    return false
  end
  local isLink = fs.isLink(path)
  local isDir = not isLink and fs.isDirectory(path)
  if isDir then
    local list = fs.list(path) or {}
    if #list > 0 then
      if not bRec and not (bEmpty and #list == 0) then
        io.stderr:write("rm: " .. rel .. ": is a directory (use -r)\n"); ec = 1; return false
      end
      if bRec then
        if promptLevel == 1 and not confirm("rm: descend into directory '" .. rel .. "'") then return false end
        for _, n in ipairs(list) do
          removeRec(fs.concat(path, n:gsub("/$", "")), rel .. "/" .. n)
        end
      end
    end
  end
  if promptLevel == 1 then
    local label
    if isLink then
      label = "symbolic link"
    elseif isDir then
      label = "directory"
    else
      label = "regular file"
    end
    if not confirm("rm: remove " .. label .. " '" .. rel .. "'") then return false end
  end
  local ok, err = fs.remove(path)
  if ok then
    if bVerbose then io.write("removed '" .. rel .. "'\n") end
  else
    io.stderr:write("rm: " .. rel .. ": " .. tostring(err) .. "\n")
    ec = 1
  end
  return ok
end

if promptLevel == 3 and #args > 3 then
  if not confirm("rm: remove " .. #args .. " arguments") then return ec end
end

for _, a in ipairs(args) do removeRec(shell.resolve(a), a) end
return ec