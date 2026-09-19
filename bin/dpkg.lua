-- dpkg: Freax package manager front end.
-- Low-level .fpkg install/remove/list; dependency resolution lives in apt.
-- See `man dpkg`.

local fs = require("fs")
local shell = require("shell")
local dpkg = require("dpkg")
local fpkg = require("fpkg")

local args, opts = shell.parse(...)

local function usage()
  io.write([[Usage: dpkg [OPTION]... [PACKAGE|FILE]...
  -i, --install FILE...      install packages from .fpkg archives
      --unpack FILE...       unpack without configuring
      --configure PKG...     configure unpacked packages (-a = all pending)
  -r, --remove PKG...        remove package, keep conffiles
  -P, --purge PKG...         remove package and its conffiles
  -l, --list [PATTERN]       list installed packages
  -L, --listfiles PKG...     list files shipped by a package
  -S, --search PATH...       show which package owns a path
  -s, --status PKG...        show package status stanzas
      --get-selections       list package selections
      --print-architecture   print the package architecture
      --version              print dpkg version
  -h, --help                 show this help
]])
end

local function statusFlags(name)
  local status = dpkg.pkgStatus(name)
  if status == "installed" then return "ii" end
  if status == "unpacked" then return "iU" end
  if status == "half-configured" then return "iF" end
  if status == "half-installed" then return "iH" end
  if status == "config-files" then return "rc" end
  return "un"
end

local function firstLine(text)
  if not text then return "" end
  return tostring(text):match("^([^\n]*)") or ""
end

if opts.h or opts.help then
  usage()
  return 0
end

if opts.version then
  io.write("dpkg (freax) " .. tostring(fpkg.VERSION) .. "\n")
  return 0
end

if opts["print-architecture"] then
  io.write(dpkg.arch() .. "\n")
  return 0
end

if opts["get-selections"] then
  local db = dpkg.loadStatus()
  for _, name in ipairs(db.order) do
    local status = dpkg.pkgStatus(name)
    local selection = "install"
    if status == "config-files" then selection = "deinstall" end
    if status == "not-installed" then selection = "purge" end
    io.write(name .. "\t" .. selection .. "\n")
  end
  return 0
end

if opts.i or opts.install then
  if #args == 0 then usage() return 1 end
  local ec = 0
  for _, file in ipairs(args) do
    local path = shell.resolve(file)
    local ok, err = dpkg.installFile(path)
    if ok then
      io.write("Installed " .. file .. ".\n")
    else
      io.stderr:write("dpkg: " .. tostring(err) .. "\n")
      ec = 1
    end
  end
  return ec
end

if opts.unpack then
  if #args == 0 then usage() return 1 end
  local ec = 0
  for _, file in ipairs(args) do
    local path = shell.resolve(file)
    local ok, err = dpkg.unpack(path)
    if ok then
      io.write("Unpacked " .. file .. ".\n")
    else
      io.stderr:write("dpkg: " .. tostring(err) .. "\n")
      ec = 1
    end
  end
  return ec
end

if opts.configure or opts.a then
  local targets = args
  if opts.a and #args == 0 then
    targets = {}
    local db = dpkg.loadStatus()
    for _, name in ipairs(db.order) do
      local status = dpkg.pkgStatus(name)
      if status == "unpacked" or status == "half-configured" then
        targets[#targets + 1] = name
      end
    end
  end
  if #targets == 0 then
    io.write("dpkg: nothing to configure\n")
    return 0
  end
  local ec = 0
  for _, name in ipairs(targets) do
    local ok, err = dpkg.configure(name)
    if ok then
      io.write("Configured " .. name .. ".\n")
    else
      io.stderr:write("dpkg: " .. tostring(err) .. "\n")
      ec = 1
    end
  end
  return ec
end

if opts.r or opts.remove then
  if #args == 0 then usage() return 1 end
  local ec = 0
  for _, name in ipairs(args) do
    local ok, err = dpkg.remove(name)
    if ok then
      io.write("Removed " .. name .. ".\n")
    else
      io.stderr:write("dpkg: " .. tostring(err) .. "\n")
      ec = 1
    end
  end
  return ec
end

if opts.P or opts.purge then
  if #args == 0 then usage() return 1 end
  local ec = 0
  for _, name in ipairs(args) do
    local ok, err = dpkg.purge(name)
    if ok then
      io.write("Purged " .. name .. ".\n")
    else
      io.stderr:write("dpkg: " .. tostring(err) .. "\n")
      ec = 1
    end
  end
  return ec
end

if opts.l or opts.list then
  local pattern = args[1]
  io.write("Desired=Unknown/Install/Remove/Purge/Hold\n")
  io.write("| Status=Not/Inst/Conf-files/Unpacked/halF-conf/Half-inst\n")
  io.write("|/ Err?=(none)/Reinst-required (Status,Err: uppercase=bad)\n")
  io.write("||/ Name                          Version            Architecture Description\n")
  io.write("+++-=============================-==================-============-========================\n")
  for _, fields in ipairs(dpkg.list()) do
    local name = tostring(fields.Package)
    if not pattern or name:lower():find(pattern:lower(), 1, true) then
      io.write(string.format("%s  %-29s %-18s %-12s %s\n",
        statusFlags(name), name,
        tostring(fields.Version or ""),
        tostring(fields.Architecture or dpkg.arch()),
        firstLine(fields.Description)))
    end
  end
  return 0
end

if opts.L or opts.listfiles then
  if #args == 0 then usage() return 1 end
  local ec = 0
  for _, name in ipairs(args) do
    if not dpkg.getStanza(name) then
      io.stderr:write("dpkg: package " .. name .. " is not installed\n")
      ec = 1
    else
      io.write("/.\n")
      for _, path in ipairs(dpkg.fileList(name)) do io.write(path .. "\n") end
    end
  end
  return ec
end

if opts.S or opts.search then
  if #args == 0 then usage() return 1 end
  local ec = 0
  for _, path in ipairs(args) do
    local owner = dpkg.owns(shell.resolve(path))
    if owner then
      io.write(owner .. ": " .. path .. "\n")
    else
      io.stderr:write("dpkg: no package owns " .. path .. "\n")
      ec = 1
    end
  end
  return ec
end

if opts.s or opts.status then
  if #args == 0 then usage() return 1 end
  local ec = 0
  for _, name in ipairs(args) do
    local fields = dpkg.getStanza(name)
    if not fields then
      io.stderr:write("dpkg: package " .. name .. " is not installed\n")
      ec = 1
    else
      io.write(fpkg.serializeControl(fields))
      io.write("\n")
    end
  end
  return ec
end

usage()
return 1
