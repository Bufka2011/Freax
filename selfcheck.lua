-- selfcheck: in-game smoke test, run via `lua /selfcheck.lua`
local checks, skips = 0, 0
local currentSection = "startup"

local function section(name)
  currentSection = name
  io.write("\n== " .. name .. " ==\n")
end

local function skip(name, reason)
  skips = skips + 1
  io.write("SKIP " .. name .. ": " .. reason .. "\n")
end

local function check(n, c)
  checks = checks + 1
  if not c then
    -- root may be read-only (uninstalled media): try tmp too.
    for _, p in ipairs({ "/tmp/s_fail.txt", "/s_fail.txt" }) do
      local ff = io.open(p, "w")
      if ff then ff:write(n) ff:close() break end
    end
    io.stderr:write("FAIL [" .. currentSection .. "] " .. n .. "\n")
    os.exit(1)
  end
end

-- memory accounting: freeMemory delta per require tells us which lib is
-- worth optimizing (harmless if freax.freeMem is absent)
local fm = freax and freax.freeMem
local freeStart = fm and fm() or nil
section("libraries and shell")
if freeStart then io.write("free before requires: " .. tostring(freeStart) .. " bytes\n") end
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
local sh = require("sh")
local completions = sh.complete("lua /self")
check("path completion", #completions == 1 and completions[1] == "/selfcheck.lua")
local shellContext = sh.newContext("probe", {"one", "two words"})
check("shell positional", sh.expand("$0:$1:${2}:$#", shellContext)
  == "probe:one:two words:2")
local parsed = sh.parseScript({
  "if ls /; then", "for x in \"$@\"; do", "echo $x", "done", "fi",
})
check("shell compound parse", parsed and parsed[1] and parsed[1].kind == "if"
  and parsed[1].body[1] and parsed[1].body[1].kind == "for")
local _, _, shellIncomplete = sh.parseScript({"if ls /; then"})
check("shell incomplete parse", shellIncomplete == true)
local freeAfterRequires = fm and fm() or nil

section("threads and events")
local event = require("event")
local thread = require("thread")
local log = {}
local timerCalls = 0
event.timer(0.05, function() timerCalls = timerCalls + 1 end, 1)
local t1 = thread.create(function()
  log[#log + 1] = "a"
  thread.sleep(0.2)
  log[#log + 1] = "b"
end)
check("join", thread.join(t1, 5) == true)
check("order", table.concat(log, ",") == "a,b")
check("status", thread.status(t1) == "dead")
check("thread timer", timerCalls == 1)

section("filesystem and io")
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
  skip("io write", "no writable tmp")
end

section("shell scripts")
local shellScript = "/tmp/s_sc_shell.sh"
local shellResult = "/tmp/s_sc_shell.txt"
local shellMatch = "/tmp/s_sc_shell_match.txt"
local shellBuiltin = "/tmp/s_sc_shell_builtin.txt"
local scriptFile = io.open(shellScript, "w")
if scriptFile then
  scriptFile:write('echo "$#:$1:$2" > ', shellResult, '\n')
  scriptFile:write('for x in "$@"; do\n')
  scriptFile:write('  echo "x=$x" >> ', shellResult, '\n')
  scriptFile:write('done\n')
  scriptFile:write('if grep "two words" ', shellResult, ' > ', shellMatch, '; then\n')
  scriptFile:write('  echo yes >> ', shellResult, '\n')
  scriptFile:write('else\n  echo no >> ', shellResult, '\nfi\n')
  scriptFile:write('cd /tmp && pwd > ', shellBuiltin, '\n')
  scriptFile:close()
  local shellPid = freax.spawn("selfcheck-sh", "/bin/sh.lua",
    {shellScript, "one", "two words"})
  check("shell script spawn", type(shellPid) == "number")
  check("shell script status", freax.wait(shellPid) == 0)
  local resultFile = io.open(shellResult, "r")
  local resultData = resultFile and resultFile:read("*a") or nil
  if resultFile then resultFile:close() end
  check("shell script output", resultData
    == "2:one:two words\nx=one\nx=two words\nyes\n")
  local builtinFile = io.open(shellBuiltin, "r")
  local builtinData = builtinFile and builtinFile:read("*a") or nil
  if builtinFile then builtinFile:close() end
  check("shell builtin status", builtinData == "/tmp\n")
  local exitPid = freax.spawn("selfcheck-sh-exit", "/bin/sh.lua", {"-c", "exit 7"})
  check("shell exit status", exitPid and freax.wait(exitPid) == 7)
  os.remove(shellScript)
  os.remove(shellResult)
  os.remove(shellMatch)
  os.remove(shellBuiltin)
else
  skip("shell scripts", "no writable tmp")
end

section("processes and signals")
local computer = require("computer")
check("uptime", computer.uptime() >= 0)
check("kill-unknown", freax.kill(99999) == nil)

check("getuid", type(freax.getuid) == "function" and type(freax.getuid()) == "number")
check("geteuid", type(freax.geteuid) == "function" and type(freax.geteuid()) == "number")

-- process groups and signals: fresh spawns lead their own group
check("pgid-fns", type(freax.getpgid) == "function" and type(freax.setpgid) == "function")
local selfPid = freax.getpid()
check("pgid-self", freax.getpgid() == selfPid)
check("setpgid-self", freax.setpgid(selfPid, selfPid) == true)
check("kill-exists", freax.kill(selfPid, 0) == true)
check("kill-group-exists", freax.kill(-selfPid, 0) == true)
local sleeper = freax.spawn("sc-sleep", "/bin/sleep.lua", {"30"})
check("spawn-sleeper", type(sleeper) == "number")
if sleeper then
  check("pgid-child", freax.getpgid(sleeper) == sleeper)
  check("stop-child", freax.kill(sleeper, "STOP") == true)
  local stoppedSeen = false
  for _, p in ipairs(freax.ps()) do
    if p.pid == sleeper and (p.stopped or p.state == "stopped") then stoppedSeen = true end
  end
  check("stopped-state", stoppedSeen)
  check("cont-child", freax.kill(sleeper, "CONT") == true)
  check("kill-term", freax.kill(sleeper, "TERM") == true)
  check("wait-term", freax.wait(sleeper) == 143)
end

-- credential boundary: a UID 1000 session must be confined to its home and
-- /tmp/u1000, must not read /etc/shadow, write /etc, mount, or kill PID 1.
section("credential boundary")
if freax.geteuid() ~= 0 or type(freax.spawnAs) ~= "function" then
  skip("credential boundary", "needs root")
elseif not freax.fsMakeDir("/tmp/u1000") and not freax.fsIsDir("/tmp/u1000") then
  skip("credential boundary", "no writable tmp")
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
    skip("credential boundary", "no writable tmp: " .. tostring(perr))
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

section("commands and timeouts")
check("fdcount-self", type(freax.fdCount) == "function"
  and type(freax.fdCount(freax.getpid())) == "number")

for _, c in ipairs({"list /", "components", "lshw", "address",
  "primary gpu", "resolution", "wget", "pastebin", "df", "mount",
  "apt version"}) do
  check("exec " .. c, os.execute(c) == true)
end
local execOk, execWhy, execCode = os.execute("ls /selfcheck-no-such-file")
check("exec status", execOk == nil and execWhy == "exit" and execCode == 1)

local pullStart = freax.uptime()
check("event timeout", event.pull(0.1, "selfcheck-never") == nil
  and freax.uptime() - pullStart >= 0.09
  and freax.uptime() - pullStart < 1)

local o = io.open((os.tmpname() or "/tmp/s_compat.txt"), "w")
if o then o:write("OK") o:close() end

local freeFinal = fm and fm() or nil
if freeStart and freeAfterRequires and freeFinal then
  io.write(string.format("\nmemory: start=%d after_requires=%d final=%d require_delta=%+d final_delta=%+d\n",
    freeStart, freeAfterRequires, freeFinal,
    freeAfterRequires - freeStart, freeFinal - freeStart))
else
  io.write("\nmemory: unavailable\n")
end
os.remove("/tmp/s_fail.txt")
os.remove("/s_fail.txt")
io.write(string.format("PASS selfcheck: %d checks, %d skips\n", checks, skips))
