local s = math.floor(freax.uptime())
local d = math.floor(s / 86400)
s = s - d * 86400
local h = math.floor(s / 3600)
s = s - h * 3600
local m = math.floor(s / 60)
s = s % 60
if d > 0 then
  io.write(string.format("up %dd %02d:%02d:%02d\n", d, h, m, s))
else
  io.write(string.format("up %02d:%02d:%02d\n", h, m, s))
end
