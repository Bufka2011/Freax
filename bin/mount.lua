local shell = require("shell")

local args, opts = shell.parse(...)

local function usage()
  io.stderr:write([==[
Usage: mount [OPTIONS] [device] [path]
  If no args are given, all current mount points are printed.
  <Options>
  -r, --ro    Mount the filesystem read only
  -h, --help  display this help and exit
  <Args>
  device      Specify filesystem device by label or address (can be abbreviated)
  path        Target folder path to mount to

See `man mount` for more details
]==])
end

local readonly = opts.r or opts.ro or opts.readonly
local help = opts.h or opts.help
opts.r, opts.ro, opts.readonly, opts.h, opts.help = nil, nil, nil, nil, nil

if help then
  usage()
  return 0
end
if next(opts) then
  io.stderr:write("mount: invalid option -- '" .. tostring(next(opts)) .. "'\n")
  return 1
end

if #args == 0 then
  local mounts = freax.fsMounts()
  table.sort(mounts, function(a, b)
    return (a.addr or "") < (b.addr or "")
  end)
  for _, m in ipairs(mounts) do
    local label, rw = "", (m.ro and "ro" or "rw")
    for _, d in ipairs(freax.fsDevices()) do
      if d.addr == m.addr then
        label = d.label or ""
        if not m.ro then rw = d.readonly and "ro" or "rw" end
        break
      end
    end
    local addr = m.addr and m.addr:sub(1, 8) or "?"
    io.write(string.format("%s on %s (%s) %s\n", addr, m.path, rw, label))
  end
  return 0
end

if #args ~= 2 then
  io.stderr:write("mount: wrong number of arguments\n")
  usage()
  return 1
end

local dev, path = args[1], shell.resolve(args[2])
local addr
for _, d in ipairs(freax.fsDevices()) do
  if (d.label or "") == dev or d.addr:sub(1, #dev) == dev then
    addr = d.addr
    break
  end
end
if not addr then
  io.stderr:write("mount: no such device '" .. dev .. "'\n")
  return 1
end
if freax.fsExists(path) and not freax.fsIsDir(path) then
  io.stderr:write("mount: " .. path .. ": not a directory\n")
  return 1
end
if not freax.fsExists(path) then freax.fsMakeDir(path) end
local ok, err = freax.fsMount(addr, path, readonly)
if not ok then
  io.stderr:write("mount: " .. tostring(err) .. "\n")
  return 1
end
return 0
