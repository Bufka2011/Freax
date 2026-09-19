local args = table.pack(...)

if args[1] == "--help" then
  io.write("Usage: yes [STRING]...\n")
  return
end
if args[1] == "--version" then
  io.write("yes (Freax) 1.0\n")
  return
end

local s = #args > 0 and table.concat(args, " ") or "y"
local tty = io.stdout and io.stdout.tty
while true do
  local ok = io.write(tostring(s) .. "\n")
  if not ok then return end
  if tty then os.sleep(0.05) end
end