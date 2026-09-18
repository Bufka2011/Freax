-- selfcheck: runs inside Freax via `lua /selfcheck.lua` (dev tool, not installed)
local function check(n, c)
  if not c then
    local ff = io.open("/s_fail.txt", "w")
    if ff then ff:write(n) ff:close() end
    io.stderr:write("FAIL " .. n .. "\n")
    os.exit(1)
  end
end

for _, m in ipairs({"text","transforms","colors","vt100","note","pipe",
  "process","package","io","os","buffer","internet","eeprom","rs","thread",
  "serialization","uuid","sides","event","keyboard","tty","filesystem",
  "fs","shell","term","computer"}) do
  local ok, mod = pcall(require, m)
  check("require " .. m, ok and mod)
end
if bit32 then
  check("require bit32", pcall(require, "bit32"))
end
check("padRight", require("text").padRight("ab", 4) == "ab  ")
if bit32 then
  check("uuid shape", require("uuid").next():len() == 36)
end
local ser = require("serialization")
check("ser roundtrip", ser.unserialize(ser.serialize({a = 1})).a == 1)
check("sides", require("sides").north == 2)

local thread = require("thread")
local log = {}
local t1 = thread.create(function()
  log[#log + 1] = "a"
  thread.sleep(0.2)
  log[#log + 1] = "b"
end)
check("join", thread.join(t1, 5) == true)
check("order", table.concat(log, ",") == "a,b")
check("status", thread.status(t1) == "dead")

-- symlink cycles must error, never hang (ln refuses to make them,
-- so build directly through the syscalls)
check("link", freax.fsLink("/bin/ls.lua", "/sc_l1"))
check("link-follow", (io.open("/sc_l1", "r"):read("*a") or "") ~= "")
check("link-cycle-a", freax.fsLink("/sc_cyc2", "/sc_cyc1"))
check("link-cycle-b", freax.fsLink("/sc_cyc1", "/sc_cyc2"))
local cycData, cycErr = io.open("/sc_cyc1", "r")
if cycData then cycData:close() end
check("cycle-errors", cycData == nil and cycErr
  and (cycErr:find("cycle", 1, true) or cycErr:find("levels", 1, true)))
check("cycle-clean1", freax.fsRemove("/sc_cyc1"))
check("cycle-clean2", freax.fsRemove("/sc_cyc2"))
check("unlink-keeps-target", freax.fsRemove("/sc_l1")
  and freax.fsExists("/bin/ls.lua"))

check("PATH", os.getenv("PATH") ~= nil)
local f = io.open("/s_io.txt", "w")
f:write("x")
f:close()
check("io", io.open("/s_io.txt", "r"):read("*a") == "x")
os.remove("/s_io.txt")
local computer = require("computer")
check("uptime", computer.uptime() >= 0)
check("kill-unknown", freax.kill(99999) == nil)

for _, c in ipairs({"list /", "components", "lshw", "address",
  "primary gpu", "redstone", "flash", "label /", "resolution",
  "wget", "pastebin", "dmesg", "df", "mount"}) do
  check("exec " .. c, os.execute(c) == true)
end

local o = io.open("/s_compat.txt", "w")
o:write("OK")
o:close()
