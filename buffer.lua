-- buffer: minimal stream wrapper (M2 compat).
-- The kernel already buffers io handles; this exists so unmodified
-- code calling buffer.new(mode, stream) keeps working. Unknown
-- stream shapes pass through untouched.
local buffer = {}

function buffer.new(mode, stream)
  if type(stream) == "table" and (stream.read or stream.write) then
    if not stream.setvbuf then
      stream.setvbuf = function() return true end
    end
    if not stream.flush then
      stream.flush = function() return true end
    end
    return stream
  end
  return nil, "bad stream"
end

return buffer
