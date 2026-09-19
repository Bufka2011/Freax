local shell = require("shell")
local text = require("text")
local args, options = shell.parse(...)

local function formatSize(size)
  if not options.h then
    return tostring(size)
  end
  local sizes = {"", "K", "M", "G"}
  local unit = 1
  while size > 1024 and unit < #sizes do
    unit = unit + 1
    size = size / 1024
  end
  return math.floor(size * 10) / 10 .. sizes[unit]
end

local mounts = {}
for _, d in ipairs(freax.fsDevices()) do
  mounts[d.addr] = d
end

local result = {{"Filesystem", "Used", "Available", "Use%", "Mounted on"}}
for _, d in pairs(mounts) do
  local label = d.label or d.addr
  local total = d.total or 0
  local used = d.used or 0
  local available, percent
  if total == math.huge then
    available = "unlimited"
    percent = "0%"
  else
    available = formatSize(total - used)
    percent = math.ceil(used / total * 100) .. "%"
  end
  table.insert(result, {label, formatSize(used), available, percent, d.mount or "-"})
end

local m = {}
for _, row in ipairs(result) do
  for col, value in ipairs(row) do
    m[col] = math.max(m[col] or 1, #tostring(value))
  end
end

for _, row in ipairs(result) do
  for col, value in ipairs(row) do
    local padding = col == #row and 0 or 2
    local str = tostring(value)
    io.write(str .. string.rep(" ", m[col] - #str + padding))
  end
  io.write("\n")
end