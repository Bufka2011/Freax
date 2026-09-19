local base_io = io
local io = {}

for k, v in pairs(base_io) do io[k] = v end

function io.dup(fd)
  return setmetatable({fd = fd, _closed = false}, {
    __index = function(dfd, key)
      local fd_value = dfd.fd[key]
      if key ~= "close" and type(fd_value) ~= "function" then return fd_value end
      return function(self, ...)
        if key == "close" or self._closed then self._closed = true return end
        return fd_value(self.fd, ...)
      end
    end,
    __newindex = function(dfd, key, value) dfd.fd[key] = value end,
  })
end

function io.type(object)
  if type(object) == "table" then
    local mt = getmetatable(object)
    if mt == "file" then
      local _, err = object:read(0)
      return err and "closed file" or "file"
    end
  end
  return nil
end

return io