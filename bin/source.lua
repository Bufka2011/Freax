-- source: run a file in a child shell.
-- A child cannot mutate its parent's state; use shell builtin source when
-- environment, aliases, or cwd must remain after script completion.
local raw = table.pack(...)
local quiet, index = false, 1
if raw[index] == "-q" then quiet, index = true, index + 1 end
if raw[index] == "--" then index = index + 1 end
if not raw[index] then
  io.stderr:write("usage: source [-q] FILE [ARG...]\n")
  return 1
end

local args = {}
for i = index, raw.n do args[#args + 1] = raw[i] end

local sink, sinkPath
if quiet then
  sinkPath = os.tmpname()
  if sinkPath then sink = io.open(sinkPath, "w") end
end
local pid, reason
local sinkFd = sink and (sink._fd or (sink.stream and sink.stream._fd))
local function fdOf(handle)
  return type(handle) == "table"
    and (handle._fd or (handle.stream and handle.stream._fd)) or nil
end
pid, reason = freax.spawnIO("sh", "/bin/sh.lua", args,
  fdOf(io.stdin), fdOf(io.stdout), sinkFd or fdOf(io.stderr))
if sink then sink:close() end
if not pid then
  if sinkPath then os.remove(sinkPath) end
  if not quiet then io.stderr:write("source: " .. tostring(reason) .. "\n") end
  return 1
end
local code, waitReason = freax.wait(pid)
if sinkPath then os.remove(sinkPath) end
if code == nil then
  if not quiet then io.stderr:write("source: " .. tostring(waitReason) .. "\n") end
  return 1
end
return code
