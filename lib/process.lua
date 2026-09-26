local freax = freax

local process = {}

local handle_registry = {}

function process.info(pid)
  local i
  if pid == nil then
    i = freax.myInfo()
  elseif type(pid) == "number" then
    for _, p in ipairs(freax.ps()) do
      if p.pid == pid then i = p; break end
    end
  elseif type(pid) == "string" then
    for _, p in ipairs(freax.ps()) do
      if p.name == pid then i = p; break end
    end
  end
  if not i then return nil end
  local data = handle_registry[i.pid]
  if not data then
    data = { handles = {}, vars = i.vars, io = {} }
    handle_registry[i.pid] = data
  end
  return {
    pid = i.pid,
    command = i.name,
    path = "/bin/" .. i.name,
    parent = i.parent,
    pgid = i.pgid,
    uid = i.uid, euid = i.euid, gid = i.gid, egid = i.egid,
    data = data,
  }
end

function process.addHandle(handle, proc)
  if type(handle) ~= "table" then error("bad argument #1 (expected table)") end
  if proc ~= nil and type(proc) ~= "table" then error("bad argument #2 (expected table or nil)") end
  local p = proc or process.info()
  local pid = p.pid
  if not handle_registry[pid] then
    handle_registry[pid] = { handles = {}, vars = {} }
  end
  local handles = handle_registry[pid].handles
  local _close = handle.close
  table.insert(handles, handle)
  function handle:close(...)
    if _close then
      self.close = _close
      _close = nil
      process.removeHandle(self, proc)
      return self:close(...)
    end
  end
  return handle
end

function process.removeHandle(handle, proc)
  if type(handle) ~= "table" then error("bad argument #1 (expected table)") end
  local p = proc or process.info()
  local pid = p.pid
  local handles = handle_registry[pid] and handle_registry[pid].handles
  if not handles then return end
  for pos, h in ipairs(handles) do
    if h == handle then
      return table.remove(handles, pos)
    end
  end
end

function process.findProcess(id)
  if id == nil then return process.info() end
  for _, p in ipairs(freax.ps()) do
    if p.name == id or p.pid == id or tostring(p.pid) == tostring(id) then return p end
  end
  return nil
end

function process.running(level)
  local info = process.info()
  if info then
    return info.path, nil, info.command
  end
end

-- Freax's scheduler is a fixed round-robin; there are no priority levels.
function process.setPriority(pid, priority)
  return nil, "process priorities are not supported"
end

process.list = setmetatable({}, {
  __pairs = function()
    local acc = {}
    for _, p in ipairs(freax.ps()) do
      local data = handle_registry[p.pid] or { handles = {} }
      acc[#acc + 1] = {
        pid = p.pid,
        command = p.name,
        path = "/bin/" .. p.name,
        parent = p.parent,
        pgid = p.pgid,
        uid = p.uid, euid = p.euid, gid = p.gid, egid = p.egid,
        data = data,
      }
    end
    local i = 0
    return function()
      i = i + 1
      return acc[i]
    end
  end,
})

return process
