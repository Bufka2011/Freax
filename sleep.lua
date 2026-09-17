-- sleep: wait N seconds (fractional ok).
local function out(s) io.write(tostring(s) .. "\n") end
local n = tonumber((...) or "")
if not n then
  out("Usage: sleep SECONDS")
  return
end
os.sleep(n)
