local shell = require("shell")
local args, options = shell.parse(...)

if options.help then
  io.write("Usage: alias [name[=value] ...]\n")
  return
end

local function validAliasName(k)
  return not k:match("[/%$`=|&;%(%)<> \t]")
end

local function setAlias(k, v)
  if not validAliasName(k) then
    io.stderr:write("alias: `" .. k .. "': invalid alias name\n")
  else
    shell.setAlias(k, v)
  end
end

local function printAlias(k)
  local v = shell.getAlias(k)
  if not v then
    io.stderr:write("alias: " .. k .. ": not found\n")
    return 1
  else
    io.write("alias " .. k .. "='" .. v .. "'\n")
  end
end

if not next(args) then
  for k, v in shell.aliases() do
    io.write("alias " .. k .. "='" .. v .. "'\n")
  end
  return
end

local ec = 0
for _, v in ipairs(args) do
  if type(v) ~= "string" then ec = 1 break end
  local matchBegin, matchEnd = v:find("=")
  if not matchBegin or matchBegin == 1 then
    ec = printAlias(v) or ec
  else
    setAlias(v:sub(1, matchBegin - 1), v:sub(matchEnd + 1))
  end
end
return ec