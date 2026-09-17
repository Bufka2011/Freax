-- process: minimal introspection over the Freax process table (M2 compat).
-- No cross-process signaling or shared-memory threads by design;
-- see freax.spawn/wait for the Freax-native model.
local freax = freax

local process = {}

function process.info()
  local i = freax.myInfo()
  return {
    pid = i.pid,
    command = i.name,
    path = "/bin/" .. i.name,
    data = { vars = i.vars },
  }
end

process.list = setmetatable({}, {
  __pairs = function()
    local acc = {}
    for _, p in ipairs(freax.ps()) do
      acc[#acc + 1] = { pid = p.pid, command = p.name, data = {} }
    end
    local i = 0
    return function()
      i = i + 1
      return acc[i]
    end
  end,
})

function process.findProcess(name)
  for _, p in ipairs(freax.ps()) do
    if p.name == name or p.pid == name then return p end
  end
  return nil
end

return process
