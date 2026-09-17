-- edit: minimal fullscreen editor (M2, nano-flavored).
-- Arrows/home/end move, type to insert, backspace/enter edit,
-- ^O saves, ^X quits (^X twice when unsaved). No select/colors yet.
local fs = require("fs")
local shell = require("shell")
local keyboard = require("keyboard")
local K = keyboard.keys

local args = table.pack(...)
if args.n == 0 then
  io.write("Usage: edit FILE\n")
  return
end
local path = shell.resolve(args[1])

local lines = { "" }
do
  local data = fs.readFile(path)
  if data then
    lines = {}
    for line in (data .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    if #lines == 0 then lines = { "" } end
  end
end

local cx, cy, top = 1, 1, 1
local dirty, quitArm, msg = false, false, ""
local cutBuf = nil

local function save()
  local f, err = io.open(path, "w")
  if not f then
    msg = "save failed: " .. tostring(err)
    return
  end
  f:write(table.concat(lines, "\n"))
  if #lines > 0 then f:write("\n") end
  f:close()
  dirty = false
  msg = "saved " .. path
end

local function draw()
  local w, h = freax.ttySize()
  local viewH = h - 1
  if cy < top then top = cy end
  if cy > top + viewH - 1 then top = cy - viewH + 1 end
  freax.ttyClear()
  for i = 0, viewH - 1 do
    local ln = lines[top + i]
    if ln == nil then
      freax.ttyWrite("\n")
    else
      freax.ttyWrite(ln:sub(1, w) .. "\n")
    end
  end
  local bar = (dirty and "*" or " ") .. args[1] ..
    "  ^O save ^K cut ^U paste ^X quit" .. (msg ~= "" and ("  " .. msg) or "")
  freax.ttyWrite(bar:sub(1, w))
  freax.ttySetCursor(math.min(cx, w), cy - top + 1)
end

draw()
while true do
  local name, _, char, code = freax.pullEvent()
  if name == "key_down" then
    msg = ""
    local len = #(lines[cy] or "")
    if code == 28 then -- enter: split line
      local cur = lines[cy]
      lines[cy] = cur:sub(1, cx - 1)
      table.insert(lines, cy + 1, cur:sub(cx))
      cy, cx, dirty, quitArm = cy + 1, 1, true, false
    elseif code == 14 then -- backspace
      if cx > 1 then
        lines[cy] = lines[cy]:sub(1, cx - 2) .. lines[cy]:sub(cx)
        cx, dirty, quitArm = cx - 1, true, false
      elseif cy > 1 then
        cx = #(lines[cy - 1]) + 1
        lines[cy - 1] = lines[cy - 1] .. lines[cy]
        table.remove(lines, cy)
        cy, dirty, quitArm = cy - 1, true, false
      end
    elseif code == K.left then
      if cx > 1 then cx = cx - 1
      elseif cy > 1 then cy = cy - 1 cx = #(lines[cy]) + 1 end
    elseif code == K.right then
      if cx <= len then cx = cx + 1
      elseif cy < #lines then cy, cx = cy + 1, 1 end
    elseif code == K.up then
      if cy > 1 then cy = cy - 1 cx = math.min(cx, #(lines[cy]) + 1) end
    elseif code == K.down then
      if cy < #lines then cy = cy + 1 cx = math.min(cx, #(lines[cy]) + 1) end
    elseif code == K.home then cx = 1
    elseif code == K["end"] then cx = len + 1
    elseif code == K.delete then -- delete char under cursor
      if cx <= len then
        lines[cy] = lines[cy]:sub(1, cx - 1) .. lines[cy]:sub(cx + 1)
        dirty, quitArm = true, false
      elseif cy < #lines then
        lines[cy] = lines[cy] .. lines[cy + 1]
        table.remove(lines, cy + 1)
        dirty, quitArm = true, false
      end
    elseif char == 15 then -- ^O
      save()
    elseif char == 11 then -- ^K: cut line into paste buffer
      cutBuf = lines[cy]
      table.remove(lines, cy)
      if #lines == 0 then lines = { "" } end
      if cy > #lines then cy = #lines end
      cx = 1
      dirty, quitArm = true, false
    elseif char == 21 then -- ^U: paste buffer below cursor line
      if cutBuf then
        table.insert(lines, cy + 1, cutBuf)
        cy = cy + 1
        cx = 1
        dirty, quitArm = true, false
      end
    elseif char == 24 then -- ^X
      if dirty and not quitArm then
        quitArm = true
        msg = "unsaved changes -- ^X again to quit"
      else
        freax.ttyClear()
        return
      end
    elseif char == 9 then -- tab: two spaces
      lines[cy] = lines[cy]:sub(1, cx - 1) .. "  " .. lines[cy]:sub(cx)
      cx, dirty, quitArm = cx + 2, true, false
    elseif char and char >= 32 and char ~= 127 then
      lines[cy] = lines[cy]:sub(1, cx - 1) ..
        string.char(char) .. lines[cy]:sub(cx)
      cx, dirty, quitArm = cx + 1, true, false
    end
    draw()
  end
end
