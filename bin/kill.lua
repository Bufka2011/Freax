-- kill: send a signal to processes or process groups.
-- Usage: kill [-s SIGNAL | -SIGNAL] PID...
-- A negative id targets a process group (kill(-pgid)).
-- Signals: TERM (default), KILL, INT, STOP, CONT, 0 (existence check),
-- or a signal number. Same-uid-or-root is enforced by the kernel.
local argv = table.pack(...)
local sig, targets = nil, {}
local i = 1
while i <= argv.n do
  local a = tostring(argv[i])
  if a == "-s" or a == "--signal" then
    sig = argv[i + 1]
    i = i + 2
  elseif a:match("^%-[A-Za-z]") and not a:match("^%-%d+$") then
    sig = a:sub(2)
    i = i + 1
  elseif a == "--help" or a == "-h" then
    io.write("Usage: kill [-s SIGNAL | -SIGNAL] PID...\n")
    return 0
  elseif a == "--" then
    i = i + 1
    break
  else
    targets[#targets + 1] = a
    i = i + 1
  end
end
while i <= argv.n do targets[#targets + 1] = tostring(argv[i]) i = i + 1 end
if #targets == 0 then
  io.stderr:write("kill: usage: kill [-s SIGNAL | -SIGNAL] PID...\n")
  return 1
end
local code = 0
for _, t in ipairs(targets) do
  local ok, err = freax.kill(tonumber(t) or 0, sig)
  if not ok then
    io.stderr:write("kill: " .. tostring(t) .. ": " .. tostring(err) .. "\n")
    code = 1
  end
end
return code
