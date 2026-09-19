local fs = require("fs")
local shell = require("shell")

local args, opts = shell.parse(...)
if #args < 2 or opts.help then
  io.write("Usage: mv [-i] [-n] [-v] SRC... DST\n")
  return
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

for _, sRaw in ipairs(args) do
  local src = shell.resolve(sRaw)
  if not fs.exists(src) then
    ec = 1; io.stderr:write("mv: " .. sRaw .. ": no such file\n")
  else
    local target = dst
    if dstIsDir then target = fs.concat(dst, fs.name(src) or sRaw) end
    if fs.exists(target) then
      if opts.n then return 0 end
      if opts.i and not prompt(src, target) then return 0 end
    end
    if opts.v then io.write(src .. " -> " .. target .. "\n") end
    local ok, err = os.rename(src, target)
    if not ok then ec = 1; io.stderr:write("mv: " .. sRaw .. ": " .. tostring(err) .. "\n") end
  end
end
return ec
