-- webinstall: install Freax from the internet onto a hard drive.
--
-- Runs on a stock OpenOS diskette, so nobody needs a Freax floppy:
-- boot OpenOS, plug in an internet card and a formatted hard drive, then
--
--   wget -f https://raw.githubusercontent.com/Bufka2011/Freax/main/webinstall.lua /tmp/webinstall.lua
--   lua /tmp/webinstall.lua
--
-- It fetches /manifest from the Freax repo and streams every shipped
-- file to the target (never holds a whole file in RAM), generates the
-- account database, labels the drive and sets the boot address.
--
-- This script deliberately uses only OpenOS libraries (filesystem,
-- component, internet, shell, term, computer); it does not run on Freax.

local computer = require("computer")
local component = require("component")
local fs = require("filesystem")
local internet = require("internet")
local shell = require("shell")
local term = require("term")

local DEFAULT_SOURCE = "https://raw.githubusercontent.com/Bufka2011/Freax/main/"
local USER_AGENT = "Freax/WebInstall"

-- Shipped for the demo/wipe guard or local-only: never installed.
local SKIP = {
  ["/.gitignore"] = true,
  ["/README.md"] = true,
  ["/selfcheck.lua"] = true,
  ["/etc/hostname"] = true,
  ["/etc/passwd"] = true,
  ["/etc/shadow"] = true,
}

local _, opts = shell.parse(...)

local function usage()
  io.write("Usage: webinstall [OPTIONS]\n")
  io.write("  --source=URL   Freax repository base URL\n")
  io.write("                 (default " .. DEFAULT_SOURCE .. ")\n")
  io.write("  --to=ADDR      install to this filesystem address\n")
  io.write("  -y, --yes      do not ask for confirmation\n")
  io.write("  --label=NAME   target filesystem label (default freax)\n")
  io.write("  --nosetboot    do not set the machine boot address\n")
  io.write("  --noreboot     do not offer to reboot\n")
end

if opts.help or opts.h then
  usage()
  return 0
end

local function trim(s)
  return (tostring(s or ""):match("^%s*(.-)%s*$"))
end

local function withSlash(u)
  u = tostring(u or "")
  if u:sub(-1) ~= "/" then u = u .. "/" end
  return u
end

-- GitHub raw serves a stale copy for a few minutes after a push; a unique
-- query string bypasses the CDN.
local function bust(u)
  return u .. (u:find("?", 1, true) and "&" or "?") ..
    "_=" .. tostring(math.random(1, 2147483647))
end

local source = withSlash(opts.source or DEFAULT_SOURCE)

if not component.isAvailable("internet") then
  io.stderr:write("webinstall: no internet card found\n")
  return 1
end

