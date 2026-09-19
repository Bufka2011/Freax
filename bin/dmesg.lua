local args, opts = require("shell").parse(...)
local mode = opts.f or opts.follow

if next(opts) and not mode then
  io.c:write("Usage: dmesg [-f]\n  -f  follow mode (live events, Ctrl+C to exit)\n")
  return 1
end

if mode == "follow" or mode then
  for _, l in ipairs(freax.dmesg()) do io.write(l .. "\n") end
  io.write("-- following new events (Ctrl+C to exit) --\n")
  while true do
    local sig = table.pack(freax.pullEvent())
    if sig[1] == "interrupted" then break end
    if sig[1] == "klog" then
      io.write(sig[2] .. "\n")
    end
  end
else
  for _, l in ipairs(freax.dmesg()) do io.write(l .. "\n") end
end