local computer = require("computer")

local buffer = {}
local metatable = {__index = buffer, __metatable = "file"}

function buffer.new(mode, stream)
  local result = {
    closed = false,
    tty = false,
    mode = {},
    stream = stream,
    bufferRead = "",
    bufferWrite = "",
    bufferSize = math.max(512, math.min(8 * 1024, computer.freeMemory() / 8)),
    bufferMode = "full",
    readTimeout = math.huge,
  }
  mode = mode or "r"
  for i = 1, #mode do
    result.mode[mode:sub(i, i)] = true
  end
  stream.close = setmetatable({close = stream.close, parent = result}, {__call = buffer.close})
  return setmetatable(result, metatable)
end

function buffer:close()
  local meta = getmetatable(self)
  if meta == metatable.__metatable then
    return self.stream:close()
  end
  local parent = self.parent
  if parent.mode.w or parent.mode.a then
    parent:flush()
  end
  parent.closed = true
  return self.close(parent.stream)
end

function buffer:flush()
  if #self.bufferWrite > 0 then
    local tmp = self.bufferWrite
    self.bufferWrite = ""
    local result, reason = self.stream:write(tmp)
    if not result then
      return nil, reason or "bad file descriptor"
    end
  end
  return self
end

function buffer:lines(...)
  local args = table.pack(...)
  return function()
    local result = table.pack(self:read(table.unpack(args, 1, args.n)))
    if not result[1] and result[2] then
      error(result[2])
    end
    return table.unpack(result, 1, result.n)
  end
end

local function readChunk(self)
  if computer.uptime() > self.timeout then
    error("timeout")
  end
  local result, reason = self.stream:read(math.max(1, self.bufferSize))
  if result then
    self.bufferRead = self.bufferRead .. result
    return self
  else
    return result, reason
  end
end

function buffer:readLine(chop, timeout)
  self.timeout = timeout or (computer.uptime() + self.readTimeout)
  local start = 1
  while true do
    local buf = self.bufferRead
    local i = buf:find("[\r\n]", start)
    local c = i and buf:sub(i, i)
    local is_cr = c == "\r"
    if i and (not is_cr or i < #buf) then
      local n = buf:sub(i + 1, i + 1)
      if is_cr and n == "\n" then
        c = c .. n
      end
      local result = buf:sub(1, i - 1) .. (chop and "" or c)
      self.bufferRead = buf:sub(i + #c)
      return result
    else
      start = #self.bufferRead - (is_cr and 1 or 0)
      local result, reason = readChunk(self)
      if not result then
        if reason then
          return result, reason
        else
          result = #self.bufferRead > 0 and self.bufferRead or nil
          self.bufferRead = ""
          return result
        end
      end
    end
  end
end

function buffer:read(...)
  if not self.mode.r then
    return nil, "read mode was not enabled for this stream"
  end
  if self.mode.w or self.mode.a then
    self:flush()
  end
  if select("#", ...) == 0 then
    return self:readLine(true)
  end
  return self:formatted_read(readChunk, ...)
end

function buffer:seek(whence, offset)
  if self.stream.seek then
    return self.stream:seek(whence, offset)
  end
  return nil, "bad file descriptor"
end

function buffer:setTimeout(timeout)
  self.readTimeout = timeout
  return self
end

function buffer:getTimeout()
  return self.readTimeout
end

function buffer:readAll()
  local result = {}
  while true do
    local chunk, reason = self.stream:read(self.bufferSize)
    if chunk then
      result[#result + 1] = chunk
    elseif reason then
      return nil, reason
    else
      break
    end
  end
  return table.concat(result)
end

function buffer:readNumber()
  local str = ""
  while true do
    local c = self:read(1)
    if not c or #c == 0 then break end
    if c:find("%s") then
      if #str > 0 then break end
    else
      str = str .. c
    end
  end
  if #str > 0 then
    return tonumber(str) or str
  end
  return nil
end

function buffer:readBytesOrChars(n)
  local result, reason = self.stream:read(n)
  return result, reason
end

function buffer:size()
  if self.stream.seek then
    local pos = self.stream:seek()
    local size = self.stream:seek("end")
    self.stream:seek("set", pos)
    return size
  end
  return nil
end

function buffer:setvbuf(mode, size)
  mode = mode or self.bufferMode
  size = size or self.bufferSize
  assert(mode == "no" or mode == "full" or mode == "line",
    "bad argument #1 (no, full or line expected, got " .. tostring(mode) .. ")")
  assert(mode == "no" or type(size) == "number",
    "bad argument #2 (number expected, got " .. type(size) .. ")")
  self.bufferMode = mode
  self.bufferSize = size
  return self.bufferMode, self.bufferSize
end

function buffer:write(...)
  if self.closed then
    return nil, "bad file descriptor"
  end
  if not self.mode.w and not self.mode.a then
    return nil, "write mode was not enabled for this stream"
  end
  local args = table.pack(...)
  for i = 1, args.n do
    if type(args[i]) == "number" then
      args[i] = tostring(args[i])
    end
    if type(args[i]) ~= "string" then
      error("bad argument #" .. i .. " (string expected, got " .. type(args[i]) .. ")")
    end
  end
  for i = 1, args.n do
    local arg = args[i]
    local result, reason
    if self.bufferMode == "no" then
      result, reason = self.stream:write(arg)
    else
      result, reason = buffer.buffered_write(self, arg)
    end
    if not result then
      return nil, reason
    end
  end
  return self
end

function buffer:buffered_write(self, arg)
  self.bufferWrite = self.bufferWrite .. arg
  if #self.bufferWrite >= self.bufferSize or self.bufferMode == "line" then
    return self:flush()
  end
  return self
end

function buffer:formatted_read(readChunk, ...)
  local results = {}
  local formats = table.pack(...)
  for i = 1, formats.n do
    local fmt = formats[i]
    if type(fmt) == "number" then
      local data, err = readChunk(self)
      if data then
        results[i] = self.bufferRead:sub(1, fmt)
        self.bufferRead = self.bufferRead:sub(fmt + 1)
      else
        results[i] = data
      end
    elseif fmt == "*a" or fmt == "*all" then
      local data, err = self:readAll()
      if data then
        results[i] = self.bufferRead .. data
        self.bufferRead = ""
      else
        results[i] = data
      end
    elseif fmt == "*l" or fmt == "*line" then
      results[i] = self:readLine(true)
    elseif fmt == "*L" then
      results[i] = self:readLine(false)
    elseif fmt == "*n" or fmt == "*number" then
      results[i] = self:readNumber()
    elseif fmt == "*N" then
      results[i] = self:readBytesOrChars()
    else
      results[i] = self:readLine(true)
    end
  end
  return table.unpack(results, 1, formats.n)
end

return buffer