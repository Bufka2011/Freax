-- dmesg: kernel log ring (pipe-clean).
local function out(s) io.write(tostring(s) .. "\n") end
for _, l in ipairs(freax.dmesg()) do out(l) end
