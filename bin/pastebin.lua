-- pastebin: up/download pastes (M2, ported from OpenOS).
local fs = require("fs")
local internet = require("internet")
local shell = require("shell")

if not freax.netAvail() then
  io.stderr:write("This program requires an internet card to run.")
  return
end

local args, options = shell.parse(...)

local function get(pasteId, filename)
  local f, reason = io.open(filename, "w")
  if not f then
    io.stderr:write("Failed opening file for writing: " .. reason)
    return
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
  else
    io.write("failed.\n")
    f:close()
    fs.remove(filename)
    io.stderr:write("HTTP request failed: " .. response .. "\n")
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
  get(pasteId, tmpFile)
  io.write("Running...\n")

  local success, reason = os.execute(tmpFile .. " " .. table.concat(table.pack(...), " "))
  if not success then
    io.stderr:write(tostring(reason))
  end
  fs.remove(tmpFile)
end

local function put(path)
  local config = {}
  local configFile = loadfile("/etc/pastebin.conf", "t", config)
  if configFile then
    local result, reason = pcall(configFile)
    if not result then
      io.stderr:write("Failed loading config: " .. reason)
    end
  end
  config.key = config.key or "fd92bd40a84c127eeb6804b146793c97"
  local file, reason = io.open(path, "r")

  if not file then
    io.stderr:write("Failed opening file for reading: " .. reason)
    return
  end

  local data = file:read("*a")
  file:close()

  io.write("Uploading to pastebin.com... ")
  local result, response = pcall(internet.request,
        "https://pastebin.com/api/api_post.php",
        "api_option=paste&" ..
        "api_dev_key=" .. config.key .. "&" ..
        "api_paste_format=lua&" ..
        "api_paste_expire_date=N&" ..
        "api_paste_name=" .. encode(fs.name(path)) .. "&" ..
        "api_paste_code=" .. encode(data))

  if result then
    local info = ""
    for chunk in response do
      info = info .. chunk
    end
    if string.match(info, "^Bad API request, ") then
      io.write("failed.\n")
      io.write(info)
    else
      io.write("success.\n")
      local pasteId = string.match(info, "[^/]+$")
      io.write("Uploaded as " .. info .. "\n")
      io.write('Run "pastebin get ' .. pasteId .. '" to download anywhere.')
    end
  else
    io.write("failed.\n")
    io.stderr:write(response)
  end
end

local command = args[1]
if command == "put" then
  if #args == 2 then
    put(shell.resolve(args[2]))
    return
  end
elseif command == "get" then
  if #args == 3 then
    local path = shell.resolve(args[3])
    if fs.exists(path) then
      if not options.f or not os.remove(path) then
        io.stderr:write("file already exists")
        return
      end
    end
    get(args[2], path)
    return
  end
elseif command == "run" then
  if #args >= 2 then
    run(args[2], table.unpack(args, 3))
    return
  end
end

io.write("Usages:\n")
io.write("pastebin put [-f] <file>\n")
io.write("pastebin get [-f] <id> <file>\n")
io.write("pastebin run [-f] <id> [<arguments...>]\n")
io.write(" -f: Force overwriting existing files.\n")
io.write(" -k: keep line endings as-is (will convert\n")
io.write("     Windows line endings to Unix otherwise).")
