-- umount: detach a filesystem (M2). Usage: umount PATH|ADDR
local args = table.pack(...)
if args.n == 0 then
  io.write("Usage: umount PATH|ADDR\n")
  return
end
local ok, err = freax.fsUmount(tostring(args[1]))
if not ok then io.stderr:write("umount: " .. tostring(err) .. "\n") end
