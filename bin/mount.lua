local shell = require("shell")
local args, opts = shell.parse(...)

if #args == 0 then
  for _, m in ipairs(freax.fsMounts()) do
    local label, rw = "", "rw"
    for _, d in ipairs(freax.fsDevices()) do
      if d.addr == m.addr then label = d.label or ""; rw = d.readonly and "ro" or "rw"; break end
    end
    local addr = m.addr and m.addr:sub(1, 8) or "?"
    io.write(string.format("%s on %s (%s) %s\n", addr, m.path, rw, label))
  end
  return
end

if #args ~= 2 then
  io.stderr:write("Usage: mount [device] [path]\n")
  return 1
end

local dev, path = args[1], shell.resolve(args[2])
local addr
for _, d in ipairs(freax.fsDevices()) do
  if d.addr:sub(1, #dev) == dev or (d.label or "") == dev then
    addr = d.addr; break
  end
end
if not addr then io.stderr:write("mount: no such device\n"); return 1 end
if freax.fsExists(path) and not freax.fsIsDir(path) then
  io.stderr:write("mount: " .. path .. ": not a directory\n"); return 1
end
if not freax.fsExists(path) then freax.fsMakeDir(path) end
local ok, err = freax.fsMount(addr, path)
if not ok then io.stderr:write("mount: " .. tostring(err) .. "\n"); return 1 end