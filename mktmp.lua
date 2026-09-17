-- mktmp: create and print a temp file name (M2).
local name = os.tmpname()
if not name then
  io.stderr:write("mktmp: no tmp space\n")
  return
end
local f, err = io.open(name, "w")
if not f then
  io.stderr:write("mktmp: " .. tostring(err) .. "\n")
  return
end
f:close()
io.write(name .. "\n")
