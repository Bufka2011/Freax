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
  local escapes = { a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v", ["\\"] = "\\" }
  local function decode(arg)
    local out, i = {}, 1
    while i <= #arg do
      local c = arg:sub(i, i)
      if c ~= "\\" or i == #arg then
        out[#out + 1] = c
        i = i + 1
      else
        local e = arg:sub(i + 1, i + 1)
        local hex = e == "x" and arg:match("^([%da-fA-F][%da-fA-F]?)", i + 2)
        local oct = e == "0" and arg:match("^([0-7][0-7]?[0-7]?)", i + 2)
        if hex then out[#out + 1] = string.char(tonumber(hex, 16)) i = i + 2 + #hex
        elseif oct then out[#out + 1] = string.char(tonumber(oct, 8)) i = i + 2 + #oct
        else out[#out + 1] = escapes[e] or ("\\" .. e) i = i + 2 end
      end
    end
    return table.concat(out)
  end
  for i, arg in ipairs(args) do
    args[i] = decode(arg)
  end
end
io.write(table.concat(args, " "))
if not options.n then
  io.write("\n")
end
