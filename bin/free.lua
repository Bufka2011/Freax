-- free: memory usage (M2).
local computer = require("computer")
local free, total = computer.freeMemory(), computer.totalMemory()
io.write(string.format("total %d free %d used %d\n", total, free, total - free))
