-- man: show manual pages (M2, ported from OpenOS).
-- Pages live under $MANPATH (default /usr/man), shown via $PAGER.
local fs = require("filesystem")
local shell = require("shell")

local args = shell.parse(...)
if #args == 0 then
  io.write("Usage: man <topic>\n")
  io.write("Where `topic` will usually be the name of a program or library.\n")
  return 1
end

local topic = args[1]
for path in string.gmatch(os.getenv("MANPATH") or "/usr/man", "[^:]+") do
  local full = fs.concat(shell.resolve(path), topic)
  if fs.exists(full) and not fs.isDirectory(full) then
    os.execute((os.getenv("PAGER") or "less") .. " " .. full)
    os.exit()
  end
end
io.stderr:write("No manual entry for " .. topic .. "\n")
return 1
