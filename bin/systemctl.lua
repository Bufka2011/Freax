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
  local list = fs.list("/etc/systemd") or {}
  for _, f in ipairs(list) do
    local data = fs.readFile("/etc/systemd/" .. f) or ""
    local name = f:match("(.+)%.[^.]+$") or f
    local desc = data:match("[Dd]escription%s*=%s*([^\n]+)")
    local enabled = data:match("[Ee]nabled%s*=%s*([^\n]+)")
    io.write(string.format("%-20s %-15s %s\n", name, enabled or "", desc or ""))
  end
  return
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
  if data then
    rsp = data
    fs.remove(rspFile)
    break
  end
  freax.sleep(0.1)
end

if cmd == "status" then
  io.write(rsp or name .. " not responding (systemd running?)\n")
else
  io.write(rsp or "timeout\n")
end
