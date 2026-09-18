-- printenv: print environment variables (M2). Usage: printenv [NAME...]
local args = table.pack(...)
if args.n == 0 then
  for k, v in pairs(os.getenv()) do io.write(k .. "=" .. tostring(v) .. "\n") end
else
  for i = 1, args.n do
    local v = os.getenv(tostring(args[i]))
    if v ~= nil then io.write(tostring(v) .. "\n") end
  end
end
