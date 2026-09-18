-- mv: move/rename files (M2, uses kernel rename, cross-fs falls back).
local function out(s) io.write(tostring(s) .. "\n") end
local fs = require("fs")
local shell = require("shell")

local args, opts = shell.parse(...)
if #args < 2 or opts.help then
  out("Usage: mv [-v] SRC... DST")
  return
end

local dstRaw = table.remove(args)
local dst = shell.resolve(dstRaw)
local dstIsDir = fs.isDirectory(dst)
local ec = 0

for _, sRaw in ipairs(args) do
  local src = shell.resolve(sRaw)
  if not fs.exists(src) then
    ec = 1
    out("mv: " .. sRaw .. ": no such file")
  else
    local target = dst
    if dstIsDir then target = fs.concat(dst, fs.name(src) or sRaw) end
    if opts.v then out(src .. " -> " .. target) end
    local ok, err = os.rename(src, target)
    if not ok then ec = 1 out("mv: " .. sRaw .. ": " .. tostring(err)) end
  end
end
return ec
