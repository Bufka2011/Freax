-- dpkg: Freax installed-package database and package operations.
-- Owns /var/lib/dpkg: the RFC822 status DB, the per-package info files
-- (.list/.sha256sums/.conffiles + Lua maintainer scripts), and the
-- unpack/configure/remove lifecycle. No dependency resolution here.

local fs = require("fs")
local fpkg = require("fpkg")
local sha256 = require("sha256")

local dpkg = {}

dpkg.statusPath = "/var/lib/dpkg/status"
dpkg.infoDir = "/var/lib/dpkg/info"
dpkg.lockPath = "/var/lib/dpkg/lock"

function dpkg.arch() return "all" end

local SCRIPT_NAMES = { "preinst", "postinst", "prerm", "postrm" }

local CANON = {
  "Package", "Status", "Priority", "Section", "Installed-Size",
  "Maintainer", "Architecture", "Version", "Depends", "Pre-Depends",
  "Recommends", "Suggests", "Conflicts", "Breaks", "Replaces",
  "Provides", "Essential", "Homepage", "Description",
}

---------------------------------------------------------------
-- Lock
---------------------------------------------------------------

local lockDepth = 0

local function pidLive(pid)
  if not (freax and freax.ps) then return false end
  local ok, list = pcall(freax.ps)
  if not ok or type(list) ~= "table" then return false end
  for _, p in ipairs(list) do
    if p.pid == pid and not p.dead then return true end
  end
  return false
end

local function acquireLock()
  if lockDepth > 0 then
    lockDepth = lockDepth + 1
    return true
  end
  fpkg.ensureDir("/var/lib/dpkg")
  if fs.exists(dpkg.lockPath) then
    local text = fs.readFile(dpkg.lockPath) or ""
    local pid = tonumber(text:match("%d+"))
    if pid and pidLive(pid) then
      return nil, "dpkg: lock held by process " .. pid
    end
    fs.remove(dpkg.lockPath)
  end
  local fd, err = fs.open(dpkg.lockPath, "w")
  if not fd then return nil, err or "cannot create lock" end
  local pid = (freax and freax.getpid and freax.getpid()) or 0
  fs.write(fd, tostring(pid) .. "\n")
  fs.close(fd)
  lockDepth = 1
  return true
end

local function releaseLock()
  if lockDepth > 1 then
    lockDepth = lockDepth - 1
    return true
  end
  if lockDepth == 1 then
    lockDepth = 0
    fs.remove(dpkg.lockPath)
  end
  return true
end

---------------------------------------------------------------
-- Database
---------------------------------------------------------------

