-- df: disk free (pipe-clean).
local function out(s) io.write(tostring(s) .. "\n") end
out("ADDR      LABEL       TOTAL  USED  MOUNT")
for _, d in ipairs(freax.fsDevices()) do
  out(string.format("%s %s %d %d %s%s",
    d.addr:sub(1, 8), tostring(d.label or ""):sub(1, 11),
    d.total or 0, d.used or 0, tostring(d.mount or "-"),
    d.boot and " (boot)" or ""))
end
