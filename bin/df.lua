local shell = require("shell")
local text = require("text")

local args, options = shell.parse(...)

local function formatSize(size)
  if not options.h then
    return tostring(size)
  elseif type(size) == "string" then
    return size
  end
  local sizes = {"", "K", "M", "G"}
  local unit = 1
  local power = options.si and 1000 or 1024
  while size > power and unit < #sizes do
    unit = unit + 1
    size = size / power
  end
  return math.floor(size * 10) / 10 .. sizes[unit]
end

local mounts = {}
if #args == 0 then
  for _, d in ipairs(freax.fsDevices()) do
    mounts[d.addr] = d
  end
else
  for _, a in ipairs(args) do
    local resolved = shell.resolve(a)
    local best, bestLen
    for _, d in ipairs(freax.fsDevices()) do
      local mnt = d.mount
      if mnt and resolved:sub(1, #mnt) == mnt then
        if not bestLen or #mnt > bestLen then
          best = d
          bestLen = #mnt
        end
      end
    end
    if best then
      mounts[best.addr] = best
    else
      io.stderr:write(a .. ": no such file or directory\n")
    end
  end
end

local result = {{"Filesystem", "Used", "Available", "Use%", "Mounted on"}}
for _, d in pairs(mounts) do
  local label = d.label or d.addr
  local total = d.total or 0
  local used = d.used or 0
  local available, percent
  if total == math.huge then
    used = used or "N/A"
    available = "unlimited"
    percent = "0%"
  else
    available = total - used
    percent = used / total
    if percent ~= percent then
      available = "N/A"
      percent = "N/A"
    else
      percent = math.ceil(percent * 100) .. "%"
    end
  end
  table.insert(result, {label, formatSize(used), formatSize(available), tostring(percent), d.mount or "-"})
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