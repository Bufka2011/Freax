local fs = require("fs")
local shell = require("shell")

local args, opts = shell.parse(...)
if #args < 2 or opts.help then
  io.write("Usage: cp [-r] [-i] [-n] [-v] SRC... DST\n")
  return
end

local function prompt(src, dst)
  io.stderr:write("cp: overwrite '" .. dst .. "'? ")
  local resp = io.stdin:read("*l")
  return resp == "y" or resp == "yes"
end

local function copyRec(src, dst)
  local isDir = fs.isDirectory(src)
  if isDir == nil then return nil, "no such file" end
  if isDir then
    if not (opts.r or opts.R) then return nil, "omitting directory (use -r)" end
    if not fs.exists(dst) then fs.makeDirectory(dst) end
    local list = fs.list(src) or {}
    for _, n in ipairs(list) do
      local s = fs.concat(src, n:gsub("/$", ""))
      local d = fs.concat(dst, n:gsub("/$", ""))
      local ok, err = copyRec(s, d)
      if not ok then return nil, err end
    end
    return true
  else
    if fs.exists(dst) then
      if opts.n then return true end
      if opts.i and not prompt(src, dst) then return true end
    end
    if opts.v then io.write(src .. " -> " .. dst .. "\n") end
    return fs.copy(src, dst)
  end
end

local dstRaw = table.remove(args)
local dst = shell.resolve(dstRaw)
local dstIsDir = fs.isDirectory(dst)
local ec = 0

for _, sRaw in ipairs(args) do
  local src = shell.resolve(sRaw)
  if not fs.exists(src) then
    ec = 1; io.stderr:write("cp: " .. sRaw .. ": no such file\n")
  else
    local target = dst
    if dstIsDir then target = fs.concat(dst, fs.name(src) or sRaw) end
    local ok, err = copyRec(src, target)
    if not ok then ec = 1; io.stderr:write("cp: " .. sRaw .. ": " .. tostring(err) .. "\n") end
  end
end
return ec
