-- apt-ftparchive: build Freax repository indexes.
--   apt-ftparchive packages <dir>     -> Packages stanzas for *.fpkg
--   apt-ftparchive release  <suiteDir> -> Release stanza + SHA256/Size
-- Run from the repo root so Filename paths are repository-relative.

local fs = require("fs")
local shell = require("shell")
local fpkg = require("fpkg")

local args, opts = shell.parse(...)
local cmd = args[1]

local FIELD_ORDER = {
  "Package", "Version", "Architecture", "Maintainer", "Installed-Size",
  "Depends", "Pre-Depends", "Recommends", "Suggests", "Conflicts", "Breaks",
  "Replaces", "Provides", "Section", "Priority", "Essential", "Homepage",
  "Description", "Filename", "Size", "SHA256",
}

local function usage()
  io.write("Usage: apt-ftparchive packages <dir>\n")
  io.write("       apt-ftparchive release  <suiteDir>\n")
end

local function toForward(p) return (tostring(p):gsub("\\", "/")) end

local function relToCwd(path)
  path = toForward(path)
  local cwd = toForward(fs.cwd() or "/"):gsub("/+$", "")
  if path:sub(1, 1) == "/" then
    if cwd ~= "" and path:sub(1, #cwd) == cwd then
      path = path:sub(#cwd + 1)
    end
    path = path:gsub("^/+", "")
  end
  path = path:gsub("^%./+", "")
  return path
end

local function fieldOrder(fields)
  local order, seen = {}, {}
  for _, k in ipairs(FIELD_ORDER) do
    if fields[k] ~= nil then
      order[#order + 1] = k
      seen[k] = true
    end
  end
  local extra = {}
  for k in pairs(fields) do if not seen[k] then extra[#extra + 1] = k end end
  table.sort(extra)
  for _, k in ipairs(extra) do order[#order + 1] = k end
  return order
end

local function findFiles(dir, suffix, out)
  local entries = fs.list(dir)
  if not entries then return end
  table.sort(entries)
  for _, name in ipairs(entries) do
    local p = dir .. "/" .. name
    if fs.isDirectory(p) then
      findFiles(p, suffix, out)
    elseif not suffix or name:sub(-#suffix) == suffix then
      out[#out + 1] = p
    end
  end
end

local function packages(dir)
  if not dir then usage() return 1 end
  local files = {}
  findFiles(dir, ".fpkg", files)
  table.sort(files)
  for _, path in ipairs(files) do
    local fields, err = fpkg.readControl(path)
    if not fields then
      io.stderr:write("apt-ftparchive: " .. path .. ": " .. tostring(err) .. "\n")
    else
      local hex, size = fpkg.hashFile(path)
      if not hex then
        io.stderr:write("apt-ftparchive: cannot hash " .. path .. "\n")
      else
        fields.Filename = relToCwd(path)
        fields.Size = tostring(size)
        fields.SHA256 = hex
        io.write(fpkg.serializeControl(fields, fieldOrder(fields)))
        io.write("\n")
      end
    end
  end
  return 0
end

local function release(suiteDir)
  if not suiteDir then usage() return 1 end
  suiteDir = toForward(suiteDir):gsub("/+$", "")
  local suite = suiteDir:match("([^/]+)$") or suiteDir
  local comps = {}
  local entries = fs.list(suiteDir)
  if entries then
    table.sort(entries)
    for _, name in ipairs(entries) do
      if fs.isDirectory(suiteDir .. "/" .. name) then
        comps[#comps + 1] = name
      end
    end
  end
  io.write("Suite: " .. suite .. "\n")
  io.write("Codename: " .. suite .. "\n")
  io.write("Date: " .. os.date("!%a, %d %b %Y %H:%M:%S UTC") .. "\n")
  io.write("Architectures: all\n")
  io.write("Components: " .. table.concat(comps, " ") .. "\n")
  local files = {}
  findFiles(suiteDir, nil, files)
  table.sort(files)
  io.write("SHA256:\n")
  for _, p in ipairs(files) do
    local base = p:match("([^/]+)$")
    if base ~= "Release" and base ~= "InRelease" and base ~= "Release.gpg" then
      local hex, size = fpkg.hashFile(p)
      if hex then
        local relp = p
        if relp:sub(1, #suiteDir) == suiteDir then
          relp = relp:sub(#suiteDir + 1):gsub("^/+", "")
        end
        io.write(string.format(" %s %d %s\n", hex, size, toForward(relp)))
      end
    end
  end
  return 0
end

if not cmd or cmd == "help" or opts.help then
  usage()
  return cmd and 0 or 1
end

if cmd == "packages" then return packages(args[2]) end
if cmd == "release" then return release(args[2]) end

io.stderr:write("apt-ftparchive: unknown command `" .. tostring(cmd) .. "`\n")
usage()
return 1
