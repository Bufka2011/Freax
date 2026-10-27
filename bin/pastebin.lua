-- pastebin: up/download pastes (M2, ported from OpenOS).
local fs = require("fs")
local internet = require("internet")
local shell = require("shell")

if not freax.netAvail() then
  io.stderr:write("This program requires an internet card to run.\n")
  return 1
end

local args, options = shell.parse(...)

local function get(pasteId, filename)
  local f, reason = io.open(filename, "w")
  if not f then
    io.stderr:write("Failed opening file for writing: " .. tostring(reason) .. "\n")
    return 1
  end

  io.write("Downloading from pastebin.com... ")
  local url = "https://pastebin.com/raw/" .. pasteId
  local result, response = pcall(internet.request, url)
  if result then
    io.write("success.\n")
    for chunk in response do
      if not options.k then
        chunk = string.gsub(chunk, "\r\n", "\n")
      end
      f:write(chunk)
    end

    f:close()
    io.write("Saved data to " .. filename .. "\n")
    return 0
  else
    io.write("failed.\n")
    f:close()
    fs.remove(filename)
    io.stderr:write("HTTP request failed: " .. tostring(response) .. "\n")
    return 1
  end
end

local function encode(code)
  if code then
    code = string.gsub(code, "([^%w ])", function(c)
      return string.format("%%%02X", string.byte(c))
    end)
    code = string.gsub(code, " ", "+")
  end
  return code
end

local function run(pasteId, ...)
  local tmpFile = os.tmpname()
  -- pastebin run aborts (exit 1) when the download itself fails, so we
  -- never execute a half-written temp file
  if get(pasteId, tmpFile) ~= 0 then
    fs.remove(tmpFile)
    return 1
  end

  io.write("Running...\n")
  local success, reason, code = os.execute(tmpFile .. " " .. table.concat(table.pack(...), " "))
  if not success then
    io.stderr:write(tostring(reason) .. (code and (" " .. code) or "") .. "\n")
  end
  fs.remove(tmpFile)
  return code or (success and 0 or 1)
end

local function put(path)
  local config = {}
  local configFile = loadfile("/etc/pastebin.conf", "t", config)
  if configFile then
    local result, reason = pcall(configFile)
    if not result then
      io.stderr:write("Failed loading config: " .. tostring(reason) .. "\n")
    end
  end
  config.key = config.key or "fd92bd40a84c127eeb6804b146793c97"
  local file, reason = io.open(path, "r")

  if not file then
    io.stderr:write("Failed opening file for reading: " .. tostring(reason) .. "\n")
    return 1
  end

  -- stream the file in fixed chunks, url-encoding each one, so the raw
  -- file is never fully buffered (the request body needs encoding anyway)
  local encParts = {}
  while true do
    local chunk = file:read(4096)
    if not chunk or chunk == "" then break end
    encParts[#encParts + 1] = encode(chunk)
  end
  file:close()

  io.write("Uploading to pastebin.com... ")
  local result, response = pcall(internet.request,
        "https://pastebin.com/api/api_post.php",
        "api_option=paste&" ..
        "api_dev_key=" .. config.key .. "&" ..
        "api_paste_format=lua&" ..
        "api_paste_expire_date=N&" ..
        "api_paste_name=" .. encode(fs.name(path)) .. "&" ..
        "api_paste_code=" .. table.concat(encParts))

  if result then
    local parts = {}
    for chunk in response do
      parts[#parts + 1] = chunk
    end
    local info = table.concat(parts)
    if string.match(info, "^Bad API request, ") then
      io.write("failed.\n")
      io.stderr:write(info .. "\n")
      return 1
    else
      io.write("success.\n")
      local pasteId = string.match(info, "[^/]+$")
      io.write("Uploaded as " .. info .. "\n")
      io.write('Run "pastebin get ' .. pasteId .. '" to download anywhere.\n')
      return 0
    end
  else
    io.write("failed.\n")
    io.stderr:write(tostring(response) .. "\n")
    return 1
  end
end

local command = args[1]
if command == "put" then
  if #args == 2 then
    return put(shell.resolve(args[2]))
  end
elseif command == "get" then
  if #args == 3 then
    local path = shell.resolve(args[3])
    if fs.exists(path) then
      if not options.f then
        io.stderr:write("pastebin: file already exists: " .. path .. "\n")
        return 1
      end
      if not os.remove(path) then
        io.stderr:write("pastebin: cannot remove " .. path .. "\n")
        return 1
      end
    end
    return get(args[2], path)
  end
elseif command == "run" then
  if #args >= 2 then
    return run(args[2], table.unpack(args, 3))
  end
end

io.stderr:write("Usages:\n")
io.stderr:write("pastebin put [-f] <file>\n")
io.stderr:write("pastebin get [-f] <id> <file>\n")
io.stderr:write("pastebin run [-f] <id> [<arguments...>]\n")
io.stderr:write(" -f: Force overwriting existing files.\n")
io.stderr:write(" -k: keep line endings as-is (will convert\n")
io.stderr:write("     Windows line endings to Unix otherwise).\n")
return 1
