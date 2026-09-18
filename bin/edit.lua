-- edit: fullscreen editor (M2 rework).
-- Architecture ported from OpenOS edit (line buffer, viewport with
-- scroll, keybind table, find, multi-line cut), behavior nano-like:
-- ^O save, ^X quit (with y/n/c prompt), ^K cut, ^U paste, ^F find.
-- Rendered through the kernel tty only: title bar, content, status.
-- No full-screen clear per keystroke; rows are padded instead.

local fs = require("fs")
local shell = require("shell")
local keyboard = require("keyboard")
local uni = require("unicode")
local K = keyboard.keys

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

-- nano-style keybinds: action -> list of {code=}/ {char=} matchers.
-- (OpenOS edit reads these from /etc/edit.cfg; Freax fixes nano set.)
local keybinds = {
  left      = { { code = K.left } },
  right     = { { code = K.right } },
  up        = { { code = K.up } },
  down      = { { code = K.down } },
  home      = { { code = K.home } },
  eol       = { { code = K["end"] } },
  pageUp    = { { code = K.pageUp } },
  pageDown  = { { code = K.pageDown } },
  backspace = { { code = K.back } },
  delete    = { { code = K.delete } },
  newline   = { { code = K.enter }, { code = K.numpadenter } },
  tab       = { { code = K.tab } },
  save      = { { char = 15 } },  -- ^O
  close     = { { char = 24 } },  -- ^X
  cut       = { { char = 11 } },  -- ^K
  uncut     = { { char = 21 } },  -- ^U
  find      = { { char = 6 } },   -- ^F
  findnext  = { { char = 7 } },   -- ^G
  cancel    = { { code = 1 } },   -- esc
}

local function matchBind(name, char, code)
  for _, m in ipairs(keybinds[name] or {}) do
    if m.code ~= nil and m.code == code then return true end
    if m.char ~= nil and m.char == char then return true end
  end
  return false
end

local args = table.pack(...)
if args.n == 0 then
  io.write("Usage: edit FILE\n")
  return
end
local path = shell.resolve(args[1])
local shownName = args[1]

