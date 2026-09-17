-- date: print date/time (M2). Usage: date [+FORMAT] (strftime via os.date).
local args = table.pack(...)
local fmt = "%Y-%m-%d %H:%M:%S"
for i = 1, args.n do
  local a = tostring(args[i])
  if a:sub(1, 1) == "+" then fmt = a:sub(2) end
end
io.write(os.date(fmt) .. "\n")
