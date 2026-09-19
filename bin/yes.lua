local args = table.pack(...)
local s = args[1] or "y"
local tty = io.stdout and io.stdout.tty
while true do
  local ok = io.write(tostring(s) .. "\n")
  if not ok then return end
  if tty then os.sleep(0.05) end
end