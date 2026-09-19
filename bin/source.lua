-- source: run a file of shell commands (OpenOS port).
-- A child process cannot mutate its parent's env/aliases, so the
-- in-shell `source` builtin (bin/sh.lua) remains the way to propagate
-- changes; this standalone form executes each line via os.execute.
local shell = require("shell")

local args, options = shell.parse(...)

if #args ~= 1 then
  io.stderr:write("specify a single file to source\n");
  return 1
end

local file, open_reason = io.open(args[1], "r")

if not file then
  if not options.q then
    io.stderr:write(string.format("could not source %s because: %s\n", args[1], open_reason));
  end
  return 1
end

local code = 0
for line in file:lines() do
  if line:match("%S") and not line:match("^%s*#") then
    code = shell.execute(line) and 0 or 1
  end
end

file:close()
return code
