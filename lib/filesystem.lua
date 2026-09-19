-- filesystem: OpenOS-compatible API over the Freax kernel VFS (M2 compat).
-- Mounts, fds and permission checks live in the kernel; this maps names.
-- Not supported: bind mounts (options.bind); umount is kernel-side.
-- Symlinks are virtual (RAM-only, lost on reboot), like OpenOS.

local fs = require("fs")

local filesystem = {}

local function segments(path)
  local parts = {}
  for part in tostring(path):gmatch("[^/\\]+") do
    if part == "." or part == "" then
      -- skip
    elseif part == ".." then
      if #parts > 0 then table.remove(parts) end
    else
      parts[#parts + 1] = part
    end
  end
  return parts
end

function filesystem.canonical(path)
  local abs = tostring(path):sub(1, 1) == "/"
  local res = table.concat(segments(path), "/")
  return abs and ("/" .. res) or res
end

function filesystem.concat(...)
  local pieces = {}
  for i = 1, select("#", ...) do pieces[#pieces + 1] = tostring(select(i, ...)) end
  return filesystem.canonical(table.concat(pieces, "/"))
end

function filesystem.path(path)
  local parts = segments(path)
  table.remove(parts)
  local res = table.concat(parts, "/") .. "/"
  if tostring(path):sub(1, 1) == "/" and res:sub(1, 1) ~= "/" then
    return "/" .. res
  end
  return res
end

function filesystem.name(path)
  local parts = segments(path)
  return parts[#parts]
end

-- path expressed relative to base (defaults to the path's own directory).
function filesystem.relative(path, base)
  local p = segments(filesystem.canonical(path))
  local b = segments(filesystem.canonical(base or filesystem.path(path)))
  local i = 1
  while p[i] and b[i] and p[i] == b[i] do i = i + 1 end
  local out = {}
  for _ = i, #b do out[#out + 1] = ".." end
  for j = i, #p do out[#out + 1] = p[j] end
  return table.concat(out, "/")
end

filesystem.segments = segments

-- fake proxy: address + space/label info from the kernel device list.
local function fakeFor(absPath)
  absPath = filesystem.canonical(absPath)
  local best, bestAddr
  for _, m in ipairs(fs.mounts()) do
    local mp = m.path
    local hit = (mp == "/") or absPath == mp
      or absPath:sub(1, #mp + 1) == mp .. "/"
    if hit and (not best or #mp > #best) then
      best, bestAddr = mp, m.addr
    end
  end
  if not best then return nil end
  local info = {}
  for _, d in ipairs(fs.devices()) do
    if d.addr == bestAddr then info = d break end
  end
  local mnt
  for _, m in ipairs(fs.mounts()) do if m.path == best then mnt = m break end end
  return {
    address = bestAddr,
    isReadOnly = function() return (mnt and mnt.ro) or not not info.readonly end,
    spaceTotal = function() return info.total or 0 end,
    spaceUsed = function() return info.used or 0 end,
    getLabel = function() return info.label or "" end,
    setLabel = function() return nil, "denied" end,
    lastModified = function(rel)
      return filesystem.lastModified(filesystem.concat(best, rel or ""))
    end,
  }, best
end

function filesystem.get(path)
  local proxy, mount = fakeFor(fs.resolve(path))
  if proxy then return proxy, mount end
  return nil, "no such file system"
end

function filesystem.mounts()
  local acc = {}
  for _, m in ipairs(fs.mounts()) do
    local proxy = fakeFor(m.path)
    acc[#acc + 1] = { proxy, m.path }
  end
  local i = 0
  return function()
    i = i + 1
    if acc[i] then return acc[i][1], acc[i][2] end
  end
end

function filesystem.mount(dev, path)
  local addr = type(dev) == "table" and dev.address or dev
  return fs.mount(addr, path)
end

function filesystem.umount()
  return nil, "unmount unsupported under Freax M1"
end

function filesystem.proxy(filter, options)
  if options and next(options) then
    return nil, "mount options unsupported"
  end
  for _, d in ipairs(fs.devices()) do
    if d.addr:sub(1, #filter) == filter or (d.label or "") == filter then
      return fakeFor(d.mount or "/")
    end
  end
  return nil, "no such file system"
end

function filesystem.exists(path) return fs.exists(path) end

function filesystem.isDirectory(path)
  local r, err = fs.isDirectory(path)
  return r, err
end

function filesystem.isLink(path)
  local r, target = fs.isLink(path)
  if r then return true, target end
  return false
end

function filesystem.link(target, linkpath)
  return fs.link(target, linkpath)
end

function filesystem.size(path) return fs.size(path) end

function filesystem.lastModified(path)
  if freax.fsLastModified then return freax.fsLastModified(path) end
  return 0
end

function filesystem.isReadOnly(path)
  if freax.fsIsReadOnly then return freax.fsIsReadOnly(path) end
  local proxy = filesystem.get(path)
  return proxy and proxy.isReadOnly() or false
end

function filesystem.list(path)
  local l = fs.list(path) or {}
  local i = 0
  return function()
    i = i + 1
    return l[i]
  end
end

function filesystem.open(path, mode)
  return io.open(path, mode)
end

function filesystem.makeDirectory(path) return fs.makeDirectory(path) end
function filesystem.remove(path) return fs.remove(path) end
function filesystem.rename(a, b) return os.rename(a, b) end
function filesystem.copy(a, b) return fs.copy(a, b) end

function filesystem.realPath(path)
  if freax.fsRealPath then
    local r, err = freax.fsRealPath(path)
    if r then return r end
    return nil, err
  end
  return filesystem.canonical(fs.resolve(path))
end

function filesystem.isAutorunEnabled() return false end
function filesystem.setAutorunEnabled() return true end

return filesystem
