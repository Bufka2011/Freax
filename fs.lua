-- fs: Freax filesystem client lib (M1).
-- Thin wrapper over freax.* VFS syscalls.
-- Inspired by OpenOS lib/filesystem.lua, but the kernel owns mounts;
-- this lib only adds convenience (whole-file IO, path helpers).

local freax = freax

local fs = {}

function fs.cwd() return freax.getCwd() end
function fs.cd(path)
  local ok, err = freax.setCwd(path)
  if ok then return true end
  return nil, err
end

function fs.canonical(p) return freax.fsCanonical(p) end
function fs.concat(...) return freax.fsConcat(...) end
function fs.name(p) return freax.fsName(p) end
function fs.dir(p) return freax.fsDir(p) end
-- OpenOS compat aliases
fs.path = fs.dir
fs.canonical = fs.canonical

function fs.resolve(p)
  p = tostring(p or "")
  if p:sub(1, 1) == "/" then return freax.fsCanonical(p) end
  return freax.fsCanonical(freax.fsConcat(freax.getCwd(), p))
end

function fs.exists(p) return freax.fsExists(p) end
function fs.isDirectory(p)
  local r, err = freax.fsIsDir(p)
  return r, err
end
function fs.size(p) return freax.fsSize(p) end
function fs.list(p)
  local r, err = freax.fsList(p)
  return r, err
end
function fs.makeDirectory(p) return freax.fsMakeDir(p) end
function fs.remove(p) return freax.fsRemove(p) end
function fs.mounts() return freax.fsMounts() end
function fs.devices() return freax.fsDevices() end
function fs.mount(addr, path) return freax.fsMount(addr, path) end

function fs.open(path, mode) return freax.fsOpen(path, mode) end
function fs.read(fd, n) return freax.fsRead(fd, n) end
function fs.write(fd, d) return freax.fsWrite(fd, d) end
function fs.close(fd) return freax.fsClose(fd) end

function fs.readFile(path)
  local fd, err = fs.open(path, "r")
  if not fd then return nil, err end
  local parts = {}
  while true do
    local chunk = fs.read(fd, 4096)
    if not chunk then break end
    parts[#parts + 1] = chunk
  end
  fs.close(fd)
  return table.concat(parts)
end

function fs.writeFile(path, data)
  local fd, err = fs.open(path, "w")
  if not fd then return nil, err end
  local ok, werr = fs.write(fd, data)
  fs.close(fd)
  if not ok then return nil, werr end
  return true
end

function fs.copy(src, dst)
  local infd, err = fs.open(src, "r")
  if not infd then return nil, err end
  local outfd, err2 = fs.open(dst, "w")
  if not outfd then fs.close(infd) return nil, err2 end
  while true do
    local chunk = fs.read(infd, 4096)
    if not chunk then break end
    local ok, werr = fs.write(outfd, chunk)
    if not ok then fs.close(infd) fs.close(outfd) return nil, werr end
  end
  fs.close(infd) fs.close(outfd)
  return true
end

return fs
