-- passwd: set passwords (M2). Usage: passwd [user]
-- No args = own password (asks current one unless unset).
-- root may set any account without knowing the old password.
local auth = require("auth")
local shell = require("shell")
local term = require("term")

local args = shell.parse(...)
local me = os.getenv("USER") or os.getenv("LOGNAME") or "root"
local target = args[1] or me

if not auth.getPasswd(target) then
  io.stderr:write("passwd: unknown user " .. target .. "\n")
  return 1
end

if target ~= me and me ~= "root" then
  io.stderr:write("passwd: only root may change other passwords\n")
  return 1
end

if target == me then
  local sh = auth.getShadow(me)
  if sh and not (sh.salt == "" and sh.hash == "") then
    term.write("Current password: ")
    local cur = term.read(nil, true, nil, "*") or ""
    if not auth.verify(me, cur) then
      io.stderr:write("passwd: incorrect password\n")
      return 1
    end
  end
end

term.write("New password: ")
local a = term.read(nil, true, nil, "*") or ""
term.write("Retype: ")
local b = term.read(nil, true, nil, "*") or ""
if a ~= b then
  io.stderr:write("passwd: mismatch\n")
  return 1
end
if a == "" then
  io.stderr:write("passwd: empty password not allowed here (use install default)\n")
  return 1
end

local salt = auth.genSalt()
local ok, err = auth.setShadow(target, salt, auth.hash(a, salt))
if not ok then
  io.stderr:write("passwd: " .. tostring(err) .. "\n")
  return 1
end
term.writeln("Password updated.")
return 0
