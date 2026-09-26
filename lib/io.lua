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
  if type(file) == "string" then file = io.open(file, "r") end
  current_input = file
  io.stdin = file
  return file
end

function io.output(file)
  if file == nil then return current_output end
  if type(file) == "string" then file = io.open(file, "w") end
  current_output = file
  io.stdout = file
  return file
end

function io.error(file)
  if file == nil then return current_error end
  if type(file) == "string" then file = io.open(file, "w") end
  current_error = file
  io.stderr = file
  return file
end

function io.read(...) return current_input:read(...) end
function io.write(...) return current_output:write(...) end
function io.close(file) return (file or current_output):close() end
function io.flush() return current_output:flush() end

function io.lines(filename, ...)
  if filename then
    local file, err = io.open(filename, "r")
    if not file then error(err, 2) end
    local iter = file:lines(...)
    return function()
      local values = table.pack(iter())
      if values[1] == nil then file:close() end
      return table.unpack(values, 1, values.n)
    end
  end
  return current_input:lines(...)
end

io.stdin, io.stdout, io.stderr = current_input, current_output, current_error
-- Mark stdio backed by the shared terminal so programs can detect a tty.
if type(base_io.stdin) == "table" then current_input.tty = base_io.stdin._stdio == true end
if type(base_io.stdout) == "table" then current_output.tty = base_io.stdout._stdio == true end
if type(base_io.stderr) == "table" then current_error.tty = base_io.stderr._stdio == true end

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
    if mt == "file" or object._isfile then
      if object.closed or object._closed then return "closed file" end
      return "file"
    end
  end
  return nil
end

return io
