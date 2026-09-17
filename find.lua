-- find: walk directories printing matches (M2).
-- Usage: find [DIR] [-name PATTERN] (Lua pattern on the file name)
local fs = require("fs")
local shell = require("shell")

local args, opts = shell.parse(...)
local root = shell.resolve(args[1] or ".")
local pat = opts.name or opts["name"]

local function walk(path, show)
  if show then io.write(path .. "\n") end
  if fs.isDirectory(path) then
    for _, n in ipairs(fs.list(path) or {}) do
      local full = fs.concat(path, n:gsub("/$", ""))
      walk(full, not pat or (fs.name(full) or ""):find(pat))
    end
  end
end

if not fs.exists(root) then
  io.stderr:write("find: " .. tostring(args[1] or ".") .. ": no such file\n")
  return
end
walk(root, true)
