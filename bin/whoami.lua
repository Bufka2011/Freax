-- whoami: print the real user name from kernel credentials.
local auth = require("auth")
local entry = auth.getPasswdByUid(freax.getuid())
io.write((entry and entry.name or tostring(freax.getuid())) .. "\n")
