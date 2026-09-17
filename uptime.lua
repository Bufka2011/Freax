-- uptime: how long since boot (pipe-clean).
local function out(s) io.write(tostring(s) .. "\n") end
local s = math.floor(freax.uptime())
out(string.format("up %02d:%02d:%02d",
  math.floor(s / 3600), math.floor(s / 60) % 60, s % 60))
