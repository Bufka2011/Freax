local buffer = require("buffer")

local internet = {}

-------------------------------------------------------------------------------

function internet.request(url, data, headers, method)
  if type(url) ~= "string" then error("bad argument #1 (string expected, got " .. type(url) .. ")") end
  if data ~= nil and type(data) ~= "string" and type(data) ~= "table" then
    error("bad argument #2 (string, table or nil expected, got " .. type(data) .. ")")
  end
  if headers ~= nil and type(headers) ~= "table" then
    error("bad argument #3 (table or nil expected, got " .. type(headers) .. ")")
  end
  if method ~= nil and type(method) ~= "string" then
    error("bad argument #4 (string or nil expected, got " .. type(method) .. ")")
  end

  if not freax.netAvail() then
    error("no internet card found", 2)
  end

  local post
  if type(data) == "string" then
    post = data
  elseif type(data) == "table" then
    for k, v in pairs(data) do
      post = post and (post .. "&") or ""
      post = post .. tostring(k) .. "=" .. tostring(v)
    end
  end

  -- The kernel returns an fd (see freax.netRequest); wrap it in the OpenOS
  -- stream shape -- callable iterator plus .close/.response -- so ported
  -- programs (apt, wget, pastebin) keep working.
  local fd, reason = freax.netRequest(url, post, headers, method)
  if not fd then
    error(reason, 2)
  end

  local function close()
    if fd then local f = fd fd = nil pcall(freax.fsClose, f) end
  end

  return setmetatable({
    ["()"] = "function():string -- Tries to read data from the socket stream and return the read byte array.",
    response = function() return freax.netResponse(fd) end,
    close = setmetatable({}, {
      __call = function() close() end,
      __tostring = function() return "function() -- closes the connection" end,
    }),
  }, {
    __call = function()
      while true do
        if not fd then return nil end
        local data, rreason = freax.fsRead(fd)
        if not data then
          pcall(freax.netFinish, fd)
          close()
          if rreason then
            error(rreason, 2)
          else
            return nil
          end
        elseif #data > 0 then
          return data
        end
        os.sleep(0)
      end
    end,
  })
end

local socketStream = {}

function socketStream:close()
  if self._fd then
    pcall(freax.fsClose, self._fd)
    self._fd = nil
  end
end

function socketStream:seek()
  return nil, "bad file descriptor"
end

function socketStream:read(n)
  if not self._fd then
    return nil, "connection is closed"
  end
  return freax.fsRead(self._fd, n)
end

function socketStream:write(value)
  if not self._fd then
    return nil, "connection is closed"
  end
  return freax.fsWrite(self._fd, value)
end

function internet.socket(address, port)
  if type(address) ~= "string" then error("bad argument #1 (string expected, got " .. type(address) .. ")") end
  if port ~= nil and type(port) ~= "number" then error("bad argument #2 (number or nil expected, got " .. type(port) .. ")") end
  if not freax.netAvail() then
    return nil, "no internet card found"
  end
  if port then
    address = address .. ":" .. port
  end
  local fd, reason = freax.netConnect(address)
  if not fd then
    return nil, reason
  end
  local stream = { _fd = fd }
  local metatable = { __index = socketStream, __metatable = "socketstream" }
  return setmetatable(stream, metatable)
end

function internet.open(address, port)
  local stream, reason = internet.socket(address, port)
  if not stream then
    return nil, reason
  end
  return buffer.new("rwb", stream)
end

return internet
