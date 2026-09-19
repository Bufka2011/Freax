-- edit: fullscreen editor (M2 rework).
-- Architecture ported from OpenOS edit (line buffer, viewport with
-- scroll, configurable keybind table from /etc/edit.cfg, find,
-- multi-line cut, clipboard paste, touch/scroll navigation and a
-- wide/Unicode aware cursor). Rendered through the kernel tty only:
-- title bar, content, status. No full-screen clear per keystroke;
-- rows are padded instead. Save keeps the Freax backup-on-write.

local fs = require("fs")
local shell = require("shell")
local keyboard = require("keyboard")
local text = require("text")
local uni = require("unicode")
local K = keyboard.keys

-- The keyboard lib's modifier state is fed by an event tap that loses a
-- require-cycle race, so track the modifiers from the event stream here.
local mods = { control = false, shift = false, alt = false }

local function updateMods(name, code)
  if name ~= "key_down" and name ~= "key_up" then return end
  local down = name == "key_down"
  if code == K.lcontrol or code == K.rcontrol then mods.control = down
  elseif code == K.lshift or code == K.rshift then mods.shift = down
  elseif code == K.lmenu or code == K.rmenu then mods.alt = down
  end
end

-- string.char (0-255) throws on Cyrillic/CJK codepoints; unicode.char
-- covers full Unicode -> UTF-8. Returns nil for undecodable input so the
-- keystroke is ignored instead of killing the editor.
local function toChar(char)
  if type(char) ~= "number" or char <= 0 then return nil end
  if type(uni) ~= "table" or type(uni.char) ~= "function" then
    if char >= 0 and char <= 255 then return string.char(char) end
    return nil
  end
  local ok, s = pcall(uni.char, char)
  if ok and type(s) == "string" and s ~= "" then return s end
  return nil
end

local args, opts = shell.parse(...)
if #args == 0 then
  io.write("Usage: edit [-r] FILE\n")
  return
end
local path = shell.resolve(args[1])
local shownName = args[1]

local parentDir = path:match("^(.+)/[^/]+$")
if parentDir and freax.fsExists(parentDir) and not freax.fsIsDir(parentDir) then
  io.stderr:write("Not a directory: " .. parentDir .. "\n"); return 1
end

