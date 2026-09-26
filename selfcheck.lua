-- selfcheck: in-game smoke test, run via `lua /selfcheck.lua`
local function check(n, c)
  if not c then
    -- root may be read-only (uninstalled media): try tmp too.
    for _, p in ipairs({ "/tmp/s_fail.txt", "/s_fail.txt" }) do
      local ff = io.open(p, "w")
      if ff then ff:write(n) ff:close() break end
    end
    io.stderr:write("FAIL " .. n .. "\n")
    os.exit(1)
  end
end

-- memory accounting: freeMemory delta per require tells us which lib is
-- worth optimizing (harmless if freax.freeMem is absent)
local fm = freax and freax.freeMem
if fm then io.write("free before requires: " .. tostring(fm()) .. " bytes\n") end
for _, m in ipairs({"text","transforms","colors","note","pipe",
  "process","package","io","os","buffer","internet","eeprom","rs","thread",
  "serialization","uuid","sides","event","keyboard","tty","filesystem",
  "fs","shell","term","computer"}) do
  local before = fm and fm() or 0
  local ok, mod = pcall(require, m)
  if fm then io.write(string.format("  %-12s %+d bytes\n", m, fm() - before)) end
  -- include the loader error: "FAIL require X" alone cannot separate
  -- missing-file from load-error (e.g. vt100/note/uuid rounds).
  check("require " .. m .. ((ok and mod) and "" or (": " .. tostring(mod))), ok and mod)
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
-- root is read-only on uninstalled media; use tmp so this still tests io
local tmp = os.tmpname() or "/tmp/s_io.txt"
local f = io.open(tmp, "w")
if f then
  f:write("x")
  f:close()
  check("io", io.open(tmp, "r"):read("*a") == "x")
  os.remove(tmp)
else
  io.write("skip io write test (no writable tmp)\n")
end
local computer = require("computer")
check("uptime", computer.uptime() >= 0)
check("kill-unknown", freax.kill(99999) == nil)

check("getuid", type(freax.getuid) == "function" and type(freax.getuid()) == "number")
check("geteuid", type(freax.geteuid) == "function" and type(freax.geteuid()) == "number")

-- credential boundary: a UID 1000 session must be confined to its home and
-- /tmp/u1000, must not read /etc/shadow, write /etc, mount, or kill PID 1.
if freax.geteuid() ~= 0 or type(freax.spawnAs) ~= "function" then
  io.write("skip credential boundary test (needs root)\n")
elseif not freax.fsMakeDir("/tmp/u1000") and not freax.fsIsDir("/tmp/u1000") then
  io.write("skip credential boundary test (no writable tmp)\n")
else
  local probe = [[
local out = {}
local function rec(k, v) out[#out + 1] = k .. "=" .. tostring(v) end
rec("uid", freax.getuid())
rec("euid", freax.geteuid())
local s = io.open("/etc/shadow", "r")
rec("shadow", s and "readable" or "denied")
if s then s:close() end
local e = io.open("/etc/s_sc_nr.txt", "w")
rec("etcwrite", e and "allowed" or "denied")
if e then e:close() os.remove("/etc/s_sc_nr.txt") end
local t = io.open("/tmp/u1000/s_sc_nr.txt", "w")
rec("tmpwrite", t and "allowed" or "denied")
if t then t:close() end
local m = freax.fsMount("0", "/mnt/sc_nr")
rec("mount", m and "allowed" or "denied")
local k = freax.kill(1)
rec("kill-init", k and "allowed" or "denied")
local a = freax.spawnAs("selfcheck-escalate", "/bin/ls.lua", {}, 0, 0, "/tmp/u1000")
rec("spawnas", a and "allowed" or "denied")
local w = freax.wait(1)
rec("wait-init", (w == nil) and "denied" or "allowed")
local r = io.open("/tmp/u1000/result.txt", "w")
if r then r:write(table.concat(out, "\n")) r:close() end
return 0
]]
  local pf = io.open("/tmp/s_sc_nr.lua", "w")
  local pid, perr
  if pf then
    pf:write(probe) pf:close()
    pid, perr = freax.spawnAs("selfcheck-nr", "/tmp/s_sc_nr.lua", {}, 1000, 1000, "/tmp/u1000")
  end
  if not pid then
    io.write("skip credential boundary test (no writable tmp: " .. tostring(perr) .. ")\n")
  else
  freax.wait(pid)
  local res, rerr = io.open("/tmp/u1000/result.txt", "r")
  local data = res and res:read("*a") or nil
  if res then res:close() end
  check("cred-probe-read (" .. tostring(rerr) .. ")", data ~= nil)
  local seen = {}
  for line in (data or ""):gmatch("[^\n]+") do
    local k, v = line:match("^([^=]+)=(.*)$")
    seen[k] = v
  end
  check("cred-uid", seen.uid == "1000" and seen.euid == "1000")
  check("cred-shadow", seen.shadow == "denied")
  check("cred-etc-write", seen.etcwrite == "denied")
  check("cred-tmp-write", seen.tmpwrite == "allowed")
  check("cred-mount", seen.mount == "denied")
  check("cred-kill-init", seen["kill-init"] == "denied")
  check("cred-spawnas", seen.spawnas == "denied")
  check("cred-wait-init", seen["wait-init"] == "denied")
  check("cred-fdcount", type(freax.fdCount) == "function"
    and type(freax.fdCount(freax.getpid())) == "number")
  freax.fsRemove("/tmp/s_sc_nr.lua")
  freax.fsRemove("/tmp/u1000/s_sc_nr.txt")
  freax.fsRemove("/tmp/u1000/result.txt")
  end
end

check("fdcount-self", type(freax.fdCount) == "function"
  and type(freax.fdCount(freax.getpid())) == "number")

for _, c in ipairs({"list /", "components", "lshw", "address",
  "primary gpu", "redstone", "flash", "label /", "resolution",
  "wget", "pastebin", "dmesg", "df", "mount", "apt version"}) do
  check("exec " .. c, os.execute(c) == true)
end

local o = io.open((os.tmpname() or "/tmp/s_compat.txt"), "w")
if o then o:write("OK") o:close() end
