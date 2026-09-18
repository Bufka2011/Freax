-- install: Freax installer.
-- Inspired by OpenOS bin/install + lib/core/install_basics.
-- Usage: install [--to=ADDR] [--from=ADDR]

local term = require("term")
local fs = require("fs")
local shell = require("shell")

local args, opts = shell.parse(...)
if opts.help then
  term.writeln("Usage: install [--to=ADDR] [--from=ADDR]")
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

-- Find the installer source media (where install.lua lives:
-- /bin/install.lua on current media, /install.lua on pre-reorg floppies).
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

-- manifest: {dst, srcCandidates[]}
-- Repo root mirrors the installed root (/), so each dst doubles as its
-- own source path on the install media.
local function entry(dst)
  return { dst = dst, srcs = { dst } }
end
local FULL = {
  entry("/init.lua"),
  entry("/boot/kernel/main.lua"),
  entry("/lib/term.lua"),
  entry("/lib/fs.lua"),
  entry("/lib/shell.lua"),
  entry("/lib/event.lua"),
  entry("/lib/keyboard.lua"),
  entry("/lib/tty.lua"),
  entry("/lib/filesystem.lua"),
  entry("/lib/component.lua"),
  entry("/lib/sides.lua"),
  entry("/lib/serialization.lua"),
  entry("/lib/uuid.lua"),
  entry("/lib/text.lua"),
  entry("/lib/transforms.lua"),
  entry("/lib/colors.lua"),
  entry("/lib/vt100.lua"),
  entry("/lib/note.lua"),
  entry("/lib/package.lua"),
  entry("/lib/io.lua"),
  entry("/lib/os.lua"),
  entry("/lib/pipe.lua"),
  entry("/lib/process.lua"),
  entry("/lib/internet.lua"),
  entry("/lib/eeprom.lua"),
  entry("/lib/rs.lua"),
  entry("/lib/thread.lua"),
  entry("/lib/buffer.lua"),
  entry("/lib/auth.lua"),
  entry("/lib/sha256.lua"),
  entry("/etc/motd"),
  entry("/etc/passwd"),
  entry("/etc/shadow"),
  entry("/manifest"),
  entry("/bin/sh.lua"),
  entry("/bin/ls.lua"),
  entry("/bin/cat.lua"),
  entry("/bin/cp.lua"),
  entry("/bin/mv.lua"),
  entry("/bin/mkdir.lua"),
  entry("/bin/rm.lua"),
  entry("/bin/touch.lua"),
  entry("/bin/pwd.lua"),
  entry("/bin/head.lua"),
  entry("/bin/grep.lua"),
  entry("/bin/wc.lua"),
  entry("/bin/sort.lua"),
  entry("/bin/du.lua"),
  entry("/bin/tree.lua"),
  entry("/bin/sleep.lua"),
  entry("/bin/uptime.lua"),
  entry("/bin/dmesg.lua"),
  entry("/bin/which.lua"),
  entry("/bin/printenv.lua"),
  entry("/bin/hostname.lua"),
  entry("/bin/df.lua"),
  entry("/bin/mount.lua"),
  entry("/bin/umount.lua"),
  entry("/bin/lua.lua"),
  entry("/bin/date.lua"),
  entry("/bin/free.lua"),
  entry("/bin/time.lua"),
  entry("/bin/yes.lua"),
  entry("/bin/mktmp.lua"),
  entry("/bin/rmdir.lua"),
  entry("/bin/find.lua"),
  entry("/bin/less.lua"),
  entry("/bin/edit.lua"),
  entry("/bin/reboot.lua"),
  entry("/bin/shutdown.lua"),
  entry("/bin/components.lua"),
  entry("/bin/lshw.lua"),
  entry("/bin/address.lua"),
  entry("/bin/primary.lua"),
  entry("/bin/label.lua"),
  entry("/bin/resolution.lua"),
  entry("/bin/redstone.lua"),
  entry("/bin/flash.lua"),
  entry("/bin/list.lua"),
  entry("/bin/wget.lua"),
  entry("/bin/pastebin.lua"),
  entry("/bin/ln.lua"),
  entry("/bin/man.lua"),
  entry("/bin/login.lua"),
  entry("/bin/passwd.lua"),
  entry("/bin/su.lua"),
  entry("/bin/whoami.lua"),
  entry("/bin/adduser.lua"),
  entry("/usr/man/address"),
  entry("/usr/man/alias"),
  entry("/usr/man/cat"),
  entry("/usr/man/cd"),
  entry("/usr/man/clear"),
  entry("/usr/man/cp"),
  entry("/usr/man/date"),
  entry("/usr/man/df"),
  entry("/usr/man/dmesg"),
  entry("/usr/man/echo"),
  entry("/usr/man/edit"),
  entry("/usr/man/grep"),
  entry("/usr/man/head"),
  entry("/usr/man/hostname"),
  entry("/usr/man/install"),
  entry("/usr/man/label"),
  entry("/usr/man/less"),
  entry("/usr/man/ln"),
  entry("/usr/man/ls"),
  entry("/usr/man/lshw"),
  entry("/usr/man/lua"),
  entry("/usr/man/man"),
  entry("/usr/man/mkdir"),
  entry("/usr/man/more"),
  entry("/usr/man/mount"),
  entry("/usr/man/mv"),
  entry("/usr/man/pastebin"),
  entry("/usr/man/primary"),
  entry("/usr/man/pwd"),
  entry("/usr/man/rc"),
  entry("/usr/man/reboot"),
  entry("/usr/man/redstone"),
  entry("/usr/man/resolution"),
  entry("/usr/man/rm"),
  entry("/usr/man/rmdir"),
  entry("/usr/man/set"),
  entry("/usr/man/sh"),
  entry("/usr/man/shutdown"),
  entry("/usr/man/umount"),
  entry("/usr/man/unalias"),
  entry("/usr/man/unset"),
  entry("/usr/man/uptime"),
  entry("/usr/man/useradd"),
  entry("/usr/man/userdel"),
  entry("/usr/man/wget"),
  entry("/usr/man/which"),
  entry("/usr/man/yes"),
  entry("/bin/install.lua"),
  entry("/bin/hello.lua"),
}
local manifest = FULL