local readonly = opts.r or opts.readonly or false
if not readonly then
  for _, d in ipairs(freax.fsDevices()) do
    local mp = d.mount
    if mp and (path == mp or path:sub(1, #mp + 1) == mp .. "/") then
      readonly = not not d.readonly; break
    end
  end
end
if freax.fsExists(path) and freax.fsIsDir(path) then
  io.stderr:write("file is a directory\n"); return 1
end

local lines = {}
do
  local data = fs.readFile(path)
  if data then
    for line in (data .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    if #lines == 0 then lines = { "" } end
  else
    lines = { "" }
  end
end

-- Configurable keybinds, OpenOS /etc/edit.cfg format. The file is a Lua
-- chunk assigning `keybinds`; modifiers are matched against the kernel
-- keyboard state. Defaults keep Freax's nano keys and add OpenOS ones.
local function rootWritable()
  for _, d in ipairs(freax.fsDevices()) do
    if d.mount == "/" then return not d.readonly end
  end
  return false
end

local function loadConfig()
  local env = {}
  local config = loadfile("/etc/edit.cfg", nil, env)
  if config then pcall(config) end
  env.keybinds = env.keybinds or {
    left = {{"left"}},
    right = {{"right"}},
    up = {{"up"}},
    down = {{"down"}},
    home = {{"home"}},
    eol = {{"end"}},
    pageUp = {{"pageUp"}},
    pageDown = {{"pageDown"}},

    backspace = {{"back"}, {"shift", "back"}},
    delete = {{"delete"}},
    deleteLine = {{"control", "delete"}, {"shift", "delete"}},
    newline = {{"enter"}, {"numpadenter"}},

    save = {{"control", "s"}, {"control", "o"}},
    close = {{"control", "w"}, {"control", "x"}},
    find = {{"control", "f"}},
    findnext = {{"control", "g"}, {"control", "n"}, {"f3"}},
    cut = {{"control", "k"}},
    uncut = {{"control", "u"}},
  }
  if not config and rootWritable() then
    fs.makeDirectory("/etc")
    local f = io.open("/etc/edit.cfg", "w")
    if f then
      local serialization = require("serialization")
      for k, v in pairs(env.keybinds) do
        f:write(k .. "=" .. tostring(serialization.serialize(v, math.huge)) .. "\n")
      end
      f:close()
    end
  end
  return env
end

local cx, cy = 1, 1            -- display-column cursor, 1-based; line
local scrollX, scrollY = 0, 0  -- 0-based viewport origin
local dirty = false
local msg = ""
local cutBuffer = {}           -- list of cut lines
local cutting = false          -- reset when cursor changes lines
local findQuery, findHits, findIdx = nil, {}, 0
local mode = "edit"            -- "edit", "find", "quit"
local findBuf = ""
local running = true
local config = loadConfig()

-- Wide/Unicode helpers (ported from OpenOS edit). Cursor columns are
-- display cells, never bytes, so Cyrillic/CJK stay intact.
local function line()
  return lines[cy] or ""
end

local function removePrefix(str, length)
  if length >= uni.wlen(str) then
    return ""
  else
    local prefix = uni.wtrunc(str, length + 1)
    local suffix = uni.sub(str, uni.len(prefix) + 1)
    length = length - uni.wlen(prefix)
    if length > 0 then
      suffix = (" "):rep(uni.charWidth(suffix) - length) .. uni.sub(suffix, 2)
    end
    return suffix
  end
end

local function lengthToChars(str, length)
  if length > uni.wlen(str) then
    return uni.len(str) + 1
  else
    local prefix = uni.wtrunc(str, length)
    return uni.len(prefix) + 1
  end
end

local function isWideAtPosition(str, x)
  local index = lengthToChars(str, x)
  if index > uni.len(str) then
    return false, false
  end
  local prefix = uni.sub(str, 1, index)
  local char = uni.sub(str, index, index)
  return uni.isWide(char), uni.wlen(prefix) == x
end

local function clampCursor()
  local str = line()
  local be = uni.wlen(str) + 1
  if cx > be then cx = be end
  if cx < 1 then cx = 1 end
  local wide, right = isWideAtPosition(str, cx)
  if wide and right then cx = cx - 1 end
end

local function save()
  -- backup existing file
  if fs.exists(path) then
    local bk = path .. "~"
    local i = 1
    while fs.exists(bk) do
      bk = path .. "." .. i
      i = i + 1
    end
    fs.copy(path, bk)
  end
  local f, err = io.open(path, "w")
  if not f then
    msg = "save failed: " .. tostring(err)
    return false
  end
  -- chunked: single giant writes risk truncation on real hardware
  local data = table.concat(lines, "\n")
  if #lines > 0 then data = data .. "\n" end
  local ok, werr = true, nil
  for i = 1, #data, 4096 do
    local r, e = f:write(data:sub(i, i + 4095))
    if not r then ok, werr = false, e break end
  end
  f:close()
  if not ok then
    msg = "save failed: " .. tostring(werr)
    return false
  end
  dirty = false
  msg = "saved " .. shownName
  return true
end

local function findAll(query)
  local hits = {}
  if query ~= "" then
    for i, ln in ipairs(lines) do
      local from = 1
      while true do
        local s = ln:find(query, from, true)
        if not s then break end
        local col = uni.wlen(string.sub(ln, 1, s - 1)) + 1
        hits[#hits + 1] = { row = i, col = col }
        from = s + 1
      end
    end
  end
  return hits
end

local function gotoHit(dir)
  if #findHits == 0 then
    msg = "no matches"
    return
  end
  findIdx = ((findIdx - 1 + dir) % #findHits) + 1
  local h = findHits[findIdx]
  cy, cx = h.row, h.col
  clampCursor()
  cutting = false
  msg = string.format("%d/%d", findIdx, #findHits)
end

local function viewHeight()
  local _, h = freax.ttySize()
  return math.max(1, h - 2)
end

-- buffer mutations -----------------------------------------------------
local function insertAt(value)
  if not value or uni.len(value) < 1 then return end
  local str = line()
  local index = lengthToChars(str, cx - 1)
  lines[cy] = uni.sub(str, 1, index - 1) .. value .. uni.sub(str, index)
  cx = cx + uni.wlen(value)
  dirty = true
  cutting = false
end

local function enter()
  local str = line()
  local index = lengthToChars(str, cx - 1)
  lines[cy] = uni.sub(str, 1, index - 1)
  table.insert(lines, cy + 1, uni.sub(str, index))
  cy, cx = cy + 1, 1
  dirty = true
  cutting = false
end

local function deleteAt()
  local str = line()
  if cx <= uni.wlen(str) then
    local index = lengthToChars(str, cx)
    lines[cy] = uni.sub(str, 1, index - 1) .. uni.sub(str, index + 1)
    dirty = true
  elseif cy < #lines then
    lines[cy] = str .. (lines[cy + 1] or "")
    table.remove(lines, cy + 1)
    dirty = true
  end
  cutting = false
end

local moveLeft -- forward declaration: backspace() calls it

local function backspace()
  if cx > 1 then
    moveLeft()
    deleteAt()
  elseif cy > 1 then
    local prev = lines[cy - 1] or ""
    cx = uni.wlen(prev) + 1
    lines[cy - 1] = prev .. (lines[cy] or "")
    table.remove(lines, cy)
    cy = cy - 1
    dirty = true
    cutting = false
  end
end

local function deleteLine()
  if #lines > 1 then
    table.remove(lines, cy)
    if cy > #lines then cy = #lines end
  else
    lines[cy] = ""
  end
  cx = 1
  dirty = true
  cutting = false
end

-- cursor movement ------------------------------------------------------
local function home()
  cx = 1
  cutting = false
end

local function ende()
  cx = uni.wlen(line()) + 1
  cutting = false
end

moveLeft = function()
  clampCursor()
  if cx > 1 then
    local wideTarget, rightTarget = isWideAtPosition(line(), cx - 1)
    if wideTarget and rightTarget then cx = cx - 2 else cx = cx - 1 end
  elseif cy > 1 then
    cy = cy - 1
    cx = uni.wlen(line()) + 1
  end
  cutting = false
end

local function moveRight()
  clampCursor()
  local be = uni.wlen(line()) + 1
  local n = 1
  local wide, right = isWideAtPosition(line(), cx + n)
  if wide and right then n = n + 1 end
  if cx + n <= be then
    cx = cx + n
  elseif cy < #lines then
    cy, cx = cy + 1, 1
  end
  cutting = false
end

local function moveUp(n)
  n = n or 1
  if cy > 1 then cy = math.max(1, cy - n) end
  clampCursor()
  cutting = false
end

local function moveDown(n)
  n = n or 1
  if cy < #lines then cy = math.min(#lines, cy + n) end
  clampCursor()
  cutting = false
end

local function cut()
  if not cutting then cutBuffer = {} end
  cutBuffer[#cutBuffer + 1] = lines[cy]
  table.remove(lines, cy)
  if #lines == 0 then lines = { "" } end
  if cy > #lines then cy = #lines end
  cx = 1
  dirty, cutting = true, true
end

local function uncut()
  home()
  for _, ln in ipairs(cutBuffer) do
    insertAt(ln)
    enter()
  end
  if #cutBuffer > 0 then dirty = true end
  cutting = false
end

local function onClipboard(value)
  if type(value) ~= "string" then return end
  value = value:gsub("\r\n", "\n")
  local start = 1
  local l = value:find("\n", 1, true)
  if l then
    repeat
      local next_line = string.sub(value, start, l - 1)
      next_line = text.detab(next_line, 2)
      insertAt(next_line)
      enter()
      start = l + 1
      l = value:find("\n", start, true)
    until not l
  end
  insertAt(string.sub(value, start))
end

-- key dispatch ---------------------------------------------------------
local function helpStatusText()
  local function prettifyKeybind(label, command)
    local keybind = type(config.keybinds) == "table" and config.keybinds[command]
    if type(keybind) ~= "table" or type(keybind[1]) ~= "table" then return "" end
    local alt, control, shift, key
    for _, value in ipairs(keybind[1]) do
      if value == "alt" then alt = true
      elseif value == "control" then control = true
      elseif value == "shift" then shift = true
      else key = value end
    end
    if not key then return "" end
    return label .. ": [" ..
           (control and "Ctrl+" or "") ..
           (alt and "Alt+" or "") ..
           (shift and "Shift+" or "") ..
           uni.upper(key) .. "] "
  end
  return prettifyKeybind("Save", "save") ..
         prettifyKeybind("Close", "close") ..
         prettifyKeybind("Find", "find") ..
         prettifyKeybind("Cut", "cut") ..
         prettifyKeybind("Uncut", "uncut")
end

local keyHandlers = {
  left = moveLeft,
  right = moveRight,
  up = moveUp,
  down = moveDown,
  home = home,
  eol = ende,
  pageUp = function() moveUp(viewHeight()) end,
  pageDown = function() moveDown(viewHeight()) end,
  backspace = function() if not readonly then backspace() end end,
  delete = function() if not readonly then deleteAt() end end,
  deleteLine = function() if not readonly then deleteLine() end end,
  newline = function() if not readonly then enter() end end,
  save = function() if not readonly then save() end end,
  close = function()
    if dirty then mode = "quit" else running = false end
  end,
  find = function() mode, findBuf = "find", "" end,
  findnext = function()
    if findQuery then
      findHits = findAll(findQuery)
      gotoHit(1)
    else
      mode, findBuf = "find", ""
    end
  end,
  cut = function() if not readonly then cut() end end,
  uncut = function() if not readonly then uncut() end end,
}

local function getKeyBindHandler(code)
  if type(config.keybinds) ~= "table" then return end
  -- Prefer more precise binds, e.g. ctrl+del over del.
  local result, resultName, resultWeight = nil, nil, 0
  for command, keybinds in pairs(config.keybinds) do
    if type(keybinds) == "table" and keyHandlers[command] then
      for _, keybind in ipairs(keybinds) do
        if type(keybind) == "table" then
          local alt, control, shift, key = false, false, false
          for _, value in ipairs(keybind) do
            if value == "alt" then alt = true
            elseif value == "control" then control = true
            elseif value == "shift" then shift = true
            else key = value end
          end
          if key ~= nil and
             (alt == mods.alt) and
             (control == mods.control) and
             (shift == mods.shift) and
             code == K[key] and
             #keybind > resultWeight then
            resultWeight = #keybind
            resultName = command
            result = keyHandlers[command]
          end
        end
      end
    end
  end
  return result, resultName
end

-- rendering ------------------------------------------------------------
local function draw()
  local w, h = freax.ttySize()
  if w < 10 or h < 4 then
    freax.ttyClear()
    freax.ttyWrite("screen too small")
    return
  end
  local viewH = h - 2
  -- keep cursor visible
  if cy - 1 < scrollY then scrollY = cy - 1 end
  if cy - 1 >= scrollY + viewH then scrollY = cy - viewH end
  if scrollY < 0 then scrollY = 0 end
  if cx - 1 < scrollX then scrollX = cx - 1 end
  if cx - 1 >= scrollX + w then scrollX = cx - w end
  if scrollX < 0 then scrollX = 0 end

  local function row(r, s)
    freax.ttySetCursor(1, r)
    s = tostring(s or "")
    -- last row must stay under w chars: writing the w-th cell would
    -- wrap past the bottom and trigger the crude clear-on-scroll.
    local lim = (r == h and w - 1 or w)
    if uni.wlen(s) > lim then s = uni.wtrunc(s, lim) end
    s = text.padRight(s, lim)
    freax.ttyWrite(s)
  end

  local title = "  Freax edit: " .. shownName .. (dirty and " *" or "")
  row(1, title)
  for i = 0, viewH - 1 do
    local ln = lines[scrollY + i + 1]
    local s = ln and removePrefix(ln, scrollX) or ""
    row(1 + 1 + i, s)
  end

  local bar
  if mode == "find" then
    bar = "Find: " .. findBuf
  elseif mode == "quit" then
    bar = "Save modified buffer? (y/n/c)"
  else
    bar = helpStatusText()
    if msg ~= "" then bar = bar .. "  " .. msg end
    local loc = string.format("Ln %d/%d", cy, #lines)
    local pad = w - 1 - uni.wlen(bar) - uni.wlen(loc)
    if pad < 0 then pad = 0 end
    bar = bar .. string.rep(" ", pad) .. loc
  end
  row(h, bar)

  if mode == "edit" then
    local sx = math.max(1, math.min(w, cx - scrollX))
    local sy = math.max(2, math.min(h - 1, cy - scrollY + 1))
    freax.ttySetCursor(sx, sy)
  else
    freax.ttySetCursor(math.min(uni.wlen(bar) + 1, w), h)
  end
end

freax.ttySetBlink(true)
draw()
while running do
  local name, _, a, b, c = freax.pullEvent()
  updateMods(name, b)
  if name == "key_down" then
    msg = ""
    local char, code = a, b
    if mode == "find" then
      if code == 1 then
        mode, msg = "edit", "cancelled"
      else
        local _, hname = getKeyBindHandler(code)
        if hname == "newline" or hname == "findnext" then
          findQuery = findBuf
          findHits = findAll(findQuery)
          findIdx = 0
          mode = "edit"
          gotoHit(1)
        elseif hname == "backspace" then
          findBuf = uni.sub(findBuf, 1, -2)
        else
          local ins = toChar(char)
          if ins and not keyboard.isControl(char) then
            findBuf = findBuf .. ins
          end
        end
      end
      draw()
    elseif mode == "quit" then
      local s = toChar(char)
      local choice = s and s:lower() or ""
      if choice == "y" then
        if save() then running = false else mode = "edit" end
      elseif choice == "n" then
        running = false
      else
        mode, msg = "edit", "cancelled"
      end
      draw()
    else
      local handler = getKeyBindHandler(code)
      if handler then
        handler()
        draw()
      elseif readonly and code == K.q then
        running = false
      elseif not readonly then
        local ins
        if not keyboard.isControl(char) then
          ins = toChar(char)
        elseif char == 9 then
          ins = "  "
        end
        if ins then insertAt(ins) draw() end
      end
    end
  elseif name == "clipboard" and not readonly then
    onClipboard(a)
    draw()
  elseif name == "touch" or name == "drag" then
    local w, h = freax.ttySize()
    if a >= 1 and a <= w and b >= 2 and b <= h - 1 then
      cy = math.max(1, math.min(#lines, scrollY + b - 1))
      cx = a + scrollX
      clampCursor()
      cutting = false
      draw()
    end
  elseif name == "scroll" then
    cy = math.max(1, math.min(#lines, cy - (c or 0) * 12))
    clampCursor()
    cutting = false
    draw()
  end
end
freax.ttyClear()
