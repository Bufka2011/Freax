local args, opts = require("shell").parse(...)
if #args < 1 then
  io.write("Usage: umount [-a] <mount>\n  -a  resolve by address prefix instead of path\n")
  return 1
end

local target = args[1]
local ok, err
if opts.a then
  ok, err = freax.fsUmount(target)
else
  for _, m in ipairs(freax.fsMounts()) do
    if m.path == target then
      ok, err = freax.fsUmount(m.addr)
      break
    end
  end
  if ok == nil then
    io.stderr:write("umount: " .. target .. ": not mounted\n"); return 1
  end
end
if not ok then io.stderr:write("umount: " .. tostring(err) .. "\n"); return 1 end