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
if freax.geteuid() ~= 0 then
  term.writeln("install: must be run as root")
  return 1
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
    local found
    for _, d in ipairs(devs) do
      if d.addr:sub(1, #opts.from) == opts.from then
        if found then return nil, "ambiguous --from address" end
        found = d
      end
    end
    if not found then return nil, "unknown --from address" end
    return found
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

local installerDev, sourceErr = findInstallerDev()
if sourceErr then term.writeln("install: " .. sourceErr) return end
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
    if d.addr:sub(1, #opts.to) == opts.to then
      if forced then term.writeln("install: ambiguous --to address") return end
      forced = d
    end
  end
  if not forced then term.writeln("install: unknown --to address") return end
  targets = { forced }
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

-- Single-source file list: the install manifest IS /manifest on the source
-- media (the same file the `sys` upgrade pulls from). Adding a file means
-- editing `manifest` only -- there is no second hardcoded list.
-- Repo root mirrors the installed root (/), so each dst doubles as its
-- own source path on the install media: {dst, srcs={dst}}.
-- Never installed: dev-only wipe-guard entries plus local-only config.
local SKIP_INSTALL = {
  ["/.gitignore"] = true,
  ["/README.md"] = true,
  ["/selfcheck.lua"] = true,
  ["/mksums.lua"] = true,
  ["/etc/hostname"] = true, -- local-only, per machine
}
local function manifestEntry(dst)
  return { dst = dst, srcs = { dst } }
end
-- Parsed from the source media once srcMount is known (below).
local manifest = {}
local function loadManifest(srcMountPath)
  local mpath = (srcMountPath ~= "/"
    and srcMountPath .. "/manifest") or "/manifest"
  local data = fs.readFile(mpath)
  if not data then return {} end
  local out = {}
  for line in (data .. "\n"):gmatch("(.-)\n") do
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" and line:sub(1, 1) ~= "#" then
      if line:sub(1, 1) ~= "/" then line = "/" .. line end
      local canonical = fs.canonical(line)
      if canonical ~= line or line == "/" then return {} end
      out[#out + 1] = manifestEntry(line)
    end
  end
  return out
end
-- (retired hardcoded FULL table: /manifest on the source media is now the
-- single file list, loaded below once srcMount is known.)

local srcMount = (srcDev and srcDev.mount) or "/"
local srcTag = srcDev.boot and "boot" or "installer"
manifest = loadManifest(srcMount)
if #manifest == 0 then
  term.writeln("install: cannot read manifest on source (" .. srcMount .. ")")
  return
end
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
  if SKIP_INSTALL[e.dst] then
  else
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
          local chunk, rerr = fs.read(infd, 4096)
          if not chunk then
            if rerr then ok, werr = nil, rerr end
            break
          end
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
end

if fails == 0 then
  term.writeln("Copy done, verifying on target...")
else
  term.writeln("Done with " .. fails .. " skips/fails, verifying anyway...")
  -- name the holes: "Verification passed" below only covers boot files,
  -- so a silent skip list here is how a target ends up without uuid etc.
  local names = {}
  for dst in pairs(skipped) do names[#names + 1] = dst end
  table.sort(names)
  for _, dst in ipairs(names) do
    term.writeln("  skipped " .. dst .. " (missing on source media)")
  end
end

-- Create account database on target (dev media does not carry a live DB)
if not fs.exists(tmount .. "/etc") then fs.makeDirectory(tmount .. "/etc") end
local pwfd = fs.open(tmount .. "/etc/passwd", "w")
if pwfd then
  fs.write(pwfd, "root:x:0:0:root:/root:/bin/sh.lua\n")
  fs.close(pwfd)
end
local shfd = fs.open(tmount .. "/etc/shadow", "w")
if shfd then
  fs.write(shfd, "root:\n")
  fs.close(shfd)
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
need[#need + 1] = "/VERSION"
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
if fails > 0 or bad > 0 then
  term.writeln("install: verification FAILED, refusing set-boot.")
  term.writeln("install: target " .. tmount .. " is incomplete.")
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
      -- auth lib ships on install media; fall back to passwordless
      -- rather than a homebrew hash when it is missing.
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

local newLabel = "freax"
if newLabel ~= (target.label or "") then
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