-- Small text fetch (manifest/VERSION are KBs, concat is fine).
local function fetchText(url)
  local ok, handle = pcall(internet.request, bust(url), nil,
    { ["user-agent"] = USER_AGENT })
  if not ok then return nil, tostring(handle) end
  local parts = {}
  local ok2, err = pcall(function()
    for chunk in handle do parts[#parts + 1] = chunk end
  end)
  if not ok2 then return nil, tostring(err) end
  return table.concat(parts)
end

-- Stream a remote file straight to disk in chunks.
local function fetchFile(url, path)
  local ok, handle = pcall(internet.request, bust(url), nil,
    { ["user-agent"] = USER_AGENT })
  if not ok then return nil, tostring(handle) end
  local fd, ferr = fs.open(path, "w")
  if not fd then return nil, tostring(ferr or "cannot write") end
  local ok2, err = pcall(function()
    for chunk in handle do
      local wok, werr = fd:write(chunk)
      if not wok then error(tostring(werr or "write failed")) end
    end
  end)
  fd:close()
  if not ok2 then
    fs.remove(path)
    return nil, tostring(err)
  end
  return true
end

local function parseManifest(text)
  local out, seen = {}, {}
  for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    line = trim(line)
    if line ~= "" and line:sub(1, 1) ~= "#" then
      if line:sub(1, 1) ~= "/" then line = "/" .. line end
      local canonical = fs.canonical(line)
      if canonical ~= line or line == "/" or seen[line] then
        return nil, "unsafe or duplicate manifest path: " .. line
      end
      seen[line] = true
      out[#out + 1] = line
    end
  end
  return out
end

local function mkdirP(root, rel)
  local cur = root
  for seg in tostring(rel):gmatch("[^/]+") do
    cur = cur .. "/" .. seg
    if not fs.exists(cur) then
      fs.makeDirectory(cur) -- may fail if it appeared meanwhile; ignore
    end
  end
end

local function writeFile(path, data)
  local fd, err = fs.open(path, "w")
  if not fd then return nil, err end
  fd:write(data)
  fd:close()
  return true
end

local function genSalt()
  local chars = "abcdefghijklmnopqrstuvwxyz0123456789"
  local out = {}
  for _ = 1, 8 do
    local i = math.random(1, #chars)
    out[#out + 1] = chars:sub(i, i)
  end
  return table.concat(out)
end

io.write("Freax web installer\n")
io.write("Source: " .. source .. "\n")
io.write("Fetching manifest... ")
local man, merr = fetchText(source .. "manifest")
if not man then
  io.stderr:write("failed: " .. tostring(merr) .. "\n")
  return 1
end
local files, manifestErr = parseManifest(man)
if not files then io.stderr:write("failed: " .. tostring(manifestErr) .. "\n") return 1 end
io.write(#files .. " files.\n")

local ver = fetchText(source .. "VERSION")
if ver then
  io.write("Remote version: " .. (ver:match("%S+") or "?") .. "\n")
end

-- Candidate targets: writable, component-backed filesystems that are not
-- the boot device, the tmpfs, or devfs.
local comps = component.list("filesystem")
local bootAddr = computer.getBootAddress()
local tmpAddr = computer.tmpAddress()

local targets = {}
for dev, path in fs.mounts() do
  local addr = dev and dev.address
  if addr and comps[addr] and addr ~= bootAddr and addr ~= tmpAddr
    and path ~= "/dev" and not dev.isReadOnly() then
    targets[#targets + 1] = { addr = addr, path = path, dev = dev }
  end
end

local function matchesTo(addr)
  return opts.to and addr:sub(1, #opts.to) == opts.to
end

local target
if opts.to then
  local matches = 0
  for _, t in ipairs(targets) do
    if matchesTo(t.addr) then target, matches = t, matches + 1 end
  end
  if matches > 1 then io.stderr:write("webinstall: ambiguous target address\n") return 1 end
  if not target then
    -- maybe the component exists but was not auto-mounted
    for addr in pairs(comps) do
      if matchesTo(addr) then
        matches = matches + 1
        if matches > 1 then io.stderr:write("webinstall: ambiguous target address\n") return 1 end
        local path = "/mnt/" .. addr:sub(1, 8)
        if not fs.exists(path) then fs.makeDirectory(path) end
        if fs.mount(addr, path) then
          target = { addr = addr, path = path, dev = fs.get(path) }
          break
        end
      end
    end
  end
  if not target then
    io.stderr:write("webinstall: no writable target matching " ..
      tostring(opts.to) .. "\n")
    return 1
  end
elseif #targets == 0 then
  io.stderr:write("webinstall: no writable target found\n")
  io.stderr:write("webinstall: attach a formatted hard drive, or --to=ADDR\n")
  return 1
elseif #targets == 1 then
  target = targets[1]
else
  io.write("Targets:\n")
  for i, t in ipairs(targets) do
    local label, total = "", ""
    pcall(function() label = t.dev.getLabel() or "" end)
    pcall(function() total = t.dev.spaceTotal() end)
    io.write(string.format(" %d) %s label=%s total=%s mount=%s\n",
      i, t.addr:sub(1, 8), tostring(label), tostring(total), t.path))
  end
  io.write("Install to [1]: ")
  local pick = tonumber(io.read() or "") or 1
  target = targets[pick] or targets[1]
end

io.write("Target: " .. target.addr:sub(1, 8) .. " mount=" .. target.path .. "\n")
if not (opts.yes or opts.y) then
  io.write("Install Freax to this drive? [Y/n] ")
  local ans = io.read() or ""
  if ans ~= "" and ans:sub(1, 1):lower() ~= "y" then
    io.write("Cancelled.\n")
    return 0
  end
end

local okN, failN, skipN = 0, 0, 0
local fails = {}
for i, dst in ipairs(files) do
  if SKIP[dst] then
    skipN = skipN + 1
  else
    local parent = fs.path(dst)
    if parent and parent ~= "/" and parent ~= "" then
      mkdirP(target.path, parent)
    end
    local out = target.path .. dst
    local tmp = out .. ".webinstall-new"
    io.write(string.format("[%d/%d] %s ", i, #files, dst))
    local ok, err = fetchFile(source .. dst:sub(2), tmp)
    if not ok then
      io.write("FAIL: " .. tostring(err) .. "\n")
      failN = failN + 1
      fails[#fails + 1] = dst .. ": " .. tostring(err)
    else
      -- 0-byte files are legitimate (.gitkeep); fetchFile already removed
      -- the temp file on a real write error, so success means we're good.
      -- temp + rename: a broken transfer never clobbers a good file
      local rok, rerr = fs.rename(tmp, out)
      if not rok then
        fs.remove(out)
        rok, rerr = fs.rename(tmp, out)
      end
      if not rok then
        fs.remove(tmp)
        io.write("FAIL: " .. tostring(rerr) .. "\n")
        failN = failN + 1
        fails[#fails + 1] = dst .. ": " .. tostring(rerr)
      else
        io.write("ok\n")
        okN = okN + 1
      end
    end
  end
end

-- Account database and per-machine config (never shipped).
mkdirP(target.path, "/etc")
writeFile(target.path .. "/etc/passwd",
  "root:x:0:0:root:/root:/bin/sh.lua\n")

local shadow = "root::\n"
io.write("Set root password (empty = none, change later with passwd): ")
local pw = term.read(nil, true, nil, "*") or ""
if pw ~= "" then
  io.write("\nRetype: ")
  local pw2 = term.read(nil, true, nil, "*") or ""
  io.write("\n")
  if pw ~= pw2 then
    io.write("Mismatch -- leaving root passwordless.\n")
  else
    -- The target's sha256 (pure Lua) gives shadow entries identical to
    -- the on-media Freax installer's.
    local chunk = loadfile(target.path .. "/lib/sha256.lua")
    local sha = chunk and chunk()
    if sha and sha.digest then
      local salt = genSalt()
      shadow = "root:$" .. salt .. "$" .. sha.digest(salt .. pw) .. "\n"
      io.write("Root password set.\n")
    else
      io.write("No sha256 on target -- root stays passwordless.\n")
    end
  end
end
writeFile(target.path .. "/etc/shadow", shadow)
writeFile(target.path .. "/etc/hostname", "freax\n")

mkdirP(target.path, "/root")
mkdirP(target.path, "/home")

-- Verify through the mounted target; a silent miss here ends as
-- "no bootable medium found: /init.lua".
local need = {
  "/init.lua", "/boot/kernel/main.lua", "/bin/sh.lua", "/bin/login.lua",
  "/lib/auth.lua", "/lib/sha256.lua", "/etc/passwd", "/etc/shadow",
  "/manifest", "/VERSION",
}
local bad = 0
io.write("Verifying...\n")
for _, p in ipairs(need) do
  local sz = fs.size(target.path .. p)
  if sz and sz > 0 then
    io.write("  ok " .. p .. " (" .. sz .. "b)\n")
  else
    io.write("  MISSING " .. p .. "\n")
    bad = bad + 1
  end
end
if bad > 0 then
  io.stderr:write("webinstall: verification FAILED, not setting boot address\n")
  return 1
end

io.write(string.format("Copied %d files (%d skipped, %d failed).\n",
  okN, skipN, failN))
for _, f in ipairs(fails) do io.stderr:write("  " .. f .. "\n") end

local label = tostring(opts.label or "freax")
pcall(target.dev.setLabel, label)
io.write("Label: " .. label .. "\n")

if not opts.nosetboot then
  if computer.setBootAddress(target.addr) then
    io.write("Boot address set to " .. target.addr:sub(1, 8) .. "\n")
  else
    io.stderr:write("webinstall: could not set boot address\n")
  end
end

if not opts.noreboot then
  io.write("Reboot now? [Y/n] ")
  local ans = io.read() or ""
  if ans == "" or ans:sub(1, 1):lower() == "y" then
    io.write("Rebooting...\n")
    computer.shutdown(true)
  end
end

io.write("Done. Eject the install media and boot the drive.\n")
if failN > 0 then
  io.stderr:write("webinstall: " .. failN ..
    " file(s) failed -- re-run to retry the rest\n")
  return 1
end
return 0
