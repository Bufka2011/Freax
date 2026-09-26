-- wget: download a file (M2, ported from OpenOS).
local fs = require("fs")
local internet = require("internet")
local shell = require("shell")
local text = require("text")

if not freax.netAvail() then
  io.stderr:write("This program requires an internet card to run.")
  return
end

local args, options = shell.parse(...)
options.q = options.q or options.Q

if #args < 1 then
  io.write("Usage: wget [-fq] <url> [<filename>]\n")
  io.write(" -f: Force overwriting existing files.\n")
  io.write(" -q: Quiet mode - no status messages.\n")
  io.write(" -Q: Superquiet mode - no error messages.")
  return
end

local url = text.trim(args[1])
local filename = args[2]
if not filename then
  filename = url
  local index = string.find(filename, "/[^/]*$")
  if index then
    filename = string.sub(filename, index + 1)
  end
  index = string.find(filename, "?", 1, true)
  if index then
    filename = string.sub(filename, 1, index - 1)
  end
end
filename = text.trim(filename)
if filename == "" then
  if not options.Q then
    io.stderr:write("could not infer filename, please specify one")
  end
  return nil, "missing target filename"
end
filename = shell.resolve(filename)

if fs.isDirectory(filename) then
  return nil, "target is a directory"
end
local preexisted = fs.exists(filename)
if preexisted then
  if not options.f then
    if not options.Q then
      io.stderr:write("file already exists")
    end
    return nil, "file already exists"
  end
end

local tmp = filename .. ".wget-new"
local backup = filename .. ".wget-old"
if fs.exists(tmp) or fs.isLink(tmp) then return nil, "temporary path already exists: " .. tmp end
if fs.exists(backup) or fs.isLink(backup) then return nil, "backup path already exists: " .. backup end
local f, reason = io.open(tmp, "wb")
if not f then
  if not options.Q then
    io.stderr:write("failed opening file for writing: " .. reason)
  end
  return nil, "failed opening file for writing: " .. reason
end
if not options.q then
  io.write("Downloading... ")
end
local result, response = pcall(internet.request, url, nil, {["user-agent"]="Wget/Freax"})
if result then
  local result, reason = pcall(function()
    for chunk in response do
      local ok, werr = f:write(chunk)
      assert(ok, tostring(werr or "write failed"))
    end
  end)
  if not result then
    if not options.q then
      io.stderr:write("failed.\n")
    end
    response.close()
    f:close()
    fs.remove(tmp)
    if not options.Q then
      io.stderr:write("HTTP request failed: " .. reason .. "\n")
    end
    return nil, reason
  end
  if not options.q then
    io.write("success.\n")
  end

  response.close()
  f:close()
  if preexisted then
    local preserved, perr = fs.rename(filename, backup)
    if not preserved then
      fs.remove(tmp)
      if not options.Q then io.stderr:write("failed preserving target: " .. tostring(perr) .. "\n") end
      return nil, perr
    end
  end
  local renamed, rerr = fs.rename(tmp, filename)
  if not renamed then
    fs.remove(tmp)
    if preexisted then fs.rename(backup, filename) end
    if not options.Q then io.stderr:write("failed replacing target: " .. tostring(rerr) .. "\n") end
    return nil, rerr
  end
  if preexisted then fs.remove(backup) end

  if not options.q then
    io.write("Saved data to " .. filename .. "\n")
  end
else
  f:close()
  fs.remove(tmp)
  if not options.q then
    io.write("failed.\n")
  end
  if not options.Q then
    io.stderr:write("HTTP request failed: " .. response .. "\n")
  end
  return nil, response
end
return true
