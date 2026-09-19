-- time: time a command (M2). Usage: time CMD [ARGS...]
local shell = require("shell")
local args = table.pack(...)
if args.n == 0 then
  io.write("Usage: time CMD [ARGS...]\n")
  return
end
local computer = require("computer")
local t0, c0 = computer.uptime(), os.clock()
local cmd = table.concat(args, " ", 1, args.n)
local ok, ec = shell.execute(cmd)
local dt, dc = computer.uptime() - t0, os.clock() - c0
io.write(string.format("real %dm%.3fs cpu %dm%.3fs\n",
  math.floor(dt / 60), dt % 60, math.floor(dc / 60), dc % 60))
return ec or (ok and 0 or 1)
