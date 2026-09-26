-- reboot: reboot the computer (M1).
local ok, err = freax.reboot()
if not ok and err then io.stderr:write("reboot: " .. tostring(err) .. "\n") return 1 end
