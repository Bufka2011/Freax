local shell = require("shell")
local args, opts = shell.parse(...)

local isDir = opts.d
local verbose = opts.v or opts.verbose
local quiet = opts.q or opts.quiet
if opts.help then
  io.write("Usage: mktmp [OPTION] [PATH]\n  -d  create directory\n  -v  verbose\n  -q  quiet\n")
  return
end

local prefix = (args[1] or os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "") .. "/"

local name = os.tmpname()
if not name then io.stderr:write("mktmp: no tmp space\n"); return 1 end
name = prefix .. name:match("/([^/]+)$")

if isDir then
  local ok, err = freax.fsMakeDir(name)
  if not ok then io.stderr:write("mktmp: " .. tostring(err) .. "\n"); return 1 end
else
  local f, err = io.open(name, "w")
  if not f then io.stderr:write("mktmp: " .. tostring(err) .. "\n"); return 1 end
  f:close()
end

if verbose or not quiet then io.write(name .. "\n") end
return name
