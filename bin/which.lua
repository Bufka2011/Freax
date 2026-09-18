-- which: locate a command via PATH (M2).
local function out(s) io.write(tostring(s) .. "\n") end
local fs = require("fs")
local shell = require("shell")

local args, opts = shell.parse(...)
if #args == 0 or opts.help then
  out("Usage: which CMD...")
  return
end

for _, c in ipairs(args) do
  if shell.getAlias and shell.getAlias(c) then
    out(c .. ": aliased")
  else
    local PATH = os.getenv("PATH") or "/bin"
    local found
    for dir in PATH:gmatch("[^:]+") do
      for _, cand in ipairs({ dir .. "/" .. c .. ".lua", dir .. "/" .. c }) do
        if fs.exists(shell.resolve(cand)) then found = cand break end
      end
      if found then break end
    end
    if found then out(found)
    else out(c .. ": not found") end
  end
end
