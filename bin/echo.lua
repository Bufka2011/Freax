local args, options = require("shell").parse(...)
if options.help then
  io.write([[
echo: write arguments to stdout
  -n  do not output trailing newline
  -e  enable interpretation of backslash escapes
]])
  return
end
if options.e then
  for i, arg in ipairs(args) do
    args[i] = assert(load("return \"" .. arg:gsub('"', '\\"') .. "\""))()
  end
end
io.write(table.concat(args, " "))
if not options.n then
  io.write("\n")
end