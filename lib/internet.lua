-- internet: OpenOS-compatible HTTP over kernel-mediated card (M2).
-- Only request(); raw sockets need component access and stay denied.
local internet = {}

function internet.request(url, data, headers, method)
  local post
  if type(data) == "string" then
    post = data
  elseif type(data) == "table" then
    for k, v in pairs(data) do
      post = post and (post .. "&") or ""
      post = post .. tostring(k) .. "=" .. tostring(v)
    end
  end
  local fd, err = freax.netRequest(url, post, headers, method)
  if not fd then
    error(tostring(err), 2)
  end
  local handle = {}
  function handle.read()
    return freax.fsRead(fd)
  end
  function handle.close()
    return freax.fsClose(fd)
  end
  function handle.response()
    return freax.netResponse(fd)
  end
  function handle.finishConnect()
    return freax.netFinish(fd)
  end
  return setmetatable(handle, {
    __call = function()
      while true do
        local chunk, reason = freax.fsRead(fd)
        if chunk == nil then
          freax.fsClose(fd)
          if reason then error(reason, 2) end
          return nil
        elseif #chunk > 0 then
          return chunk
        end
        os.sleep(0)
      end
    end,
  })
end

-- Raw TCP stream. Handle mirrors the file API (read/write/close).
function internet.socket(address, port)
  if port then
    address = tostring(address) .. ":" .. tostring(port)
  end
  local fd, err = freax.netConnect(tostring(address))
  if not fd then
    return nil, err
  end
  return freax.wrapFd(fd)
end

return internet
