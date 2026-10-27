local fs = filesystem or require("filesystem")
local shell = require("shell")

local args = shell.parse(...)
if #args == 0 then
  io.stderr:write("Usage: man <topic>\n")
  io.write("Where `topic` will usually be the name of a program or library.\n")
  return 1
end

local topic = args[1]
local function dumpPage(full)
  local fd, err = io.open(full, "r")
  if not fd then
    io.stderr:write("man: cannot read " .. tostring(err or full) .. "\n")
    return 1
  end
  while true do
    local chunk = fd:read(4096)
    if not chunk or #chunk == 0 then break end
    io.write(chunk)
  end
  fd:close()
  return 0
end

for path in string.gmatch(os.getenv("MANPATH") or "/usr/man", "[^:]+") do
  local full = fs.concat(shell.resolve(path), topic)
  if fs.exists(full) and not fs.isDirectory(full) then
    local pagerName = os.getenv("PAGER")
    if not pagerName or pagerName == "" then pagerName = "less" end
    local pagerPath = shell.resolve(pagerName, "lua")
    if pagerPath then
      local ok, _, code = os.execute(pagerName .. " " .. full)
      return code or (ok and 0 or 1)
    end
    -- pager not found: fall back to a plain dump
    return dumpPage(full)
  end
end
io.stderr:write("No manual entry for " .. topic .. "\n")
return 1
