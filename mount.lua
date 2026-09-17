-- mount: list mounts (pipe-clean).
local function out(s) io.write(tostring(s) .. "\n") end
for _, m in ipairs(freax.fsMounts()) do
  out((m.addr and m.addr:sub(1, 8) or "?") .. " on " .. m.path)
end
