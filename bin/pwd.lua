local args = table.pack(...)
if args[1] == "-P" then
  io.write(freax.fsCanonical(freax.getCwd()) .. "\n")
else
  io.write(freax.getCwd() .. "\n")
end