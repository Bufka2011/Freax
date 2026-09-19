local fs = require("fs")
local shell = require("shell")

local args, opts = shell.parse(...)
if #args < 2 or opts.help or opts.h then
  io.write([[Usage: cp [OPTION]... SRC... DST
  -i            prompt before overwrite
  -f            force; never prompt
  -n            do not overwrite an existing file
  -r            copy directories recursively
  -u            copy only when SOURCE differs from destination
  -P            preserve symbolic links
  -x            do not cross filesystem boundaries
  -v            verbose output
  --skip=PATH   skip the given (resolved) path
]])
  return
end

local bForce = opts.f or opts.force
local bNoClobber = opts.n or opts["no-clobber"]
local bRec = opts.r or opts.R or opts.recursive
local bUpdate = opts.u or opts.update
local bPreserve = opts.P
local bOneFS = opts.x
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

local function skipped(path)
  return skips[path] == true
end

local function prompt(src, dst)
  io.stderr:write("cp: overwrite '" .. dst .. "'? ")
  local resp = io.stdin:read("*l")
  return resp == "y" or resp == "yes"
end

local function mountOf(path)
  local best, bestLen
  for _, d in ipairs(fs.devices() or {}) do
    local m = d.mount
    if m and path:sub(1, #m) == m and (not bestLen or #m > bestLen) then
      best, bestLen = m, #m
    end
  end
  return best
end

local function sameFile(a, b)
  local f1 = fs.open(a, "r")
  if not f1 then return false end
  local f2 = fs.open(b, "r")
  if not f2 then fs.close(f1) return false end
  local same = true
  while true do
    local s1 = fs.read(f1, 4096)
    local s2 = fs.read(f2, 4096)
    if s1 ~= s2 then same = false break end
    if not s1 then break end
  end
  fs.close(f1)
  fs.close(f2)
  return same
end

local function copyRec(src, dst, top, srcMount)
  if skipped(shell.resolve(src)) then
    if bVerbose then io.write("skipping " .. src .. "\n") end
    return true
  end
  local isLink, linkTarget = fs.isLink(src)
  if isLink and bPreserve then
    if fs.exists(dst) then
      if bNoClobber then return true end
      fs.remove(dst)
    end
    if bVerbose then io.write(src .. " -> " .. dst .. "\n") end
    return fs.link(linkTarget, dst)
  end

  if fs.isDirectory(src) then
    if not bRec then return nil, "omitting directory (use -r)" end
    if bOneFS and not top and mountOf(src) ~= srcMount then return true end
    if not fs.exists(dst) then fs.makeDirectory(dst) end
    for _, n in ipairs(fs.list(src) or {}) do
      local name = n:gsub("/$", "")
      local ok, err = copyRec(fs.concat(src, name), fs.concat(dst, name), false, srcMount)
      if not ok then return nil, err end
    end
    return true
  end

  if fs.exists(dst) then
    if bNoClobber then return true end
    if bUpdate and not fs.isDirectory(dst) and sameFile(src, dst) then return true end
    if bPrompt and not prompt(src, dst) then return true end
  end
  if bVerbose then io.write(src .. " -> " .. dst .. "\n") end
  return fs.copy(src, dst)
end

local dstRaw = table.remove(args)
local dst = shell.resolve(dstRaw)
local dstIsDir = fs.isDirectory(dst)
local ec = 0

for _, sRaw in ipairs(args) do
  local src = shell.resolve(sRaw)
  if skipped(src) then
    if bVerbose then io.write("skipping " .. sRaw .. "\n") end
  elseif not fs.exists(src) and not fs.isLink(src) then
    ec = 1; io.stderr:write("cp: " .. sRaw .. ": no such file\n")
  else
    local target = dst
    if dstIsDir then target = fs.concat(dst, fs.name(src) or sRaw) end
    local ok, err = copyRec(src, target, true, mountOf(src))
    if not ok then ec = 1; io.stderr:write("cp: " .. sRaw .. ": " .. tostring(err) .. "\n") end
  end
end
return ec
