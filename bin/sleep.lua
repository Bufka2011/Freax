local shell = require("shell")
local args, options = shell.parse(...)

if options.help then
  io.write("Usage: sleep NUMBER[SUFFIX]...\n")
  return
end

options.help = nil
if next(options) then
  io.stderr:write("sleep: invalid option\n")
  return 1
end

local function multiplier(t)
  if not t or #t == 0 or t == "s" then return 1 end
  if t == "m" then return 60 end
  if t == "h" then return 3600 end
  if t == "d" then return 86400 end
  return nil
end

local total = 0
for _, v in ipairs(args) do
  local interval, t = v:match("^([%d%.]+)([smhd]?)$")
  interval = tonumber(interval)
  local mult = multiplier(t)
  if not interval or not mult or interval < 0 then
    io.stderr:write("sleep: invalid time interval '" .. v .. "'\n")
    return 1
  end
  total = total + mult * interval
end

os.sleep(total)
