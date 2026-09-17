-- rs: mediated redstone card access (M2 compat, require "rs").
-- First redstone card found; any method forwards via freax.rs.
-- (Named rs so it never collides with /bin/redstone.lua in flat layout.)
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
