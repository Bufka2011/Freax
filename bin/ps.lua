local process = require("process")

local data, widths = {}, {}

local function add_field(key, value)
  if not data[key] then data[key] = {} end
  table.insert(data[key], value)
  widths[key] = math.max(widths[key] or 0, #value)
end

local cols = {
  {"PID", function(_, p) return tostring(p.pid) end},
  {"EVENTS", function(_, p)
    local handlers = rawget(p.data, "handlers") or {}
    local count = 0
    for _ in pairs(handlers) do
      count = count + 1
    end
    return count == 0 and "-" or tostring(count)
  end},
  {"THREADS", function(_, p)
    local count = 0
    for _, h in ipairs(p.data.handles) do
      local mt = getmetatable(h)
      if mt and mt.__status then
        count = count + 1
      end
    end
    return count == 0 and "-" or tostring(count)
  end},
  {"HANDLES", function(_, p)
    local count = #p.data.handles
    return count == 0 and "-" or tostring(count)
  end},
  {"CMD", function(_, p) return p.command or "?" end},
}

for _, col in ipairs(cols) do add_field(col[1], col[1]) end

for _, proc in ipairs(freax.ps()) do
  local pi = process.info(proc.pid) or {pid = proc.pid, command = proc.name, data = {handles = {}}}
  for _, col in ipairs(cols) do
    add_field(col[1], col[2](nil, pi))
  end
end

local indexed = {}
for i = 1, #data.PID do indexed[i] = i end
table.sort(indexed, function(a, b) return tonumber(data.PID[a]) < tonumber(data.PID[b]) end)

local header = {}
for _, col in ipairs(cols) do
  header[#header + 1] = col[1] .. string.rep(" ", widths[col[1]] - #col[1])
end
io.write(table.concat(header, "   ") .. "\n")

for _, idx in ipairs(indexed) do
  local parts = {}
  for _, col in ipairs(cols) do
    parts[#parts + 1] = data[col[1]][idx] .. string.rep(" ", widths[col[1]] - #data[col[1]][idx])
  end
  io.write(table.concat(parts, "   ") .. "\n")
end