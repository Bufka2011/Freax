local args, opts = require("shell").parse(...)
if opts.help then
  io.write("Usage: ps\n  Lists running processes with PID, name, status\n")
  return
end

for _, p in ipairs(freax.ps()) do
  local status = p.dead and "dead" or "alive"
  local name = p.name or "?"
  io.write(string.format("%-6d %s  %s\n", p.pid, status, name))
end