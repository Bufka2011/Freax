local unicode = require("unicode")

local elbow = unicode.char(0x2514)

local cols = {"PID", "UID", "PARENT", "STATE", "FDS", "EVENTS", "CMD"}

-- collect a display row per live process
local rows, byPid = {}, {}
for _, p in ipairs(freax.ps()) do
local fdText = freax.fdCount(p.pid)
  local row = {
    PID = tostring(p.pid),
    UID = tostring(p.euid or p.uid or 0),
    PARENT = p.parent and tostring(p.parent) or "-",
    STATE = tostring(p.state or "?"),
    FDS = fdText and tostring(fdText) or "-",
    EVENTS = tostring(p.events or 0),
    CMD = p.name or "?",
    parent = p.parent,
  }
  rows[#rows + 1] = row
  byPid[p.pid] = row
end

-- tree order: roots first, children indented under their parent
local children, roots = {}, {}
for _, r in ipairs(rows) do
  local pid = tonumber(r.PID)
  if r.parent and byPid[r.parent] then
    children[r.parent] = children[r.parent] or {}
    children[r.parent][#children[r.parent] + 1] = pid
  else
    roots[#roots + 1] = pid
  end
end
table.sort(roots)
for _, list in pairs(children) do table.sort(list) end

local function make_elbow(depth)
  return (" "):rep(depth - 1) .. (depth > 0 and elbow or "")
end

local ordered, visited = {}, {}
local function walk(pid, depth)
  if visited[pid] then return end
  visited[pid] = true
  local row = byPid[pid]
  if not row then return end
  row.CMD = make_elbow(depth) .. row.CMD
  ordered[#ordered + 1] = row
  for _, child in ipairs(children[pid] or {}) do
    walk(child, depth + 1)
  end
end
for _, pid in ipairs(roots) do walk(pid, 0) end
-- cycles / orphans never reached from a root still need a row
for _, r in ipairs(rows) do walk(tonumber(r.PID), 0) end

local widths = {}
for _, c in ipairs(cols) do widths[c] = #c end
for _, row in ipairs(ordered) do
  for _, c in ipairs(cols) do
    widths[c] = math.max(widths[c], #row[c])
  end
end

local function pad(value, width)
  return value .. string.rep(" ", width - #value)
end

local header = {}
for _, c in ipairs(cols) do header[#header + 1] = pad(c, widths[c]) end
io.write(table.concat(header, "   ") .. "\n")

for _, row in ipairs(ordered) do
  local parts = {}
  for _, c in ipairs(cols) do parts[#parts + 1] = pad(row[c], widths[c]) end
  io.write(table.concat(parts, "   ") .. "\n")
end
