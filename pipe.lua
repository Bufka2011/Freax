-- pipe: minimal popen/api over kernel pipes (M2 compat).
-- OpenOS pipe.lua is coupled to its process model; Freax programs
-- get the same capability through io.popen and freax.pipe.
local pipe = {}

function pipe.popen(prog, mode)
  return io.popen(prog, mode)
end

return pipe
