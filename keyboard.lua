-- keyboard: OpenOS-compatible key state (M2 compat).
-- Scancodes match the OC mod; state is fed from the event tap
-- (per-process, like everything else under Freax).

local keyboard = { pressedChars = {}, pressedCodes = {} }

-- Full scancode table (matches the OC mod; extends the OpenOS boot subset).
keyboard.keys = {
  ["1"] = 0x02, ["2"] = 0x03, ["3"] = 0x04, ["4"] = 0x05,
  ["5"] = 0x06, ["6"] = 0x07, ["7"] = 0x08, ["8"] = 0x09,
  ["9"] = 0x0A, ["0"] = 0x0B,
  a = 0x1E, b = 0x30, c = 0x2E, d = 0x20, e = 0x12, f = 0x21,
  g = 0x22, h = 0x23, i = 0x17, j = 0x24, k = 0x25, l = 0x26,
  m = 0x32, n = 0x31, o = 0x18, p = 0x19, q = 0x10, r = 0x13,
  s = 0x1F, t = 0x14, u = 0x16, v = 0x2F, w = 0x11, x = 0x2D,
  y = 0x15, z = 0x2C,
  apostrophe = 0x28, at = 0x91,
  back = 0x0E, -- backspace
  backslash = 0x2B, capital = 0x3A, colon = 0x92, comma = 0x33,
  enter = 0x1C, equals = 0x0D, grave = 0x29,
  lbracket = 0x1A, lcontrol = 0x1D, lmenu = 0x38, lshift = 0x2A,
  minus = 0x0C, numlock = 0x45, pause = 0xC5, period = 0x34,
  rbracket = 0x1B, rcontrol = 0x9D, rmenu = 0xB8, rshift = 0x36,
  scroll = 0x46, semicolon = 0x27, slash = 0x35, space = 0x39,
  stop = 0x95, tab = 0x0F, underline = 0x93,
  up = 0xC8, down = 0xD0, left = 0xCB, right = 0xCD,
  home = 0xC7, ["end"] = 0xCF, pageUp = 0xC9, pageDown = 0xD1,
  insert = 0xD2, delete = 0xD3,
  f1 = 0x3B, f2 = 0x3C, f3 = 0x3D, f4 = 0x3E, f5 = 0x3F,
  f6 = 0x40, f7 = 0x41, f8 = 0x42, f9 = 0x43, f10 = 0x44,
  f11 = 0x57, f12 = 0x58,
  numpad0 = 0x52, numpad1 = 0x4F, numpad2 = 0x50, numpad3 = 0x51,
  numpad4 = 0x4B, numpad5 = 0x4C, numpad6 = 0x4D, numpad7 = 0x47,
  numpad8 = 0x48, numpad9 = 0x49, numpadmul = 0x37, numpaddiv = 0xB5,
  numpadsub = 0x4A, numpadadd = 0x4E, numpaddecimal = 0x53,
  numpadcomma = 0xB3, numpadenter = 0x9C, numpadequals = 0x8D,
}

setmetatable(keyboard.keys, {
  __index = function(tbl, k)
    if type(k) ~= "number" then return end
    for name, value in pairs(tbl) do
      if value == k then return name end
    end
  end
})

function keyboard.isAltDown()
  return keyboard.pressedCodes[keyboard.keys.lmenu]
      or keyboard.pressedCodes[keyboard.keys.rmenu]
end

function keyboard.isControl(char)
  return type(char) == "number"
    and (char < 0x20 or (char >= 0x7F and char <= 0x9F))
end

function keyboard.isControlDown()
  return keyboard.pressedCodes[keyboard.keys.lcontrol]
      or keyboard.pressedCodes[keyboard.keys.rcontrol]
end

function keyboard.isKeyDown(charOrCode)
  if type(charOrCode) == "string" then
    local b = charOrCode:byte()
    return keyboard.pressedChars[b]
  elseif type(charOrCode) == "number" then
    return keyboard.pressedCodes[charOrCode]
  end
end

function keyboard.isShiftDown()
  return keyboard.pressedCodes[keyboard.keys.lshift]
      or keyboard.pressedCodes[keyboard.keys.rshift]
end

-- feed from event pulls: key_down(addr, char, code), key_up(addr, char, code)
local ok, event = pcall(require, "event")
if ok and event then
  event._taps[#event._taps + 1] = function(name, _, char, code)
    if name == "key_down" then
      if code then keyboard.pressedCodes[code] = true end
      if char and char > 0 then keyboard.pressedChars[char] = true end
    elseif name == "key_up" then
      if code then keyboard.pressedCodes[code] = nil end
      if char and char > 0 then keyboard.pressedChars[char] = nil end
    end
  end
end

return keyboard
