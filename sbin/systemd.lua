-- systemd: service manager daemon.
-- Reads /etc/systemd/*.unit, starts services, monitors them.
-- IPC via command files in /run/systemd/, written by systemctl.
-- Usage: systemd
--   systemd checks /run/systemd/ctl.<action>.<name> each cycle,
--   writes response to /run/systemd/rsp.<name>.
-- Actions: start, stop, restart, enable, disable, status.

local fs = require("fs")
local shell = require("shell")

local CTRL = "/run/systemd"
local RUN_DIR = CTRL
local function mkdirP(p)
  local parts = {}
  for seg in p:gmatch("[^/]+") do parts[#parts + 1] = seg end
  local cur = ""
  for _, seg in ipairs(parts) do
    cur = cur .. "/" .. seg
    if not fs.exists(cur) then fs.makeDirectory(cur) end
  end
end
mkdirP(CTRL)
mkdirP("/var/log/systemd")

-- Mount tmpfs at /run/ if available (ephemeral storage for IPC).
local tmpAddr = freax.tmpAddr()
if tmpAddr then
  local ok, err = freax.fsMount(tmpAddr, "/run")
  if ok then mkdirP(CTRL) end
end

-- load unit files from /etc/systemd/*.unit
local units = {}
local function loadUnits()
  local list = fs.list("/etc/systemd") or {}
  for _, name in ipairs(list) do
    local path = "/etc/systemd/" .. name
    local data = fs.readFile(path)
    if data then
      local u = { name = name:match("(.+)%.[^.]+$") or name, file = path }
      for line in data:gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1,1) ~= "#" and line:sub(1,1) ~= "[" then
          local k, v = line:match("^([^=]+)=(.*)$")
          if k and v then
            k = k:match("^%s*(.-)%s*$")
            v = v:match("^%s*(.-)%s*$")
            u[k] = v
          end
        end
      end
      if u.exec then units[u.name] = u end
    end
  end
end
loadUnits()

-- running services: name -> { pid, status, unit }
local services = {}

local function ensureDir(path)
  local parent = fs.dir(path)
  if parent and parent ~= "/" and parent ~= "" then
    if not fs.exists(parent) then fs.makeDirectory(parent) end
  end
end

local function log(unit, msg)
  local fd = fs.open("/var/log/systemd/" .. unit .. ".log", "a")
  if fd then
    fs.write(fd, string.format("[%.1f] %s\n", freax.uptime(), msg))
    fs.close(fd)
  end
end

local function startUnit(name)
  local u = units[name]
  if not u then return nil, "no such unit" end
  local s = services[name]
  if s and s.status == "running" then return true end

  -- dependencies
  if u.after then
    for dep in u.after:gmatch("[^,]+") do
      dep = dep:match("^%s*(.-)%s*$")
      if dep ~= "" then
        local ok, err = startUnit(dep)
        if not ok then return nil, "dependency " .. dep .. ": " .. tostring(err) end
      end
    end
  end

  local pid = freax.spawn(u.name, u.exec, {})
  if not pid then return nil, "spawn failed" end
  services[name] = { pid = pid, status = "running", unit = u }
  log(name, "started (pid " .. pid .. ")")
  return true
end

local function stopUnit(name)
  local s = services[name]
  if not s then return nil, "not loaded" end
  if s.status ~= "running" then return true end
  freax.kill(s.pid)
  s.status = "stopped"
  s.pid = nil
  log(name, "stopped")
  return true
end

local function restartUnit(name)
  stopUnit(name)
  return startUnit(name)
end

-- enable/disable: toggle enabled= flag in unit file
local function setEnabled(name, on)
  local u = units[name]
  if not u then return nil, "no such unit" end
  local data = fs.readFile(u.file) or ""
  local lines = {}
  local found = false
  for line in (data .. "\n"):gmatch("(.-)\n") do
    if line:match("^%s*[Ee]nabled%s*=") then
      lines[#lines + 1] = "enabled=" .. (on and "yes" or "no")
      found = true
    else
      lines[#lines + 1] = line
    end
  end
  if not found then lines[#lines + 1] = "enabled=" .. (on and "yes" or "no") end
  local fd = fs.open(u.file, "w")
  if not fd then return nil, "cannot write unit" end
  for _, line in ipairs(lines) do fs.write(fd, line .. "\n") end
  fs.close(fd)
  u.enabled = on and "yes" or "no"
  log(name, on and "enabled" or "disabled")
  return true
end

-- start enabled units at boot
for _, u in pairs(units) do
  if u.enabled == "yes" then
    local ok, err = startUnit(u.name)
    if not ok then log(u.name, "boot start failed: " .. tostring(err)) end
  end
end

log("systemd", "started (" .. (next(units) and #services .. " services" or "no units") .. ")")

-- fallback: no units enabled -> boot login directly
if not units or not next(units) then
  local fallback = { "/bin/login.lua", "/bin/sh.lua" }
  for _, path in ipairs(fallback) do
    local pid = freax.spawn("console", path, {})
    if pid then
      services["console"] = { pid = pid, status = "running", unit = { name = "console", exec = path, description = "Console login", restart = "always" } }
      log("systemd", "fallback: spawned " .. path)
      break
    end
  end
end

-- main loop
while true do
  -- poll for commands
  local list = fs.list(CTRL) or {}
  for _, f in ipairs(list) do
    local action, name = f:match("^ctl%.([^.]+)%.(.+)$")
    if action and name then
      local rsp
      if action == "start" then
        local ok, err = startUnit(name)
        rsp = ok and "ok" or tostring(err)
      elseif action == "stop" then
        local ok, err = stopUnit(name)
        rsp = ok and "ok" or tostring(err)
      elseif action == "restart" then
        local ok, err = restartUnit(name)
        rsp = ok and "ok" or tostring(err)
      elseif action == "enable" then
        local ok, err = setEnabled(name, true)
        rsp = ok and "ok" or tostring(err)
      elseif action == "disable" then
        local ok, err = setEnabled(name, false)
        rsp = ok and "ok" or tostring(err)
      elseif action == "status" then
        local s = services[name]
        local lines = {}
        if name == "all" then
        local lines = {}
        for _, u in pairs(units) do
          local s = services[u.name]
          local st = (s and s.status) or "stopped"
          local en = (u.enabled == "yes") and "enabled" or "disabled"
          lines[#lines + 1] = string.format("%-16s %-8s %s (%s)", u.name, st, u.description or "", en)
        end
        if #lines == 0 then lines[#lines + 1] = "no units loaded" end
        rsp = table.concat(lines, "\n")
      elseif name == "systemd" then
          lines[#lines + 1] = "systemd (daemon) running"
        elseif s then
          lines[#lines + 1] = name .. " " .. (s.status or "unknown")
          if s.pid then lines[#lines + 1] = "  pid: " .. s.pid end
          local u = s.unit
          if u then
            if u.description then lines[#lines + 1] = "  desc: " .. u.description end
            if u.restart then lines[#lines + 1] = "  restart: " .. u.restart end
          end
        else
          lines[#lines + 1] = name .. " not found"
        end
        rsp = table.concat(lines, "\n")
      else
        rsp = "unknown action: " .. action
      end
      -- write response
      local fd = fs.open(RUN_DIR .. "/rsp." .. action .. "." .. name, "w")
      if fd then fs.write(fd, rsp or "ok") fs.close(fd) end
      -- remove command file
      fs.remove(CTRL .. "/" .. f)
    end
  end

  -- poll managed PIDs, restart dead services as configured
  local all = freax.ps()
  local pidMap = {}
  for _, p in ipairs(all) do pidMap[p.pid] = p end
  for name, s in pairs(services) do
    if s.status == "running" and s.pid then
      local p = pidMap[s.pid]
      if not p or p.dead then
        log(name, "exited (pid " .. s.pid .. ")")
        s.status = "exited"
        s.pid = nil
        local u = s.unit
        if u and (u.restart == "always" or u.restart == "on-failure") then
          log(name, "restarting")
          local pid = freax.spawn(name, u.exec, {})
          if pid then s.pid = pid s.status = "running" end
        end
      end
    end
  end

  freax.sleep(0.5)
end