local shell = require("shell")
local args, options = shell.parse(...)

local err = 0
local function pop(k, conv)
  local r = options[k]; options[k] = nil
  if r and conv then r = tonumber(r) or (function() err = 1; io.stderr:write("--" .. k .. "=N requires number\n") end)() end
  return r
end

local bytes = pop("bytes", true)
local lines = pop("lines", true)
local quiet = pop("q") or pop("quiet") or pop("silent")
local verbose = pop("v") or pop("verbose")
local help = pop("help")
if help or next(options) then
  io.write("Usage: head [--lines=n] [--bytes=n] [-q] [-v] [FILE...]\n")
  return err
end
if #args == 0 then args = {"-"} end
if quiet and verbose then quiet = false end

local n = math.abs(lines or bytes or 10)
local isBytes = bytes ~= nil
local isTail = (lines or 0) < 0 or (bytes or 0) < 0

local function newStream()
  return { open = true, capacity = n, isBytes = isBytes, tail = isTail and {} }
end

local function push(s, line)
  if not line then s.open = false return end
  if s.tail then
    s.tail[#s.tail + 1] = line
    if #s.tail > s.capacity then table.remove(s.tail, 1) end
    return
  end
  if s.capacity <= 0 then return end
  if s.isBytes then
    io.write(line:sub(1, s.capacity))
    s.capacity = s.capacity - #line
  else
    io.write(line .. "\n")
    s.capacity = s.capacity - 1
  end
  if s.capacity <= 0 then s.open = false end
end

for i = 1, #args do
  local f
  if args[i] == "-" then
    f = io.stdin
  else
    f, err = io.open(args[i], "r")
  end
  if not f then
    io.stderr:write("head: " .. args[i] .. ": " .. tostring(err) .. "\n")
  else
    if verbose or #args > 1 then io.write("==> " .. args[i] .. " <==\n") end
    local s = newStream()
    while s.open do
      local line = f:read("*l")
      if not line then break end
      push(s, line)
    end
    if s.tail then
      for _, tl in ipairs(s.tail) do io.write(tl .. "\n") end
    end
    if args[i] ~= "-" then f:close() end
  end
end