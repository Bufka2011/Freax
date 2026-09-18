-- install: Freax installer (M1).
-- Inspired by OpenOS bin/install + lib/core/install_basics,
-- simplified to Ubuntu-Server style with a Minimal checkbox.
-- Usage: install [--minimal] [--to=ADDR]

local term = require("term")
local fs = require("fs")
local shell = require("shell")

local args, opts = shell.parse(...)
if opts.help then
  term.writeln("Usage: install [--minimal] [--to=ADDR] [--from=ADDR]")
  term.writeln("  Installs Freax to a hard drive.")
  return
end

-- Bug fix 1: start on a clean screen, like Ubuntu Server installer.
term.clear()

local function ask(prompt, def)
  term.write(prompt)
  local line = term.readLine()
  if not line or line == "" then return def end
  return line
end

local devs = fs.devices()

-- Find the installer source media (where install.lua lives).
-- Bug fix 2: never offer the installer floppy itself as a target.
-- Source != necessarily boot: user may boot HDD and run installer from floppy.
local function findInstallerDev()
  if opts.from then
    for _, d in ipairs(devs) do
      if d.addr:sub(1, #opts.from) == opts.from then return d end
    end
  end
  for _, d in ipairs(devs) do
    if d.mount then
      if fs.exists(d.mount .. "/bin/install.lua")
        or fs.exists(d.mount .. "/install.lua") then
        return d
      end
    end
  end
  return nil
end

local installerDev = findInstallerDev()
local bootDev = nil
for _, d in ipairs(devs) do if d.boot then bootDev = d break end end
-- Source is installer media if found, else boot (already-installed system).
local srcDev = installerDev or bootDev

local targets = {}
local skippedTmp = 0
for _, d in ipairs(devs) do
  local isSrc = srcDev and d.addr == srcDev.addr
  local isBoot = d.boot
  if d.readonly then
    -- keep OpenOS behaviour: explicit --to on readonly errors, else skip
    if opts.to and d.addr:sub(1, #opts.to) == opts.to then
      term.writeln("install: target is read-only")
      return
    end
  elseif d.tmp and not (opts.to and d.addr:sub(1, #opts.to) == opts.to) then
    -- RAM disk: contents vanish on reboot, installing there
    -- guarantees "no bootable medium found" afterwards.
    skippedTmp = skippedTmp + 1
  elseif not isSrc and not isBoot then
    targets[#targets + 1] = d
  end
end
-- Explicit --to overrides source/boot exclusion (except readonly above).
if opts.to then
  local forced = nil
  for _, d in ipairs(devs) do
    if d.addr:sub(1, #opts.to) == opts.to then forced = d break end
  end
  if forced then targets = { forced } end
end
if not srcDev then
  term.writeln("install: cannot find source device")
  return
end
if #targets == 0 then
  if skippedTmp > 0 then
    term.writeln("install: only RAM disk(s) found besides source/boot.")
    term.writeln("install: tmpfs is skipped (it wipes on reboot).")
    term.writeln("install: attach a hard drive, or force with --to=ADDR")
  else
    term.writeln("install: no writable target found (need a second HDD)")
  end
  return
end

-- pick target
local target = targets[1]
if opts.to then
  for _, d in ipairs(targets) do
    if d.addr:sub(1, #opts.to) == opts.to then target = d break end
  end
else
  if #targets > 1 then
    term.writeln("Targets:")
    for i, d in ipairs(targets) do
      term.writeln(string.format(" %d) %s label=%s total=%d mount=%s",
        i, d.addr:sub(1, 8), tostring(d.label or ""),
        d.total or 0, tostring(d.mount or "-")))
    end
    local pick = ask("Install to [1]: ", "1")
    target = targets[tonumber(pick) or 1] or targets[1]
  end
end

-- Minimal checkbox (Ubuntu Server style)
local minimal = opts.minimal
if minimal == nil then
  local ans = ask("[ ] Minimal install? (core only) [y/N]: ", "n")
  minimal = ans:sub(1, 1):lower() == "y"
else
  minimal = minimal == true or minimal == "true"
end

-- manifest: {dst, srcCandidates[]}
local function entry(dst, base)
  return { dst = dst, srcs = { dst, "/" .. base, base } }
end
local FULL = {
  entry("/init.lua", "init.lua"),
  entry("/boot/kernel/main.lua", "main.lua"),
  entry("/lib/term.lua", "term.lua"),
  entry("/lib/fs.lua", "fs.lua"),
  entry("/lib/shell.lua", "shell.lua"),
  entry("/lib/event.lua", "event.lua"),
  entry("/lib/keyboard.lua", "keyboard.lua"),
  entry("/lib/tty.lua", "tty.lua"),
  entry("/lib/filesystem.lua", "filesystem.lua"),
  entry("/lib/component.lua", "component.lua"),
  entry("/lib/sides.lua", "sides.lua"),
  entry("/lib/serialization.lua", "serialization.lua"),
  entry("/lib/uuid.lua", "uuid.lua"),
  entry("/lib/text.lua", "text.lua"),
  entry("/lib/transforms.lua", "transforms.lua"),
  entry("/lib/colors.lua", "colors.lua"),
  entry("/lib/vt100.lua", "vt100.lua"),
  entry("/lib/note.lua", "note.lua"),
  entry("/lib/package.lua", "package.lua"),
  entry("/lib/io.lua", "io.lua"),
  entry("/lib/os.lua", "os.lua"),
  entry("/lib/pipe.lua", "pipe.lua"),
  entry("/lib/process.lua", "process.lua"),
  entry("/lib/internet.lua", "internet.lua"),
  entry("/lib/eeprom.lua", "eeprom.lua"),
  entry("/lib/rs.lua", "rs.lua"),
  entry("/lib/thread.lua", "thread.lua"),
  entry("/lib/buffer.lua", "buffer.lua"),
  entry("/lib/auth.lua", "auth.lua"),
  entry("/lib/sha256.lua", "sha256.lua"),
  entry("/etc/motd", "motd"),
  entry("/etc/passwd", "passwd"),
  entry("/etc/shadow", "shadow"),
  entry("/manifest", "manifest"),
  entry("/bin/sh.lua", "sh.lua"),
  entry("/bin/ls.lua", "ls.lua"),
  entry("/bin/cat.lua", "cat.lua"),
  entry("/bin/cp.lua", "cp.lua"),
  entry("/bin/mv.lua", "mv.lua"),
  entry("/bin/mkdir.lua", "mkdir.lua"),
  entry("/bin/rm.lua", "rm.lua"),
  entry("/bin/touch.lua", "touch.lua"),
  entry("/bin/pwd.lua", "pwd.lua"),
  entry("/bin/head.lua", "head.lua"),
  entry("/bin/grep.lua", "grep.lua"),
  entry("/bin/wc.lua", "wc.lua"),
  entry("/bin/sort.lua", "sort.lua"),
  entry("/bin/du.lua", "du.lua"),
  entry("/bin/tree.lua", "tree.lua"),
  entry("/bin/sleep.lua", "sleep.lua"),
  entry("/bin/uptime.lua", "uptime.lua"),
  entry("/bin/dmesg.lua", "dmesg.lua"),
  entry("/bin/which.lua", "which.lua"),
  entry("/bin/printenv.lua", "printenv.lua"),
  entry("/bin/hostname.lua", "hostname.lua"),
  entry("/bin/df.lua", "df.lua"),
  entry("/bin/mount.lua", "mount.lua"),
  entry("/bin/umount.lua", "umount.lua"),
  entry("/bin/lua.lua", "lua.lua"),
  entry("/bin/date.lua", "date.lua"),
  entry("/bin/free.lua", "free.lua"),
  entry("/bin/time.lua", "time.lua"),
  entry("/bin/yes.lua", "yes.lua"),
  entry("/bin/mktmp.lua", "mktmp.lua"),
  entry("/bin/rmdir.lua", "rmdir.lua"),
  entry("/bin/find.lua", "find.lua"),
  entry("/bin/less.lua", "less.lua"),
  entry("/bin/edit.lua", "edit.lua"),
  entry("/bin/reboot.lua", "reboot.lua"),
  entry("/bin/shutdown.lua", "shutdown.lua"),
  entry("/bin/components.lua", "components.lua"),
  entry("/bin/lshw.lua", "lshw.lua"),
  entry("/bin/address.lua", "address.lua"),
  entry("/bin/primary.lua", "primary.lua"),
  entry("/bin/label.lua", "label.lua"),
  entry("/bin/resolution.lua", "resolution.lua"),
  entry("/bin/redstone.lua", "redstone.lua"),
  entry("/bin/flash.lua", "flash.lua"),
  entry("/bin/list.lua", "list.lua"),
  entry("/bin/wget.lua", "wget.lua"),
  entry("/bin/pastebin.lua", "pastebin.lua"),
  entry("/bin/ln.lua", "ln.lua"),
  entry("/bin/man.lua", "man.lua"),
  entry("/bin/login.lua", "login.lua"),
  entry("/bin/passwd.lua", "passwd.lua"),
  entry("/bin/su.lua", "su.lua"),
  entry("/bin/whoami.lua", "whoami.lua"),
  entry("/bin/adduser.lua", "adduser.lua"),
  entry("/usr/man/address", "address"),
  entry("/usr/man/alias", "alias"),
  entry("/usr/man/cat", "cat"),
  entry("/usr/man/cd", "cd"),
  entry("/usr/man/clear", "clear"),
  entry("/usr/man/cp", "cp"),
  entry("/usr/man/date", "date"),
  entry("/usr/man/df", "df"),
  entry("/usr/man/dmesg", "dmesg"),
  entry("/usr/man/echo", "echo"),
  entry("/usr/man/edit", "edit"),
  entry("/usr/man/grep", "grep"),
  entry("/usr/man/head", "head"),
  entry("/usr/man/hostname", "hostname"),
  entry("/usr/man/install", "install"),
  entry("/usr/man/label", "label"),
  entry("/usr/man/less", "less"),
  entry("/usr/man/ln", "ln"),
  entry("/usr/man/ls", "ls"),
  entry("/usr/man/lshw", "lshw"),
  entry("/usr/man/lua", "lua"),
  entry("/usr/man/man", "man"),
  entry("/usr/man/mkdir", "mkdir"),
  entry("/usr/man/more", "more"),
  entry("/usr/man/mount", "mount"),
  entry("/usr/man/mv", "mv"),
  entry("/usr/man/pastebin", "pastebin"),
  entry("/usr/man/primary", "primary"),
  entry("/usr/man/pwd", "pwd"),
  entry("/usr/man/rc", "rc"),
  entry("/usr/man/reboot", "reboot"),
  entry("/usr/man/redstone", "redstone"),
  entry("/usr/man/resolution", "resolution"),
  entry("/usr/man/rm", "rm"),
  entry("/usr/man/rmdir", "rmdir"),
  entry("/usr/man/set", "set"),
  entry("/usr/man/sh", "sh"),
  entry("/usr/man/shutdown", "shutdown"),
  entry("/usr/man/umount", "umount"),
  entry("/usr/man/unalias", "unalias"),
  entry("/usr/man/unset", "unset"),
  entry("/usr/man/uptime", "uptime"),
  entry("/usr/man/useradd", "useradd"),
  entry("/usr/man/userdel", "userdel"),
  entry("/usr/man/wget", "wget"),
  entry("/usr/man/which", "which"),
  entry("/usr/man/yes", "yes"),
  entry("/bin/install.lua", "install.lua"),
  entry("/bin/hello.lua", "hello.lua"),
}
local MINIMAL = {
  entry("/init.lua", "init.lua"),
  entry("/boot/kernel/main.lua", "main.lua"),
  entry("/lib/term.lua", "term.lua"),
  entry("/lib/fs.lua", "fs.lua"),
  entry("/lib/shell.lua", "shell.lua"),
  entry("/bin/sh.lua", "sh.lua"),
  entry("/bin/ls.lua", "ls.lua"),
  entry("/bin/cat.lua", "cat.lua"),
  entry("/bin/reboot.lua", "reboot.lua"),
  entry("/bin/shutdown.lua", "shutdown.lua"),
}
local manifest = minimal and MINIMAL or FULL

local srcMount = (srcDev and srcDev.mount) or "/"
local srcTag = srcDev.boot and "boot" or "installer"
term.writeln("Source: " .. srcDev.addr:sub(1, 8) .. " (" .. srcTag .. " " .. srcMount .. ")")
term.writeln("Target: " .. target.addr:sub(1, 8) ..
  " label=" .. tostring(target.label or "") ..
  (minimal and " [Minimal]" or " [Full]"))
local okGo = ask("Install? [Y/n]: ", "y")
if okGo:sub(1, 1):lower() ~= "y" then
  term.writeln("Cancelled.")
  return
end

-- ensure target mounted
local tmount = target.mount
if not tmount then
  tmount = "/mnt/" .. target.addr:sub(1, 3)
  local ok, err = freax.fsMount(target.addr, tmount)
  if not ok then term.writeln("mount failed: " .. tostring(err)) return end
end

local function mkdirP(path)
  local parts = {}
  for seg in path:gmatch("[^/]+") do parts[#parts + 1] = seg end
  local cur = ""
  for _, seg in ipairs(parts) do
    cur = cur .. "/" .. seg
    -- only mkdir on target prefix
    if not fs.exists(tmount .. cur) then
      fs.makeDirectory(tmount .. cur)
    end
  end
end

local fails = 0
for _, e in ipairs(manifest) do
  -- Read from source media (srcMount), not from cwd/root.
  -- Tries FHS path then flat fallback, both under srcMount.
  local data
  local tried = {}
  for _, s in ipairs(e.srcs) do
    local cand = s
    if srcMount ~= "/" then
      -- s is absolute ("/bin/x"); prefix with source mount
      cand = srcMount .. s
    end
    tried[#tried + 1] = cand
    data = fs.readFile(cand)
    if data then break end
  end
  if not data and srcMount ~= "/" then
    -- last resort: cwd-relative (old behaviour) in case mount table shifted
    for _, s in ipairs(e.srcs) do
      data = fs.readFile(s)
      if data then break end
    end
  end
  if not data then
    term.writeln("skip (not found on source): " .. e.dst)
    fails = fails + 1
  else
    local parent = fs.dir(e.dst)
    if parent and parent ~= "/" and parent ~= "" then mkdirP(parent) end
    -- ensure parent chain exists (mkdirP builds under tmount)
    local out = tmount .. e.dst
    -- makeDirectory may fail if exists; ignore
    local fd, err = fs.open(out, "w")
    if not fd then
      term.writeln("write fail " .. e.dst .. ": " .. tostring(err))
      fails = fails + 1
    else
      fs.write(fd, data)
      fs.close(fd)
      term.writeln((minimal and "[min] " or "") .. e.dst)
    end
  end
end

if fails == 0 then
  term.writeln("Copy done, verifying on target...")
else
  term.writeln("Done with " .. fails .. " skips/fails, verifying anyway...")
end

-- Verify by reading back through the VFS (catches wrong-device writes).
-- Without this, a silent miss ends as "no bootable medium found: /init.lua".
local need = { "/init.lua", "/boot/kernel/main.lua", "/bin/sh.lua" }
if not minimal then
  -- without these a full install boots straight into demo mode
  need[#need + 1] = "/bin/login.lua"
  need[#need + 1] = "/lib/auth.lua"
  need[#need + 1] = "/lib/sha256.lua"
  need[#need + 1] = "/etc/passwd"
  need[#need + 1] = "/etc/shadow"
  need[#need + 1] = "/manifest"
end
local bad = 0
for _, p in ipairs(need) do
  local back = fs.readFile(tmount .. p)
  if back and #back > 0 then
    term.writeln("  ok " .. p .. " (" .. #back .. "b)")
  else
    term.writeln("  MISSING " .. p)
    bad = bad + 1
  end
end
if bad > 0 then
  term.writeln("install: verification FAILED, refusing set-boot.")
  term.writeln("install: target " .. tmount .. " is missing boot files.")
  return
end
term.writeln("Verification passed.")

if not minimal then
  -- root home + root password (full installs boot into login)
  if not fs.exists(tmount .. "/root") then
    fs.makeDirectory(tmount .. "/root")
  end
  term.write("Set root password (empty = none, change later with passwd): ")
  local pw1 = term.read(nil, true, nil, "*") or ""
  if pw1 ~= "" then
    term.write("Retype: ")
    local pw2 = term.read(nil, true, nil, "*") or ""
    if pw1 ~= pw2 then
      term.writeln("Mismatch -- leaving root passwordless.")
    else
      -- auth lib ships on full media (this block is full-only);
      -- fall back to passwordless rather than a homebrew hash.
      local okAuth, auth = pcall(require, "auth")
      if not okAuth then
        term.writeln("No auth lib on media -- root stays passwordless.")
      else
        local salt = auth.genSalt()
        local fd = fs.open(tmount .. "/etc/shadow", "w")
        if fd then
          fs.write(fd, "root:$" .. salt .. "$" .. auth.hash(pw1, salt) .. "\n")
          fs.close(fd)
          term.writeln("Root password set.")
        else
          term.writeln("Could not write shadow file -- root stays passwordless.")
        end
      end
    end
  else
    term.writeln("No password -- run `passwd` after first login.")
  end
end

-- Show what's actually on the target (screenshot this if boot fails).
term.writeln("Target contents:")
for _, d in ipairs({ "", "/boot/kernel", "/bin", "/lib" }) do
  local list = fs.list(tmount .. d)
  if list then
    term.writeln(" " .. tmount .. (d == "" and "/" or d) .. ": " .. table.concat(list, " "))
  else
    term.writeln(" " .. tmount .. d .. ": (unreadable)")
  end
end

local setboot = ask("Set boot address to target? [Y/n]: ", "y")
if setboot:sub(1, 1):lower() == "y" then
  local ok, err = freax.setBootAddr(target.addr)
  if ok then
    term.writeln("Boot address set to " .. target.addr:sub(1, 8))
  else
    term.writeln("ERROR: boot address NOT set: " .. tostring(err))
    term.writeln("Rebooting now would boot the old media, not the target.")
  end
end
local rb = ask("Reboot now? [Y/n]: ", "n")
if rb:sub(1, 1):lower() == "y" then
  freax.reboot()
end
