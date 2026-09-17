-- passwd: set the root password (M2).
-- Asks for the current password first when one exists.
local term = require("term")
local shadow = require("shadow")

if shadow.hasPassword("root") then
  term.write("Current password: ")
  local cur = term.readSecret()
  if not shadow.verify("root", cur or "") then
    term.writeln("Wrong password.")
    return 1
  end
end

while true do
  term.write("New password: ")
  local a = term.readSecret()
  term.write("Retype password: ")
  local b = term.readSecret()
  if a ~= b then
    term.writeln("Passwords do not match, try again.")
  else
    shadow.set("root", a)
    term.writeln("Password updated.")
    return 0
  end
end