local srcMount = (srcDev and srcDev.mount) or "/"
local srcTag = srcDev.boot and "boot" or "installer"
term.writeln("Source: " .. srcDev.addr:sub(1, 8) .. " (" .. srcTag .. " " .. srcMount .. ")")
term.writeln("Target: " .. target.addr:sub(1, 8) ..
  " label=" .. tostring(target.label or ""))
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
local skipped = {} -- dst paths missing on source (stale install media)
for _, e in ipairs(manifest) do
  -- Stream from source media (srcMount), not from cwd/root.
  -- Source media mirrors the installed root, so each dst is also the
  -- source path (prefixed with the source mount when it isn't /).
  -- Streaming fd->fd in 4K chunks: never hold a whole file in RAM.
  -- (readFile+concat on 66K main.lua OOMs low-RAM machines: the
  -- kernel + shell + installer + 2x file copies exceed the budget.)
  local function candidates()
    local out = {}
    for _, s in ipairs(e.srcs) do
      if srcMount ~= "/" then
        -- s is absolute ("/bin/x"); prefix with source mount
        out[#out + 1] = srcMount .. s
      else
        out[#out + 1] = s
      end
    end
    return out
  end
  local srcPath
  for _, cand in ipairs(candidates()) do
    if fs.exists(cand) then srcPath = cand break end
  end
  if not srcPath then
    term.writeln("skip (not found on source): " .. e.dst)
    skipped[e.dst] = true
    fails = fails + 1
  else
    local parent = fs.dir(e.dst)
    if parent and parent ~= "/" and parent ~= "" then mkdirP(parent) end
    -- ensure parent chain exists (mkdirP builds under tmount)
    local out = tmount .. e.dst
    -- makeDirectory may fail if exists; ignore
    local infd, rerr = fs.open(srcPath, "r")
    if not infd then
      term.writeln("read fail " .. e.dst .. ": " .. tostring(rerr))
      fails = fails + 1
    else
      local outfd, werr0 = fs.open(out, "w")
      if not outfd then
        fs.close(infd)
        term.writeln("write fail " .. e.dst .. ": " .. tostring(werr0))
        fails = fails + 1
      else
        -- chunked copy: single giant writes risk truncation on real
        -- hardware (OpenOS copies in 1-4K chunks for the same reason)
        local ok, werr = true, nil
        while true do
          local chunk = fs.read(infd, 4096)
          if not chunk then break end
          ok, werr = fs.write(outfd, chunk)
          if not ok then break end
        end
        fs.close(infd)
        fs.close(outfd)
        if not ok then
          term.writeln("write fail " .. e.dst .. ": " .. tostring(werr))
          fails = fails + 1
        else
          term.writeln(e.dst)
        end
      end
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
-- without these the install boots straight into demo mode
need[#need + 1] = "/bin/login.lua"
need[#need + 1] = "/lib/auth.lua"
need[#need + 1] = "/lib/sha256.lua"
need[#need + 1] = "/etc/passwd"
need[#need + 1] = "/etc/shadow"
need[#need + 1] = "/manifest"
local bad = 0
for _, p in ipairs(need) do
  -- size check, not full read: readFile on 66K main.lua doubles RAM
  -- pressure right after the copy loop (second OOM source).
  local sz = fs.size(tmount .. p)
  if sz and sz > 0 then
    term.writeln("  ok " .. p .. " (" .. sz .. "b)")
  elseif skipped[p] then
    term.writeln("  MISSING " .. p .. " (was skipped: update the install media)")
    bad = bad + 1
  else
    term.writeln("  MISSING " .. p .. " (copy failed: target/drive issue)")
    bad = bad + 1
  end
end
if bad > 0 then
  term.writeln("install: verification FAILED, refusing set-boot.")
  term.writeln("install: target " .. tmount .. " is missing boot files.")
  return
end
term.writeln("Verification passed.")

-- Preserve /home/ from source to target (user files survive install)
if fs.exists("/home") then
  term.writeln("Copying /home/ to target...")
  local stack = { "/home" }
  while #stack > 0 do
    local dir = table.remove(stack)
    local list = fs.list(dir)
    if list then
      for _, name in ipairs(list) do
        if name ~= "." and name ~= ".." then
          local isDir = name:sub(-1) == "/"
          local base = isDir and name:sub(1, -2) or name
          local full = dir .. "/" .. base
          local dst = tmount .. full
          if isDir then
            if not fs.exists(dst) then fs.makeDirectory(dst) end
            stack[#stack + 1] = full
          else
            local infd, rerr = fs.open(full, "r")
            if infd then
              local outfd, werr = fs.open(dst, "w")
              if outfd then
                while true do
                  local chunk = fs.read(infd, 4096)
                  if not chunk then break end
                  local ok, e = fs.write(outfd, chunk)
                  if not ok then break end
                end
                fs.close(infd); fs.close(outfd)
              else
                fs.close(infd)
              end
            end
          end
        end
      end
    end
  end
  term.writeln("/home/ copied.")
end

-- root home + root password (installs boot into login)
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

local newLabel = ask("Drive label [" .. tostring(target.label or "freax") .. "]: ",
  tostring(target.label or "freax"))
if newLabel ~= "" and newLabel ~= (target.label or "") then
  local ok, err = freax.fsSetLabel(target.addr, newLabel)
  if ok then
    term.writeln("Label set to " .. newLabel)
  else
    term.writeln("Could not set label: " .. tostring(err))
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
