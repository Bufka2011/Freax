-- shutdown: power off the computer (M1).
local ok, err = freax.shutdown()
if not ok and err then io.stderr:write("shutdown: " .. tostring(err) .. "\n") return 1 end
