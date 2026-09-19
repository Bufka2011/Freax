local base_io = io
local io = {}

for k, v in pairs(base_io) do io[k] = v end

local shell = require("shell")
local buffer = require("buffer")

local current_input = buffer.new("r", base_io.stdin)
local current_output = buffer.new("w", base_io.stdout)
local current_error = buffer.new("w", base_io.stderr)

function io.open(path, mode)
  local resolved, err = shell.resolve(path)
  if not resolved then return nil, err end
  mode = mode or "r"
  local file, err = base_io.open(resolved, mode)
  if not file then return nil, err end
  return buffer.new(mode, file)
end

function io.input(file)
  if file == nil then return current_input end
  current_input = file
  return file
end

function io.output(file)
  if file == nil then return current_output end
  current_output = file
  return file
end

function io.error(file)
  if file == nil then return current_error end
  current_error = file
  return file
end

function io.tmpfile()
  local name = os.tmpname()
  local file, err = io.open(name, "w")
  if not file then return nil, err end
  return file
end

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