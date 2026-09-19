-- which: locate a command via PATH (M2).
local function out(s) io.write(tostring(s) .. "\n") end
local shell = require("shell")

local args, opts = shell.parse(...)
if #args == 0 or opts.help then
  out("Usage: which CMD...")
  return 255
end

local ec = 0
for _, c in ipairs(args) do
  local alias = shell.getAlias(c)
  if alias then
    out(c .. ": aliased to " .. alias)
  else
    local result, reason = shell.resolve(c, "lua")
    if result then
      out(result)
    else
      io.stderr:write(c .. ": " .. tostring(reason) .. "\n")
      ec = 1
    end
  end
end
return ec
