-- unicode: requireable shim over the process-global unicode lib.
-- Like lib/computer.lua: the kernel injects `unicode` into every process
-- env, but the live require path (lib/package.lua) has no unicode hook,
-- so require("unicode") (text.lua, edit.lua, ps.lua, less.lua) failed with
-- "module 'unicode' not found". Re-export the global.
return unicode
