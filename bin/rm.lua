-- rm: remove files/dirs (M1, simplified).
-- Usage: rm [-r] FILE...
local function out(s) io.write(tostring(s) .. "\n") end
local fs = require("fs")
local shell = require("shell")

local args, opts = shell.parse(...)
if #args == 0 or opts.help then
  out("Usage: rm [-r] FILE...")
  return
end

local ec = 0

local function removeRec(path)
  local isDir = fs.isDirectory(path)
  if isDir then
    local list = fs.list(path) or {}
    if #list > 0 and not (opts.r or opts.R) then
      return nil, "is a directory (use -r)"
    end
    for _, n in ipairs(list) do
      local full = fs.concat(path, n:gsub("/$", ""))
      local ok, err = removeRec(full)
      if not ok then return nil, err end
    end
  end
  return fs.remove(path)
end

for _, a in ipairs(args) do
  local path = shell.resolve(a)
  if not fs.exists(path) then
    ec = 1
    out("rm: " .. a .. ": no such file")
  else
    local ok, err = removeRec(path)
    if not ok then ec = 1 out("rm: " .. a .. ": " .. tostring(err)) end
  end
end
return ec
