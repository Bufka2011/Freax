-- pipe: kernel-pipe popen plus stream helpers.
-- OpenOS pipe.createCoroutineStack/buildPipeChain are tightly coupled to
-- its process/coroutine_handler model. Freax processes are kernel
-- coroutines with real kernel pipes, so only the stream surface is
-- provided here; io.popen/freax.pipe cover the chaining use cases.

local pipe = {}

local function wrap(proc, mode)
  local stream = { mode = mode, _closed = false }
  if mode == "r" then
    local buf = ""
    function stream:read(fmt)
      fmt = fmt or "*l"
      if type(fmt) == "number" then
        while #buf < fmt do
          local chunk = proc:read(4096)
          if not chunk then break end
          buf = buf .. chunk
        end
        if #buf == 0 then return nil end
        local out = buf:sub(1, fmt)
        buf = buf:sub(#out + 1)
        return out
      elseif fmt == "*a" then
        local rest = proc:read("*a")
        local out = buf .. (rest or "")
        buf = ""
        if #out == 0 then return nil end
        return out
      else -- *l / *L
        while true do
          local i = buf:find("\n", 1, true)
          if i then
            local out = buf:sub(1, i - 1)
            buf = buf:sub(i + 1)
            if fmt == "*L" then out = out .. "\n" end
            return out
          end
          local chunk = proc:read(4096)
          if not chunk then
            if #buf == 0 then return nil end
            local out = buf
            buf = ""
            return out
          end
          buf = buf .. chunk
        end
      end
    end
    function stream:lines(...)
      local fmts = table.pack(...)
      return function() return stream:read(table.unpack(fmts, 1, fmts.n)) end
    end
  else
    function stream:write(data) return proc:write(data) end
    function stream:flush() return true end
  end
  function stream:close()
    if self._closed then return true end
    self._closed = true
    return proc:close()
  end
  function stream:seek() return nil, "bad file descriptor" end
  return stream
end

function pipe.popen(prog, mode, env)
  mode = mode or "r"
  if mode ~= "r" and mode ~= "w" then
    return nil, "bad argument #2: invalid mode " .. tostring(mode)
  end
  local proc = io.popen(prog, mode, env)
  if not proc then return nil, "cannot execute" end
  return wrap(proc, mode)
end

return pipe
