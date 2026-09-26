-- component: OpenOS compatibility bridge over freax.* syscalls.
--
-- Freax sandboxes hardware behind freax.* on purpose, so `component` used
-- to be a stub that errored. This shim re-exposes the components Freax
-- already mediates (gpu, screen, keyboard, filesystem, internet,
-- computer, eeprom) in the OpenOS shape, so existing programs can run
-- unchanged. It is not a full component bus: unknown types get an empty
-- proxy, and unsupported methods are simply absent.

local component = {}

local function deviceMap(filter)
  local out = {}
  for _, d in ipairs(freax.devices(filter)) do
    out[d.address] = d.type
  end
  return out
end

function component.list(filter)
  local map = deviceMap(filter)
  return setmetatable(map, {
    __call = function(t, _, key)
      return next(t, key)
    end,
  })
end

function component.isAvailable(typ)
  if typ == "gpu" then return freax.primary("gpu") ~= nil end
  if typ == "filesystem" then return true end
  if typ == "computer" then return true end
  if typ == "internet" then return freax.netAvail() end
  if typ == "eeprom" then return freax.eepromAddr() ~= nil end
  if typ == "screen" or typ == "keyboard" then
    return freax.primary("gpu") ~= nil
  end
  return next(deviceMap(typ)) ~= nil
end

local function listIter(t)
  local keys, i = {}, 0
  for k in pairs(t) do keys[#keys + 1] = k end
  return function()
    i = i + 1
    local k = keys[i]
    if k then return t[k] end
  end
end

-- Wrap each method so both `proxy.method(args)` (OpenOS dot style) and
-- `proxy:method(args)` (colon style) work.
local function method(p, fn)
  return function(a, ...)
    if a == p then return fn(...) end
    return fn(a, ...)
  end
end

local function makeProxy(typ, addr)
  local p = { type = typ, address = addr }
  local m = {}
  if typ == "gpu" then
    m = {
      set = function(x, y, s) return freax.gpuSet(x, y, s) end,
      get = function(x, y) return freax.gpuGet(x, y) end,
      fill = function(x, y, w, h, c) return freax.gpuFill(x, y, w, h, c) end,
      copy = function(x, y, w, h, dx, dy) return freax.gpuCopy(x, y, w, h, dx, dy) end,
      getResolution = function() return freax.gpuSize() end,
      maxResolution = function() return freax.gpuMaxResolution() end,
      setResolution = function(w, h) return freax.gpuSetResolution(w, h) end,
      setForeground = function(c, pal) return freax.ttySetForeground(c, pal) end,
      setBackground = function(c, pal) return freax.ttySetBackground(c, pal) end,
      getForeground = function() return freax.ttyGetForeground() end,
      getBackground = function() return freax.ttyGetBackground() end,
      getDepth = function() return 8 end,
      setDepth = function() return true end,
      getPaletteColor = function() return 0 end,
      setPaletteColor = function() return true end,
    }
  elseif typ == "screen" then
    m = {
      isOn = function() return true end,
      turnOn = function() return true end,
      turnOff = function() return true end,
      getResolution = function() return freax.gpuSize() end,
      getAspectRatio = function()
        local w, h = freax.gpuSize()
        return (h ~= 0) and (w / h) or 1
      end,
      getKeyboards = function()
        local k = freax.primary("keyboard")
        return k and { k } or {}
      end,
      isPrecise = function() return false end,
      setPrecise = function() return true end,
      getTouchMode = function() return 0 end,
      setTouchMode = function() return true end,
      getTouchModeInverted = function() return false end,
      setTouchModeInverted = function() return true end,
    }
  elseif typ == "keyboard" then
    m = {
      isKeyDown = function() return false end,
      getKeyName = function() return nil end,
      setKeyDown = function() return true end,
    }
  elseif typ == "filesystem" then
    m = {
      exists = function(path) return freax.fsExists(path) end,
      isDirectory = function(path) return freax.fsIsDir(path) end,
      size = function(path) return freax.fsSize(path) end,
      lastModified = function(path) return freax.fsLastModified(path) end,
      list = function(path) return listIter(freax.fsList(path) or {}) end,
      makeDirectory = function(path) return freax.fsMakeDir(path) end,
      remove = function(path) return freax.fsRemove(path) end,
      rename = function(a, b) return freax.fsRename(a, b) end,
      open = function(path, mode) return freax.fsOpen(path, mode) end,
      read = function(h, n) return freax.fsRead(h, n) end,
      write = function(h, d) return freax.fsWrite(h, d) end,
      close = function(h) return freax.fsClose(h) end,
      getLabel = function() return freax.fsLabel(addr) end,
      setLabel = function(l) return freax.fsSetLabel(addr, l) end,
      isReadOnly = function() return freax.fsIsReadOnly("/") end,
      spaceTotal = function() return 0 end,
      spaceUsed = function() return 0 end,
    }
  elseif typ == "internet" then
    m = {
      request = function(...) return require("internet").request(...) end,
    }
  elseif typ == "computer" then
    m = {
      address = function() return computer.address() end,
      tmpAddress = function() return computer.tmpAddress() end,
      freeMemory = function() return computer.freeMemory() end,
      totalMemory = function() return computer.totalMemory() end,
      uptime = function() return computer.uptime() end,
      getDeviceInfo = function() return computer.getDeviceInfo() or {} end,
      beep = function(...) return computer.beep(...) end,
      shutdown = function(reboot) return computer.shutdown(reboot) end,
      pushSignal = function() return nil, "not supported" end,
    }
  elseif typ == "eeprom" then
    local eeprom = require("eeprom")
    m = {
      get = function() return eeprom.get() end,
      set = function(d) return eeprom.set(d) end,
      getData = function() return eeprom.get() end,
      setData = function(d) return eeprom.set(d) end,
      getLabel = function() return eeprom.getLabel() end,
      setLabel = function(l) return eeprom.setLabel(l) end,
      getSize = function() return eeprom.getSize() end,
      getChecksum = function() return nil end,
    }
  end
  for k, fn in pairs(m) do p[k] = method(p, fn) end
  return p
end

function component.getPrimary(typ)
  local addr
  if typ == "computer" then addr = freax.machineAddr()
  elseif typ == "eeprom" then addr = freax.eepromAddr()
  else addr = freax.primary(typ) end
  if not addr then
    for a in pairs(deviceMap(typ)) do addr = a break end
  end
  return makeProxy(typ, addr)
end

function component.proxy(addr)
  local typ
  for a, t in pairs(deviceMap()) do
    if a == addr then typ = t break end
  end
  if not typ then return nil, "no such component" end
  return makeProxy(typ, addr)
end

function component.get(addr)
  local ok, px = pcall(component.proxy, addr)
  return ok and px or nil
end

function component.methods(addr)
  local px = component.proxy(addr)
  local out = {}
  if px then for k in pairs(px) do out[k] = true end end
  return out
end

setmetatable(component, {
  __index = function(_, k)
    if k == "gpu" or k == "screen" or k == "keyboard" or k == "filesystem"
      or k == "internet" or k == "computer" or k == "eeprom" then
      return component.getPrimary(k)
    end
    return nil
  end,
})

return component