local function canonicalOrder(fields)
  local order, seen = {}, {}
  for _, k in ipairs(CANON) do
    if fields[k] ~= nil then
      order[#order + 1] = k
      seen[k] = true
    end
  end
  local extra = {}
  for k in pairs(fields) do
    if type(k) == "string" and not seen[k] then extra[#extra + 1] = k end
  end
  table.sort(extra)
  for _, k in ipairs(extra) do order[#order + 1] = k end
  return order
end

function dpkg.loadStatus()
  local db = { order = {}, byName = {} }
  if not fs.exists(dpkg.statusPath) then return db end
  local text = fs.readFile(dpkg.statusPath)
  if not text then return db end
  for _, stanza in ipairs(fpkg.parseStanzas(text)) do
    local name = stanza.fields.Package
    if name then
      if not db.byName[name] then db.order[#db.order + 1] = name end
      db.byName[name] = stanza.fields
    end
  end
  return db
end

function dpkg.saveStatus(db)
  fpkg.ensureDir("/var/lib/dpkg")
  local parts = {}
  for _, name in ipairs(db.order) do
    local fields = db.byName[name]
    if fields then
      parts[#parts + 1] = fpkg.serializeControl(fields, canonicalOrder(fields))
    end
  end
  local text = table.concat(parts, "\n")
  local tmp = dpkg.statusPath .. ".dpkg-new"
  local ok, err = fs.writeFile(tmp, text)
  if not ok then return nil, err end
  local backup = dpkg.statusPath .. ".dpkg-old"
  if fs.exists(backup) or fs.isLink(backup) then
    fs.remove(tmp)
    return nil, "status backup already exists: " .. backup
  end
  local hadOld = fs.exists(dpkg.statusPath)
  if hadOld then
    local bok, berr = fs.rename(dpkg.statusPath, backup)
    if not bok then fs.remove(tmp) return nil, berr end
  end
  local rok, rerr = fs.rename(tmp, dpkg.statusPath)
  if not rok then
    fs.remove(tmp)
    if hadOld then fs.rename(backup, dpkg.statusPath) end
    return nil, rerr
  end
  if hadOld then fs.remove(backup) end
  return true
end

function dpkg.getStanza(name)
  local db = dpkg.loadStatus()
  return db.byName[name]
end

function dpkg.list()
  local db = dpkg.loadStatus()
  local out = {}
  for _, name in ipairs(db.order) do
    if db.byName[name] then out[#out + 1] = db.byName[name] end
  end
  table.sort(out, function(a, b)
    return tostring(a.Package) < tostring(b.Package)
  end)
  return out
end

function dpkg.pkgStatus(name)
  local fields = dpkg.getStanza(name)
  if not fields or not fields.Status then return "not-installed" end
  local status = fields.Status:match("%S+%s+%S+%s+(%S+)")
  return status or "not-installed"
end

function dpkg.meta(name) return dpkg.getStanza(name) end

function dpkg.isInstalled(name)
  return dpkg.pkgStatus(name) == "installed"
end

function dpkg.readControl(path) return fpkg.readControl(path) end

---------------------------------------------------------------
-- Info files
---------------------------------------------------------------

local function readSums(name)
  local out = {}
  local text = fs.readFile(dpkg.infoDir .. "/" .. name .. ".sha256sums")
  if text then
    for line in (text .. "\n"):gmatch("(.-)\n") do
      local hex, path = line:match("^(%x+)%s+(.*)$")
      if hex and path then out[path] = hex end
    end
  end
  return out
end

local function writeInfo(name, list, sums, conff, scripts)
  local ok, err = fpkg.ensureDir(dpkg.infoDir)
  if not ok then return nil, err end
  local base = dpkg.infoDir .. "/" .. name
  local function writeArray(path, arr)
    if arr and #arr > 0 then
      local wok, werr = fs.writeFile(path, table.concat(arr, "\n") .. "\n")
      if not wok then return nil, werr end
    else
      fs.remove(path)
    end
    return true
  end
  local aok, aerr = writeArray(base .. ".list", list)
  if not aok then return nil, aerr end
  aok, aerr = writeArray(base .. ".sha256sums", sums)
  if not aok then return nil, aerr end
  aok, aerr = writeArray(base .. ".conffiles", conff)
  if not aok then return nil, aerr end
  for _, script in ipairs(SCRIPT_NAMES) do
    local src = scripts and scripts[script]
    if src then
      local wok, werr = fs.writeFile(base .. "." .. script, src)
      if not wok then return nil, werr end
    else
      fs.remove(base .. "." .. script)
    end
  end
  return true
end

local function removeInfo(name)
  local base = dpkg.infoDir .. "/" .. name
  fs.remove(base .. ".list")
  fs.remove(base .. ".sha256sums")
  fs.remove(base .. ".conffiles")
  for _, script in ipairs(SCRIPT_NAMES) do fs.remove(base .. "." .. script) end
  return true
end

local function deleteStanza(name)
  local db = dpkg.loadStatus()
  if not db.byName[name] then return true end
  db.byName[name] = nil
  for i, n in ipairs(db.order) do
    if n == name then table.remove(db.order, i) break end
  end
  return dpkg.saveStatus(db)
end

---------------------------------------------------------------
-- Maintainer scripts
---------------------------------------------------------------

local function scriptEnv(action, oldver)
  local env = {
    arg = { action, oldver },
    io = io, os = os, print = print,
    string = string, table = table, math = math, bit32 = bit32,
    coroutine = coroutine,
    pairs = pairs, ipairs = ipairs, next = next, select = select,
    tostring = tostring, tonumber = tonumber, type = type,
    pcall = pcall, xpcall = xpcall, error = error, assert = assert,
    setmetatable = setmetatable, getmetatable = getmetatable,
    rawget = rawget, rawset = rawset,
    require = require,
  }
  if freax then env.freax = freax end
  env.fs = require("fs")
  return env
end

local function runSource(source, label, action, oldver)
  if not source or source == "" then return true end
  local fn, err = load(source, label, "t", scriptEnv(action, oldver))
  if not fn then return nil, err end
  local ok, reason = pcall(fn)
  if not ok then return nil, reason end
  return true
end

function dpkg.runScript(name, scriptName, action, opts)
  opts = opts or {}
  local path = dpkg.infoDir .. "/" .. name .. "." .. scriptName
  if not fs.exists(path) then return true end
  local src = fs.readFile(path)
  if not src then return nil, "cannot read " .. path end
  return runSource(src, path, action, opts.oldVersion or opts.version)
end

---------------------------------------------------------------
-- Inspection
---------------------------------------------------------------

function dpkg.inspect(path)
  local reader, err = fpkg.open(path)
  if not reader then return nil, err end
  local fields = reader.fields
  local scripts, scriptErr = reader:loadScripts()
  if not scripts then reader:close() return nil, scriptErr end
  local conffiles = {}
  while true do
    local entry, nerr = reader:next()
    if not entry then
      if nerr then reader:close() return nil, nerr end
      break
    end
    if entry.type == "c" then conffiles[#conffiles + 1] = entry.path end
    local ok, skipErr = reader:skip()
    if not ok then reader:close() return nil, skipErr end
  end
  reader:close()
  return { fields = fields, scripts = scripts, conffiles = conffiles }
end

---------------------------------------------------------------
-- Install lifecycle
---------------------------------------------------------------

-- OC's fs.remove is recursive for directories. Package file lists contain
-- directory entries (e.g. /bin, /usr), so removing every entry blindly
-- wipes shared system trees. Only ever drop a directory when it is empty;
-- shared dirs survive because they still hold other entries.
local function dirIsEmpty(path)
  local list = fs.list(path)
  if type(list) ~= "table" then return false end
  for _ in ipairs(list) do return false end
  return true
end

local function replaceFile(tmp, target)
  if fs.isDirectory(target) and not fs.isLink(target) then
    if not dirIsEmpty(target) then
      return nil, "refusing to replace non-empty directory " .. target
    end
  end
  local backup = target .. ".dpkg-old"
  if fs.exists(backup) or fs.isLink(backup) then
    return nil, "backup path already exists: " .. backup
  end
  local hadOld = fs.exists(target) or fs.isLink(target)
  if hadOld then
    local bok, berr = fs.rename(target, backup)
    if not bok then return nil, berr or ("cannot preserve " .. target) end
  end
  local ok, err = fs.rename(tmp, target)
  if not ok then
    if hadOld then fs.rename(backup, target) end
    return nil, err or ("cannot install " .. target)
  end
  if hadOld then fs.remove(backup) end
  return true
end

local function mergeFields(db, name, fields, status)
  local f = db.byName[name]
  if not f then
    f = {}
    db.byName[name] = f
    db.order[#db.order + 1] = name
  end
  for k in pairs(f) do f[k] = nil end
  if fields then
    for k, v in pairs(fields) do f[k] = v end
  end
  f.Package = name
  f.Status = status
  return f
end

function dpkg.unpack(fpkgPath, opts)
  opts = opts or {}
  local lok, lerr = acquireLock()
  if not lok then return nil, lerr end
  local function done(ok, err)
    releaseLock()
    return ok, err
  end
  local reader, oerr = fpkg.open(fpkgPath)
  if not reader then return done(nil, oerr) end
  local fields, order = reader.fields, reader.order
  local name = fields and fields.Package
  if not name then reader:close() return done(nil, "package has no Package field") end
  if not fpkg.validPackageName(name) then
    reader:close()
    return done(nil, "invalid package name: " .. tostring(name))
  end
  local old = dpkg.getStanza(name)
  local oldver = old and old.Version
  local prev = old and dpkg.pkgStatus(name) or "not-installed"
  local isUpgrade = prev ~= "not-installed" and prev ~= "config-files"
  local scripts, scriptErr = reader:loadScripts()
  if not scripts then reader:close() return done(nil, scriptErr) end
  if scripts.preinst then
    local sok, serr = runSource(scripts.preinst, name .. ".preinst",
      isUpgrade and "upgrade" or "install", oldver)
    if not sok then
      reader:close()
      return done(nil, "preinst: " .. tostring(serr))
    end
  end
  local oldSums = readSums(name)
  local list, sums, conff = {}, {}, {}
  local function abort(msg)
    reader:close()
    local db = dpkg.loadStatus()
    mergeFields(db, name, fields, "install ok half-installed")
    dpkg.saveStatus(db)
    return done(nil, msg)
  end
  local xok, xerr = pcall(function()
    while true do
      local entry, nerr = reader:next()
      if not entry then
        if nerr then error(nerr) end
        break
      end
      if entry.type == "d" then
        local dok, derr = fpkg.ensureDir(entry.path)
        if not dok then error(derr or ("cannot create " .. entry.path)) end
        list[#list + 1] = entry.path
      elseif entry.type == "f" or entry.type == "c" then
        local parent = fs.dir(entry.path)
        if parent and parent ~= "" and parent ~= "/" then fpkg.ensureDir(parent) end
        local tmp = entry.path .. ".dpkg-new"
        local h = sha256.new()
        local fd, ferr = fs.open(tmp, "w")
        if not fd then error(ferr or ("cannot write " .. tmp)) end
        while true do
          local chunk, rerr = reader:readData(4096)
          if not chunk then
            if rerr then fs.close(fd) error(rerr) end
            break
          end
          h:update(chunk)
          local wok, werr = fs.write(fd, chunk)
          if not wok then fs.close(fd) error(werr or "write failed") end
        end
        fs.close(fd)
        local hex = h:hex()
        if entry.type == "c" then
          conff[#conff + 1] = entry.path
          local keep = false
          if fs.exists(entry.path) and not fs.isDirectory(entry.path) then
            local cur = fpkg.hashFile(entry.path)
            if cur ~= hex and not (oldSums[entry.path] and cur == oldSums[entry.path]) then
              keep = true
            end
          end
          if not keep then
            local rok, rerr = replaceFile(tmp, entry.path)
            if not rok then error(rerr) end
          else
            fs.remove(tmp)
          end
        else
          local rok, rerr = replaceFile(tmp, entry.path)
          if not rok then error(rerr) end
        end
        list[#list + 1] = entry.path
        sums[#sums + 1] = hex .. "  " .. entry.path
      elseif entry.type == "l" then
        local parent = fs.dir(entry.path)
        if parent and parent ~= "" and parent ~= "/" then fpkg.ensureDir(parent) end
        if fs.isLink(entry.path) then
          fs.remove(entry.path)
        elseif fs.isDirectory(entry.path) then
          if not dirIsEmpty(entry.path) then
            error("refusing to replace non-empty directory " .. entry.path)
          end
          fs.remove(entry.path)
        elseif fs.exists(entry.path) then
          fs.remove(entry.path)
        end
        local lok2, lerr2 = fs.link(entry.target, entry.path)
        if not lok2 then error(lerr2 or ("cannot link " .. entry.path)) end
        list[#list + 1] = entry.path
      else
        reader:skip()
      end
    end
  end)
  if not xok then return abort(tostring(xerr)) end
  reader:close()
  local iok, ierr = writeInfo(name, list, sums, conff, scripts)
  if not iok then return abort("info: " .. tostring(ierr)) end
  local db = dpkg.loadStatus()
  mergeFields(db, name, fields, "install ok unpacked")
  local sok, serr = dpkg.saveStatus(db)
  if not sok then return done(nil, serr) end
  return done(true)
end

function dpkg.configure(name, opts)
  opts = opts or {}
  local lok, lerr = acquireLock()
  if not lok then return nil, lerr end
  local fields = dpkg.getStanza(name)
  if not fields then
    releaseLock()
    return nil, "package " .. name .. " is not installed"
  end
  local status = dpkg.pkgStatus(name)
  if status ~= "unpacked" and status ~= "half-configured"
    and status ~= "installed" and not opts.force then
    releaseLock()
    return nil, "package " .. name .. " is not ready to configure (" .. status .. ")"
  end
  local ok, err = dpkg.runScript(name, "postinst", "configure", opts)
  if not ok then
    local db = dpkg.loadStatus()
    if db.byName[name] then db.byName[name].Status = "install ok half-configured" end
    dpkg.saveStatus(db)
    releaseLock()
    return nil, "postinst: " .. tostring(err)
  end
  local db = dpkg.loadStatus()
  if db.byName[name] then db.byName[name].Status = "install ok installed" end
  local sok, serr = dpkg.saveStatus(db)
  releaseLock()
  if not sok then return nil, serr end
  return true
end

function dpkg.installFile(fpkgPath, opts)
  local ok, err = dpkg.unpack(fpkgPath, opts)
  if not ok then return nil, err end
  local reader, rerr = fpkg.open(fpkgPath)
  if not reader then return nil, rerr end
  local name = reader.fields.Package
  reader:close()
  if not name then return nil, "package has no Package field" end
  return dpkg.configure(name, opts)
end

function dpkg.remove(name, opts)
  opts = opts or {}
  local purge = opts.purge
  local lok, lerr = acquireLock()
  if not lok then return nil, lerr end
  local fields = dpkg.getStanza(name)
  if not fields then
    releaseLock()
    return nil, "package " .. name .. " is not installed"
  end
  local ok, err = dpkg.runScript(name, "prerm", "remove", opts)
  if not ok then
    releaseLock()
    return nil, "prerm: " .. tostring(err)
  end
  local files = dpkg.fileList(name)
  local conff = {}
  for _, p in ipairs(dpkg.conffiles(name)) do conff[p] = true end
  table.sort(files, function(a, b) return #a > #b end)
  local remaining = {}
  for _, path in ipairs(files) do
    local islink = fs.isLink(path)
    if islink then
      fs.remove(path)
    elseif fs.isDirectory(path) then
      if dirIsEmpty(path) then fs.remove(path) end
    elseif conff[path] then
      if purge then
        fs.remove(path)
      elseif fs.exists(path) or fs.isLink(path) then
        remaining[#remaining + 1] = path
      end
    else
      fs.remove(path)
    end
  end
  local ok2, err2 = dpkg.runScript(name, "postrm", "remove", opts)
  if not ok2 then
    releaseLock()
    return nil, "postrm: " .. tostring(err2)
  end
  if purge then
    dpkg.runScript(name, "postrm", "purge", opts)
    removeInfo(name)
    deleteStanza(name)
    releaseLock()
    return true
  end
  if #remaining > 0 then
    local db = dpkg.loadStatus()
    if db.byName[name] then db.byName[name].Status = "deinstall ok config-files" end
    dpkg.saveStatus(db)
    releaseLock()
    return true
  end
  removeInfo(name)
  deleteStanza(name)
  releaseLock()
  return true
end

function dpkg.purge(name, opts)
  local o = {}
  for k, v in pairs(opts or {}) do o[k] = v end
  o.purge = true
  return dpkg.remove(name, o)
end

---------------------------------------------------------------
-- Queries
---------------------------------------------------------------

local function readLines(path)
  local out = {}
  local text = fs.readFile(path)
  if not text then return out end
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if line ~= "" then out[#out + 1] = line end
  end
  return out
end

function dpkg.fileList(name)
  return readLines(dpkg.infoDir .. "/" .. name .. ".list")
end

function dpkg.conffiles(name)
  return readLines(dpkg.infoDir .. "/" .. name .. ".conffiles")
end

function dpkg.owns(path)
  local abs = fs.resolve(path)
  if not abs then return nil end
  local db = dpkg.loadStatus()
  for _, name in ipairs(db.order) do
    for _, p in ipairs(dpkg.fileList(name)) do
      if p == abs then return name end
    end
  end
  return nil
end

function dpkg.installedSize(name)
  local fields = dpkg.getStanza(name)
  if not fields then return 0 end
  return tonumber(fields["Installed-Size"]) or 0
end

return dpkg