local lines = { "" }
do
  local data = fs.readFile(path)
  if data then
    lines = {}
    for line in (data .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    if #lines == 0 then lines = { "" } end
  end
end

local cx, cy = 1, 1            -- 1-based cursor in buffer
local scrollX, scrollY = 0, 0  -- 0-based viewport origin
local dirty = false
local msg = ""
local cutBuffer = {}           -- list of cut lines
local cutting = false          -- reset when cursor changes lines
local findQuery, findHits, findIdx = nil, {}, 0

local function save()
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
        hits[#hits + 1] = { row = i, col = s }
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
  msg = string.format("%d/%d", findIdx, #findHits)
end

-- modes: "edit", "find" (query entry), "quit" (y/n/c)
local mode = "edit"
local findBuf = ""

local function draw()
  local w, h = freax.ttySize()
  if w < 10 or h < 4 then
    freax.ttyClear()
    freax.ttyWrite("screen too small")
    return
  end
  local topOff, viewH = 1, h - 2
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
    if #s < lim then s = s .. string.rep(" ", lim - #s) end
    freax.ttyWrite(s:sub(1, lim))
  end
  local title = "  Freax edit: " .. shownName .. (dirty and " *" or "")
  row(1, title)
  for i = 0, viewH - 1 do
    local ln = lines[scrollY + i + 1] or ""
    row(1 + topOff + i, ln:sub(scrollX + 1, scrollX + w))
  end
  local bar
  if mode == "find" then
    bar = "Find: " .. findBuf
  elseif mode == "quit" then
    bar = "Save modified buffer? (y/n/c)"
  else
    bar = "^O save ^X quit ^K cut ^U paste ^F find"
    if msg ~= "" then bar = bar .. "  " .. msg end
    bar = bar .. string.rep(" ", math.max(0, w - #bar - 12))
      .. string.format("Ln %d/%d", cy, #lines)
  end
  row(h, bar)
  if mode == "edit" then
    freax.ttySetCursor(cx - scrollX, cy - scrollY + topOff - 1 + 1)
  else
    freax.ttySetCursor(math.min(#bar + 1, w), h)
  end
end

draw()
while true do
  local name, _, char, code = freax.pullEvent()
  if name == "key_down" then
    msg = ""
    if mode == "find" then
      if matchBind("newline", char, code) or matchBind("findnext", char, code) then
        findQuery = findBuf
        findHits = findAll(findQuery)
        findIdx = 0
        mode = "edit"
        gotoHit(1)
      elseif matchBind("cancel", char, code) then
        mode = "edit"
        msg = "cancelled"
      elseif matchBind("backspace", char, code) then
        findBuf = findBuf:sub(1, -2)
      elseif type(char) == "number" and char >= 32 and char ~= 127 then
        local ins = toChar(char)
        if ins then findBuf = findBuf .. ins end
      end
      draw()
    elseif mode == "quit" then
      local c = ""
      do
        local s = toChar(char)
        if s then
          if type(uni) == "table" and type(uni.lower) == "function" then
            local okL, low = pcall(uni.lower, s)
            c = (okL and type(low) == "string") and low or s:lower()
          else
            c = s:lower()
          end
        end
      end
      if c == "y" then
        if save() then freax.ttyClear() return end
        mode = "edit"
      elseif c == "n" then
        freax.ttyClear()
        return
      else
        mode = "edit" -- n handled above; anything else cancels
        msg = "cancelled"
      end
      draw()
    elseif matchBind("newline", char, code) then
      local cur = lines[cy]
      lines[cy] = cur:sub(1, cx - 1)
      table.insert(lines, cy + 1, cur:sub(cx))
      cy, cx, dirty = cy + 1, 1, true
      cutting = false
      draw()
    elseif matchBind("backspace", char, code) then
      if cx > 1 then
        lines[cy] = lines[cy]:sub(1, cx - 2) .. lines[cy]:sub(cx)
        cx, dirty = cx - 1, true
      elseif cy > 1 then
        cx = #(lines[cy - 1]) + 1
        lines[cy - 1] = lines[cy - 1] .. lines[cy]
        table.remove(lines, cy)
        cy, dirty = cy - 1, true
      end
      cutting = false
      draw()
    elseif matchBind("delete", char, code) then
      local len = #(lines[cy] or "")
      if cx <= len then
        lines[cy] = lines[cy]:sub(1, cx - 1) .. lines[cy]:sub(cx + 1)
        dirty = true
      elseif cy < #lines then
        lines[cy] = lines[cy] .. lines[cy + 1]
        table.remove(lines, cy + 1)
        dirty = true
      end
      cutting = false
      draw()
    elseif matchBind("left", char, code) then
      if cx > 1 then cx = cx - 1
      elseif cy > 1 then cy = cy - 1 cx = #(lines[cy]) + 1 end
      cutting = false
      draw()
    elseif matchBind("right", char, code) then
      if cx <= #(lines[cy] or "") then cx = cx + 1
      elseif cy < #lines then cy, cx = cy + 1, 1 end
      cutting = false
      draw()
    elseif matchBind("up", char, code) then
      if cy > 1 then cy = cy - 1 cx = math.min(cx, #(lines[cy]) + 1) end
      cutting = false
      draw()
    elseif matchBind("down", char, code) then
      if cy < #lines then cy = cy + 1 cx = math.min(cx, #(lines[cy]) + 1) end
      cutting = false
      draw()
    elseif matchBind("home", char, code) then
      cx = 1
      cutting = false
      draw()
    elseif matchBind("eol", char, code) then
      cx = #(lines[cy] or "") + 1
      cutting = false
      draw()
    elseif matchBind("pageUp", char, code) or matchBind("pageDown", char, code) then
      local _, h = freax.ttySize()
      local d = (h - 2) * (matchBind("pageUp", char, code) and -1 or 1)
      cy = math.max(1, math.min(#lines, cy + d))
      cx = math.min(cx, #(lines[cy]) + 1)
      cutting = false
      draw()
    elseif matchBind("tab", char, code) then
      lines[cy] = lines[cy]:sub(1, cx - 1) .. "  " .. lines[cy]:sub(cx)
      cx, dirty = cx + 2, true
      cutting = false
      draw()
    elseif matchBind("save", char, code) then
      save()
      draw()
    elseif matchBind("close", char, code) then
      if dirty then mode = "quit" else freax.ttyClear() return end
      draw()
    elseif matchBind("cut", char, code) then
      if not cutting then cutBuffer = {} end
      cutBuffer[#cutBuffer + 1] = lines[cy]
      table.remove(lines, cy)
      if #lines == 0 then lines = { "" } end
      if cy > #lines then cy = #lines end
      cx = 1
      dirty, cutting = true, true
      draw()
    elseif matchBind("uncut", char, code) then
      for i, ln in ipairs(cutBuffer) do
        table.insert(lines, cy + i, ln)
      end
      if #cutBuffer > 0 then cy = cy + 1 cx = 1 dirty = true end
      cutting = false
      draw()
    elseif matchBind("find", char, code) then
      mode, findBuf = "find", ""
      draw()
    elseif matchBind("findnext", char, code) then
      if findQuery then
        findHits = findAll(findQuery)
        gotoHit(1)
      else
        mode, findBuf = "find", ""
      end
      draw()
    elseif type(char) == "number" and char >= 32 and char ~= 127 then
      local ins2 = toChar(char)
      if ins2 then
        lines[cy] = lines[cy]:sub(1, cx - 1) ..
          ins2 .. lines[cy]:sub(cx)
        cx, dirty = cx + #ins2, true
        cutting = false
        draw()
      end
    end
  end
end
