-- cp: copy files/dirs (M1, simplified OpenOS tools/transfer).
-- Usage: cp [-r] [-v] SRC... DST
local function out(s) io.write(tostring(s) .. "\n") end
local fs = require("fs")
local shell = require("shell")

local args, opts = shell.parse(...)
if #args < 2 or opts.help then
  out("Usage: cp [-r] [-v] SRC... DST")
  return
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
    if opts.v then out(src .. " -> " .. dst) end
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
    ec = 1
    out("cp: " .. sRaw .. ": no such file")
  else
    local target = dst
    if dstIsDir then
      target = fs.concat(dst, fs.name(src) or sRaw)
    end
    local ok, err = copyRec(src, target)
    if not ok then ec = 1 out("cp: " .. sRaw .. ": " .. tostring(err)) end
  end
end
return ec
