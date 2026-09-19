local shell = require("shell")
local fs = require("fs")

local args, opts = shell.parse(...)

local isDir = opts.d or opts.dir
local verbose = opts.v or opts.verbose
local quiet = opts.q or opts.quiet
if opts.help then
  io.write("Usage: mktmp [OPTION] [PATH]\n" ..
    "Create a new file with a random name in $TMPDIR or PATH argument if given\n" ..
    "  -d              create a directory instead of a file\n" ..
    "  -v, --verbose   print result to stdout, even if no tty\n" ..
    "  -q, --quiet     do not print results to stdout, even if tty\n" ..
    "      --help      print this help message\n")
  return 0
end

local prefix = (args[1] or os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "") .. "/"
if not fs.exists(prefix) then
  io.stderr:write(string.format(
    "mktmp: cannot create tmp %s at %s: no such directory\n",
    isDir and "directory" or "file", prefix))
  return 1
end

local name = os.tmpname()
if not name then io.stderr:write("mktmp: no tmp space\n"); return 1 end
name = prefix .. (name:match("([^/]+)$") or name)

if isDir then
  local ok, err = fs.makeDirectory(name)
  if not ok then
    io.stderr:write("mktmp: cannot create directory '" .. name .. "': " ..
      tostring(err) .. "\n")
    return 1
  end
else
  local f, err = io.open(name, "w")
  if not f then
    io.stderr:write("mktmp: cannot create file '" .. name .. "': " ..
      tostring(err) .. "\n")
    return 1
  end
  f:close()
end

if verbose or not quiet then io.write(name .. "\n") end
return name
