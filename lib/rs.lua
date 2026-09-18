-- rs: mediated redstone card access (M2 compat, require "rs").
-- First redstone card found; any method forwards via freax.rs.
-- (Named rs so require("rs") never resolves to /bin/redstone.lua.)
local redstone = {}

function redstone.present()
  return freax.rsAvail()
end

setmetatable(redstone, {
  __index = function(_, method)
    return function(...)
      return freax.rs(method, ...)
    end
  end,
})

return redstone
