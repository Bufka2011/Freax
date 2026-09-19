local buffer = require("buffer")

local internet = {}

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

  local request, reason = freax.netRequest(url, post, headers, method)
  if not request then
    error(reason, 2)
  end

  return setmetatable({
    ["()"] = "function():string -- Tries to read data from the socket stream and return the read byte array.",
    close = setmetatable({}, {
      __call = request.close,
      __tostring = function() return "function() -- closes the connection" end,
    }),
  }, {
    __call = function()
      while true do
        local data, reason = request.read()
        if not data then
          request.close()
          if reason then
            error(reason, 2)
          else
            return nil
          end
        elseif #data > 0 then
          return data
        end
        os.sleep(0)
      end
    end,
    __index = request,
  })
end

local socketStream = {}

function socketStream:close()
  if self.socket then
    self.socket.close()
    self.socket = nil
  end
end

function socketStream:seek()
  return nil, "bad file descriptor"
end

function socketStream:read(n)
  if not self.socket then
    return nil, "connection is closed"
  end
  return self.socket.read(n)
end

function socketStream:write(value)
  if not self.socket then
    return nil, "connection is closed"
  end
  while #value > 0 do
    local written, reason = self.socket.write(value)
    if not written then
      return nil, reason
    end
    value = string.sub(value, written + 1)
  end
  return true
end

function internet.socket(address, port)
  if type(address) ~= "string" then error("bad argument #1 (string expected, got " .. type(address) .. ")") end
  if port ~= nil and type(port) ~= "number" then
    error("bad argument #2 (number or nil expected, got " .. type(port) .. ")")
  end
  if not freax.netAvail() then
    return nil, "no internet card found"
  end
  if port then
    address = address .. ":" .. port
  end
  local socket, reason = freax.netSocket(address)
  if not socket then
    return nil, reason
  end
  local stream = {socket = socket}
  local metatable = {__index = socketStream, __metatable = "socketstream"}
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