local fs = require("fs")
local shell = require("shell")

local args, opts = shell.parse(...)
if #args < 2 or opts.help or opts.h then
  io.write([[Usage: mv [OPTION]... SRC... DST
  -f            force; overwrite without prompting
  -i            prompt before overwriting (unless -f)
  -n            do not overwrite an existing file
  -v            verbose output
  --skip=PATH   skip the given (resolved) path
]])
  return
end

local bForce = opts.f or opts.force
local bNoClobber = opts.n or opts["no-clobber"]
local bVerbose = opts.v or opts.verbose
local bPrompt = (opts.i or opts.interactive) and not bForce

local skips = {}
do
  local raw = opts.skip
  if type(raw) == "table" then
    for _, s in ipairs(raw) do skips[shell.resolve(s)] = true end
  elseif type(raw) == "string" then
    skips[shell.resolve(raw)] = true
  end
end

local function prompt(src, dst)
  io.stderr:write("mv: overwrite '" .. dst .. "'? ")
  local resp = io.stdin:read("*l")
  return resp == "y" or resp == "yes"
end

local dstRaw = table.remove(args)
local dst = shell.resolve(dstRaw)
local dstIsDir = fs.isDirectory(dst)
local ec = 0

local function moveOne(sRaw)
  local src = shell.resolve(sRaw)
  if skips[src] then
    if bVerbose then io.write("skipping " .. sRaw .. "\n") end
    return true
  end
  if not fs.exists(src) and not fs.isLink(src) then
    io.stderr:write("mv: " .. sRaw .. ": no such file\n")
    return false
  end
  local target = dst
  if dstIsDir then target = fs.concat(dst, fs.name(src) or sRaw) end
  if fs.exists(target) then
    if bNoClobber then return true end
    if bPrompt and not prompt(src, target) then return true end
  end
  if bVerbose then io.write(src .. " -> " .. target .. "\n") end
  local ok, err = os.rename(src, target)
  if not ok then
    io.stderr:write("mv: " .. sRaw .. ": " .. tostring(err) .. "\n")
    return false
  end
  return true
end

for _, sRaw in ipairs(args) do
  if not moveOne(sRaw) then ec = 1 end
end
return ec
