local fs = require("fs")
local shell = require("shell")

local args, opts = shell.parse(...)
if opts.help then
  io.write("Usage: tree [OPTION]... [DIR]...\n  -a  show hidden files\n  -h  human-readable sizes\n  -p  append / to dirs\n  -Q  quote names\n  --level=N  max depth\n")
  return
end

local roots = #args > 0 and args or {"."}
local showAll = opts.a
local human = opts.h or opts["human-readable"]
local slash = opts.p
local quote = opts.Q or opts.quote
local maxLevel = tonumber(opts.level) or math.huge
local dirCount, fileCount = 0, 0

local function fmtSize(sz)
  if not human then return tostring(sz) end
  local units = {"", "K", "M", "G"}
  local u = 1
  while sz > 1024 and u < #units do u = u + 1 sz = sz / 1024 end
  return math.floor(sz * 10) / 10 .. units[u]
end

local function show(path, prefix, level)
  if level > maxLevel then return end
  local entries = fs.list(path) or {}
  local items = {}
  for _, n in ipairs(entries) do
    if showAll or n:sub(1, 1) ~= "." then
      local full = fs.concat(path, n:gsub("/$", ""))
      items[#items + 1] = {name = n, isDir = fs.isDirectory(full), full = full}
    end
  end
  table.sort(items, function(a, b) return a.name:lower() < b.name:lower() end)
  for i, item in ipairs(items) do
    local last = i == #items
    local line = prefix .. (last and "└── " or "├── ")
    if quote then line = line .. '"' end
    line = line .. item.name
    if quote then line = line .. '"' end
    if slash and item.isDir then line = line .. "/" end
    io.write(line .. "\n")
    if item.isDir then
      dirCount = dirCount + 1
      show(item.full, prefix .. (last and "    " or "│   "), level + 1)
    else
      fileCount = fileCount + 1
    end
  end
end

for _, r in ipairs(roots) do
  local path = shell.resolve(r)
  io.write(r .. "\n")
  if not fs.exists(path) then
    io.stderr:write("tree: " .. r .. ": no such file\n")
  else
    if fs.isDirectory(path) then dirCount = dirCount + 1 end
    show(path, "", 1)
  end
end
io.write("\n" .. dirCount .. " director" .. (dirCount == 1 and "y" or "ies") .. ", " .. fileCount .. " file" .. (fileCount == 1 and "" or "s") .. "\n")