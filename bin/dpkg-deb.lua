-- dpkg-deb: build and inspect Freax .fpkg archives.
-- See `man dpkg-deb`.

local fs = require("fs")
local shell = require("shell")
local fpkg = require("fpkg")

local args, opts = shell.parse(...)

local SCRIPT_NAMES = { "preinst", "postinst", "prerm", "postrm" }

local function usage()
  io.write([[Usage: dpkg-deb ACTION [OPTION]...
  -b, --build DIR [OUT.fpkg]   build an archive from DIR/DEBIAN
  -c, --contents PKG           list archive contents
  -I, --info PKG               show control metadata and scripts
  -x, --extract PKG DIR        extract package data into DIR
  -e, --control PKG DIR        extract control files into DIR
  -h, --help                   show this help
]])
end

local function trim(s) return (tostring(s or ""):match("^%s*(.-)%s*$")) end

local function stripSlash(s) return (tostring(s or ""):gsub("/+$", "")) end

local function join(a, b)
  if a == "" or a == "/" then return "/" .. b end
  return a .. "/" .. b
end

local function collect(root, rel, out, skip)
  local entries = fs.list(rel == "" and root or join(root, rel)) or {}
  table.sort(entries)
  for _, raw in ipairs(entries) do
    local name = stripSlash(raw)
    if name ~= "" and not (rel == "" and name == "DEBIAN") then
      local full = join(rel == "" and root or join(root, rel), name)
      local r = rel == "" and name or (rel .. "/" .. name)
      if skip and skip[fs.resolve(full)] then
        -- building over an existing archive: leave it out
      elseif fs.isLink(full) then
        local _, target = fs.isLink(full)
        out[#out + 1] = { kind = "l", path = "/" .. r, target = target, full = full }
      elseif fs.isDirectory(full) then
        out[#out + 1] = { kind = "d", path = "/" .. r, full = full }
        collect(root, r, out, skip)
      else
        out[#out + 1] = { kind = "f", path = "/" .. r, full = full }
      end
    end
  end
end

local function build(dir, outPath)
  local control = fs.readFile(dir .. "/DEBIAN/control")
  if not control then return nil, "cannot read " .. dir .. "/DEBIAN/control" end
  local fields, order = fpkg.parseControl(control)
  local name = fields.Package or fs.name(dir)
  local version = fields.Version or "0"
  local out = outPath or (name .. "_" .. version .. "_all.fpkg")
  local conff = {}
  local conffText = fs.readFile(dir .. "/DEBIAN/conffiles")
  if conffText then
    for line in (conffText .. "\n"):gmatch("(.-)\n") do
      line = trim(line)
      if line ~= "" and line:sub(1, 1) ~= "#" then conff[line] = true end
    end
  end
  local skip = { [fs.resolve(out)] = true }
  local entries = {}
  collect(dir, "", entries, skip)
  local w, werr = fpkg.writer(out)
  if not w then return nil, werr end
  local ok, err = w:control(fields, order)
  if not ok then return nil, err end
  for _, script in ipairs(SCRIPT_NAMES) do
    local text = fs.readFile(dir .. "/DEBIAN/" .. script)
    if text then
      local sok, serr = w:script(script, text)
      if not sok then return nil, serr end
    end
  end
  for _, entry in ipairs(entries) do
    local eok, eerr
    if entry.kind == "d" then
      eok, eerr = w:addDir(entry.path)
    elseif entry.kind == "l" then
      eok, eerr = w:addLink(entry.path, entry.target)
    else
      eok, eerr = w:addFile(entry.path, conff[entry.path], entry.full)
    end
    if not eok then return nil, eerr end
  end
  local fok, ferr = w:finish()
  if not fok then return nil, ferr end
  local hex, size = fpkg.hashFile(out)
  io.write("dpkg-deb: building package '" .. tostring(name) .. "' in '" .. out .. "'.\n")
  io.write("SHA256: " .. tostring(hex) .. "\n")
  io.write("Size: " .. tostring(size) .. "\n")
  return true
end

local function contents(pkg)
  local reader, err = fpkg.open(pkg)
  if not reader then return nil, err end
  reader:loadScripts()
  while true do
    local entry, nerr = reader:next()
    if not entry then
      reader:close()
      if nerr then return nil, nerr end
      break
    end
    if entry.type == "d" then
      io.write("d " .. entry.size .. "  " .. entry.path .. "/\n")
    elseif entry.type == "l" then
      io.write("l " .. entry.size .. "  " .. entry.path .. " -> " .. entry.target .. "\n")
    else
      io.write("f " .. entry.size .. "  " .. entry.path .. "\n")
    end
    reader:skip()
  end
  return true
end

local function info(pkg)
  local reader, err = fpkg.open(pkg)
  if not reader then return nil, err end
  io.write(fpkg.serializeControl(reader.fields, reader.order))
  local scripts = reader:loadScripts() or {}
  reader:close()
  for _, name in ipairs(SCRIPT_NAMES) do
    if scripts[name] then io.write(name .. " (lua)\n") end
  end
  return true
end

local function extractData(pkg, dir)
  local reader, err = fpkg.open(pkg)
  if not reader then return nil, err end
  reader:loadScripts()
  while true do
    local entry, nerr = reader:next()
    if not entry then
      reader:close()
      if nerr then return nil, nerr end
      break
    end
    local target = dir .. entry.path
    if entry.type == "d" then
      fpkg.ensureDir(target)
    elseif entry.type == "l" then
      fpkg.ensureDir(fs.dir(target))
      if fs.exists(target) or fs.isLink(target) then fs.remove(target) end
      fs.link(entry.target, target)
    else
      fpkg.ensureDir(fs.dir(target))
      local fd, ferr = fs.open(target, "w")
      if not fd then reader:close() return nil, ferr end
      while true do
        local chunk = reader:readData(4096)
        if not chunk then break end
        fs.write(fd, chunk)
      end
      fs.close(fd)
    end
  end
  return true
end

local function extractControl(pkg, dir)
  local reader, err = fpkg.open(pkg)
  if not reader then return nil, err end
  fpkg.ensureDir(dir)
  local ok, werr = fs.writeFile(dir .. "/control",
    fpkg.serializeControl(reader.fields, reader.order))
  if not ok then reader:close() return nil, werr end
  local scripts = reader:loadScripts() or {}
  reader:close()
  for _, name in ipairs(SCRIPT_NAMES) do
    if scripts[name] then
      local sok, serr = fs.writeFile(dir .. "/" .. name, scripts[name])
      if not sok then return nil, serr end
    end
  end
  return true
end

local function run()
  if opts.h or opts.help then usage() return 0 end
  if opts.b or opts.build then
    if not args[1] then usage() return 1 end
    local dir = shell.resolve(args[1])
    local out = args[2] and shell.resolve(args[2]) or nil
    local ok, err = build(dir, out)
    if not ok then io.stderr:write("dpkg-deb: " .. tostring(err) .. "\n") return 1 end
    return 0
  end
  if opts.c or opts.contents then
    if not args[1] then usage() return 1 end
    local ok, err = contents(shell.resolve(args[1]))
    if not ok then io.stderr:write("dpkg-deb: " .. tostring(err) .. "\n") return 1 end
    return 0
  end
  if opts.I or opts.info then
    if not args[1] then usage() return 1 end
    local ok, err = info(shell.resolve(args[1]))
    if not ok then io.stderr:write("dpkg-deb: " .. tostring(err) .. "\n") return 1 end
    return 0
  end
  if opts.x or opts.extract then
    if not (args[1] and args[2]) then usage() return 1 end
    local ok, err = extractData(shell.resolve(args[1]), shell.resolve(args[2]))
    if not ok then io.stderr:write("dpkg-deb: " .. tostring(err) .. "\n") return 1 end
    return 0
  end
  if opts.e or opts.control then
    if not (args[1] and args[2]) then usage() return 1 end
    local ok, err = extractControl(shell.resolve(args[1]), shell.resolve(args[2]))
    if not ok then io.stderr:write("dpkg-deb: " .. tostring(err) .. "\n") return 1 end
    return 0
  end
  usage()
  return 1
end

return run()
