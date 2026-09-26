-- redstone: inspect/drive redstone (M2, ported from OpenOS).
-- Hardware goes through the mediated rs lib (first card found).
local colors = require("colors")
local rs = require("rs")
local shell = require("shell")
local sides = require("sides")

if not rs.present() then
  io.stderr:write("This program requires a redstone card or redstone I/O block.\n")
  return 1
end

local args, options = shell.parse(...)
if #args == 0 and not options.w and not options.f then
  io.write("Usage:\n")
  io.write("  redstone <side> [<value>]\n")
  io.write("  redstone -b <side> <color> [<value>]\n")
  io.write("  redstone -w [<value>]\n")
  io.write("  redstone -f [<frequency>]\n")
  return
end

if options.w then
  if not rs.setWirelessOutput then
    -- probe: method-missing lib always answers, so check the card
    local ok = rs.getWirelessInput()
    if ok == nil then
      io.stderr:write("wireless redstone not available\n")
      return 1
    end
  end
  if #args > 0 then
    local value = args[1]
    if tonumber(value) then
      value = tonumber(value) > 0
    else
      value = ({["true"]=true,["on"]=true,["yes"]=true})[value] ~= nil
    end
    local wok, werr = rs.setWirelessOutput(value)
    if not wok then io.stderr:write("redstone: " .. tostring(werr) .. "\n") return 1 end
  end
  io.write("in: " .. tostring(rs.getWirelessInput()) .. "\n")
  io.write("out: " .. tostring(rs.getWirelessOutput()) .. "\n")
elseif options.f then
  if #args > 0 then
    local value = args[1]
    if not tonumber(value) then
      io.stderr:write("invalid frequency\n")
      return 1
    end
    local fok, ferr = rs.setWirelessFrequency(tonumber(value))
    if not fok then io.stderr:write("redstone: " .. tostring(ferr) .. "\n") return 1 end
  end
  io.write("freq: " .. tostring(rs.getWirelessFrequency()) .. "\n")
else
  local side = sides[args[1]]
  if not side then
    io.stderr:write("invalid side\n")
    return 1
  end
  if type(side) == "string" then
    side = sides[side]
  end

  if options.b then
    local color = colors[args[2]]
    if not color then
      io.stderr:write("invalid color\n")
      return 1
    end
    if type(color) == "string" then
      color = colors[color]
    end
    if #args > 2 then
      local value = args[3]
      if tonumber(value) then
        value = tonumber(value)
      else
        value = ({["true"]=true,["on"]=true,["yes"]=true})[value] and 255 or 0
      end
      local bok, berr = rs.setBundledOutput(side, color, value)
      if not bok then io.stderr:write("redstone: " .. tostring(berr) .. "\n") return 1 end
    end
    io.write("in: " .. tostring(rs.getBundledInput(side, color)) .. "\n")
    io.write("out: " .. tostring(rs.getBundledOutput(side, color)) .. "\n")
  else
    if #args > 1 then
      local value = args[2]
      if tonumber(value) then
        value = tonumber(value)
      else
        value = ({["true"]=true,["on"]=true,["yes"]=true})[value] and 15 or 0
      end
      local ok2, err2 = rs.setOutput(side, value)
      if not ok2 then io.stderr:write("redstone: " .. tostring(err2) .. "\n") return 1 end
    end
    io.write("in: " .. tostring(rs.getInput(side)) .. "\n")
    io.write("out: " .. tostring(rs.getOutput(side)) .. "\n")
  end
end
