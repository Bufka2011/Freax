-- systemctl: control systemd services.
-- Usage: systemctl <command> [name]
-- Commands: start stop restart status enable disable list-units
-- Communicates with systemd via /run/systemd/ctl.* files.

local shell = require("shell")
local fs = require("fs")
local args, opts = shell.parse(...)
local cmd = args[1]
local name = args[2]

local CTRL = "/run/systemd"
local CMD_PFX = CTRL .. "/ctl"
local RSP_PFX = CTRL .. "/rsp"

local function readUnits()
  local units = {}
  for _, file in ipairs(fs.list("/etc/systemd") or {}) do
    if file:match("%.unit$") and not fs.isDirectory("/etc/systemd/" .. file) then
      local data = fs.readFile("/etc/systemd/" .. file) or ""
      units[#units + 1] = {
        name = file:sub(1, -6),
        description = data:match("[Dd]escription%s*=%s*([^\n]+)"),
        enabled = data:match("[Ee]nabled%s*=%s*([^\n]+)"),
      }
    end
  end
  table.sort(units, function(a, b) return a.name < b.name end)
  return units
end

if not cmd or cmd == "help" or opts.help then
  io.write("Usage: systemctl <command> [name]\n")
  io.write("Commands:\n")
  io.write("  start NAME       start a service\n")
  io.write("  stop NAME        stop a service\n")
  io.write("  restart NAME     restart a service\n")
  io.write("  status [NAME]    show service status\n")
  io.write("  enable NAME      enable service at boot\n")
  io.write("  disable NAME     disable service at boot\n")
  io.write("  list-units       list all units\n")
  io.write("  daemon-reload    reload unit files\n")
  return
end

if cmd == "list-units" then
  for _, unit in ipairs(readUnits()) do
    io.write(string.format("%-20s %-15s %s\n", unit.name,
      unit.enabled or "", unit.description or ""))
  end
  return
end

if freax.geteuid() ~= 0 then
  io.stderr:write("systemctl: " .. cmd .. " requires root\n")
  return 1
end

if cmd == "status" and not name then
  local live = {}
  for _, process in ipairs(freax.ps()) do
    if not process.dead then live[process.name] = true end
  end
  local units = readUnits()
  for _, unit in ipairs(units) do
    io.write(string.format("%-16s %-8s %s (%s)\n", unit.name,
      live[unit.name] and "running" or "stopped", unit.description or "",
      unit.enabled == "yes" and "enabled" or "disabled"))
  end
  if #units == 0 then io.write("no units loaded\n") end
  return 0
end

if cmd == "daemon-reload" then cmd, name = "reload", "systemd" end

if not name and cmd ~= "status" then
  io.write("Usage: systemctl " .. cmd .. " NAME\n")
  return 1
end

-- write command file
local subj = name or (cmd == "status" and "all" or "")
local ctlFile = CMD_PFX .. "." .. cmd .. "." .. subj
local rspFile = RSP_PFX .. "." .. cmd .. "." .. subj

fs.remove(rspFile)
local fd = fs.open(ctlFile, "w")
if not fd then
  io.write("error: cannot write " .. ctlFile .. " (systemd running?)\n")
  return 1
end
fs.close(fd)

-- wait for response (poll up to ~5s)
local rsp, deadline = nil, freax.uptime() + 5
while freax.uptime() < deadline do
  local data = fs.readFile(rspFile)
  if data and #data > 0 then
    rsp = data
    fs.remove(rspFile)
    break
  end
  freax.sleep(0.1)
end

local output = rsp
if not output then
  output = cmd == "status"
    and ((name or "systemd") .. " not responding (systemd running?)")
    or "timeout"
end
io.write(output:gsub("\n*$", "") .. "\n")
if not rsp then return 1 end
if cmd ~= "status" and rsp ~= "ok" then return 1 end
