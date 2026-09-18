-- package: minimal stub (M2 compat).
-- OpenOS libs call require("package").delay(lib, path) for lazy full
-- implementations; Freax libs are already small, so delay is a no-op.
local package = {}

function package.delay(lib)
  return lib
end

function package.searchpath(name)
  return "/lib/" .. name:gsub("%.", "/") .. ".lua"
end

return package
