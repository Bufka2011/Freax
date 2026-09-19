local ps = require("process")
local args, opts = require("shell").parse(...)
if opts.help then
  io.write("Usage: ps\n  PID    EVENTS  THREADS  HANDLES  CMD\n")
  return
end

local data, widths, sorted = {}, {}, {}
local cols = {
  {"PID", function(_, p) return tostring(p.pid) end},
  {"EVENTS", function(_, p)
    local n = 0
    if p.data and p.data.handles then
      for _ in pairs(p.data.handles) do n = n + 1 end
    end
    return n == 0 and "-" or tostring(n)
  end},
  {"THREADS", function(_, p)
    local n = 0
    if p.data and p.data.handles then
      for _, h in ipairs(p.data.handles) do
        local mt = getmetatable(h)
        if mt and mt.__status then n = n + 1 end
      end
    end
    return n == 0 and "-" or tostring(n)
  end},
  {"HANDLES", function(_, p)
    local n = p.data and #p.data.handles or 0
    return n == 0 and "-" or tostring(n)
  end},
  {"CMD", function(_, p) return p.command or "?" end},
}

for _, col in ipairs(cols) do
  data[col[1]] = {}; widths[col[1]] = #col[1]
end

for _, p in ipairs(freax.ps()) do
  local pi = ps.info(p.pid) or {pid = p.pid, command = p.name, data = {}}
  local row = {}
  for _, col in ipairs(cols) do
    local val = col[2](nil, pi)
    row[col[1]] = val
    widths[col[1]] = math.max(widths[col[1]], #val)
  end
  sorted[#sorted + 1] = row
end

table.sort(sorted, function(a, b) return tonumber(a.PID, 10) < tonumber(b.PID, 10) end)

local header = {}
for _, col in ipairs(cols) do
  local w = widths[col[1]]
  header[#header + 1] = col[1] .. string.rep(" ", w - #col[1])
end
io.write(table.concat(header, "   ") .. "\n")

for _, row in ipairs(sorted) do
  local parts = {}
  for _, col in ipairs(cols) do
    parts[#parts + 1] = row[col[1]] .. string.rep(" ", widths[col[1]] - #row[col[1]])
  end
  io.write(table.concat(parts, "   ") .. "\n")
end