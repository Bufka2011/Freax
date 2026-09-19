-- pipe: minimal popen/api over kernel pipes (M2 compat).
-- OpenOS pipe.lua is coupled to its process model; Freax programs
-- get the same capability through io.popen and freax.pipe.
local pipe = {}

function pipe.popen(prog, mode, env)
  mode = mode or "r"
  local proc = io.popen(prog, mode, env)
  if not proc then return nil end
  local stream = {}
  if mode == "r" then
    local buf = ""
    function stream:read(n)
      if n then
        while #buf < n do
          local chunk = proc:read(4096)
          if not chunk then break end
          buf = buf .. chunk
        end
        local out = buf:sub(1, n)
        buf = buf:sub(n + 1)
        return out
      else
        local rest = proc:read("*a")
        local out = buf .. (rest or "")
        buf = ""
        if #out == 0 then return nil end
        return out
      end
    end
  else
    function stream:write(data)
      return proc:write(data)
    end
  end
  function stream:close()
    return proc:close()
  end
  return stream
end

return pipe
