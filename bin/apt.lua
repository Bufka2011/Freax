-- apt: Freax in-game updater.
-- Usage: apt update [--source=URL] | upgrade [--yes] [--force] [--source=URL]
--        | version | sources
-- Pulls core OS files over HTTP so you never leave the game to update:
-- no world restart, just `apt update`, `apt upgrade`, `reboot`.
-- Repo root mirrors the installed root (/), so each manifest entry maps
-- to <source><path>. Streaming 4K (never hold a whole file in RAM),
-- temp + rename (no half-written files), accounts/config preserved.

local fs = require("fs")
local shell = require("shell")
local term = require("term")

local DEFAULT_SOURCE = "https://raw.githubusercontent.com/Bufka2011/Freax/main/"
local CACHE_DIR = "/tmp/apt"
local CACHE_MANIFEST = CACHE_DIR .. "/manifest"
local CACHE_VERSION = CACHE_DIR .. "/VERSION"

-- Manifest entries that are dev-only: shipped for the demo wipe guard
-- but never installed, so the updater must not create them either.
local SKIP_DEV = {
  ["/.gitignore"] = true,
  ["/README.md"] = true,
  ["/selfcheck.lua"] = true,
}
-- Local state the updater must never overwrite.
local PRESERVE = {
  ["/etc/passwd"] = true,
  ["/etc/shadow"] = true,
  ["/etc/hostname"] = true,
}
-- Kernel/boot files: take effect on next (in-game) reboot, not instantly.
local NEEDS_REBOOT = {
  ["/init.lua"] = true,
  ["/boot/kernel/main.lua"] = true,
}

local args, opts = shell.parse(...)
local cmd = args[1]

local function trim(s)
  return (tostring(s or ""):match("^%s*(.-)%s*$"))
end

local function withSlash(u)
  u = tostring(u or "")
  if u:sub(-1) ~= "/" then u = u .. "/" end
  return u
end

local function effectiveSource()
  if opts.source and trim(opts.source) ~= "" then
    return withSlash(trim(opts.source))
  end
  local data = fs.readFile("/etc/apt/sources.list")
  if data then
    for line in (data .. "\n"):gmatch("(.-)\n") do
      line = trim(line)
      if line ~= "" and line:sub(1, 1) ~= "#" then
        return withSlash(line)
      end
    end
  end
  return DEFAULT_SOURCE
end

local function localVersion()
  local data = fs.readFile("/VERSION")
  if data then
    local v = data:match("%S+")
    if v then return v end
  end
  return "unknown"
end

local function mkdirP(path)
  local cur = ""
  for seg in tostring(path):gmatch("[^/]+") do
    cur = cur .. "/" .. seg
    if not fs.exists(cur) then fs.makeDirectory(cur) end
  end
end

local function needNet()
  if not freax.netAvail() then
    io.stderr:write("apt: needs an internet card (see `man apt`)\n")
    return false
  end
  return true
end

-- GitHub raw serves a cached copy for a few minutes after a push, which
-- makes `apt update` see the previous VERSION/manifest. A unique query
-- string changes the URL, so the CDN is bypassed and the new content is
-- fetched immediately. Harmless for plain file servers too.
local function noCache(url)
  local sep = url:find("?", 1, true) and "&" or "?"
  return url .. sep .. "_=" .. tostring(math.random(1, 2147483647))
end

-- Small text fetch (VERSION, manifest: KBs, concat is fine).
-- Returns body string or nil + err.
local function fetchText(url)
  local internet = require("internet")
  local ok, handle = pcall(internet.request, noCache(url), nil,
    { ["user-agent"] = "Apt/Freax" })
  if not ok then return nil, tostring(handle) end
  local parts, total = {}, 0
  local ok2, err = pcall(function()
    for chunk in handle do
      parts[#parts + 1] = chunk
      total = total + #chunk
      if total > 65536 then error("response too large") end
    end
  end)
  if not ok2 then return nil, tostring(err) end
  return table.concat(parts)
end

-- Stream a remote file straight to disk, chunk by chunk.
-- Never holds the whole file in RAM (kernel is ~66K; low-RAM OOMs).
local function fetchToFile(url, tmp)
  local internet = require("internet")
  local ok, handle = pcall(internet.request, noCache(url), nil,
    { ["user-agent"] = "Apt/Freax" })
  if not ok then return nil, tostring(handle) end
  local fd, oerr = fs.open(tmp, "w")
  if not fd then return nil, tostring(oerr or "cannot write") end
  local ok2, werr = pcall(function()
    for chunk in handle do
      local wok, wmsg = fs.write(fd, chunk)
      if not wok then error(tostring(wmsg or "write failed")) end
    end
  end)
  fs.close(fd)
  if not ok2 then
    fs.remove(tmp)
    return nil, tostring(werr)
  end
  return true
end

local function parseManifest(data)
  local out = {}
  for line in (tostring(data or "") .. "\n"):gmatch("(.-)\n") do
    line = trim(line)
    if line ~= "" and line:sub(1, 1) ~= "#" then
      if line:sub(1, 1) ~= "/" then line = "/" .. line end
      out[#out + 1] = line
    end
  end
  return out
end

local function usage()
  io.write("Usage: apt update [--source=URL]\n")
  io.write("       apt upgrade [--yes] [--force] [--source=URL]\n")
  io.write("       apt version | sources\n")
end

if not cmd or cmd == "help" or opts.help then
  usage()
  return
end

if cmd == "version" then
  io.write("freax " .. localVersion() .. "\n")
  local cached = fs.readFile(CACHE_VERSION)
  if cached then
    local rv = cached:match("%S+")
    if rv then io.write("cached remote: " .. rv .. "\n") end
  end
  return
end

if cmd == "sources" then
  io.write(effectiveSource() .. "\n")
  return
end

if cmd == "update" then
  if not needNet() then return 1 end
  local src = effectiveSource()
  io.write("Source: " .. src .. "\n")
  io.write("Checking version... ")
  local body, err = fetchText(src .. "VERSION")
  if not body then
    io.stderr:write("failed.\napt: " .. tostring(err) .. "\n")
    return 1
  end
  local remote = (body:match("%S+")) or "unknown"
  io.write(remote .. "\n")
  io.write("Fetching manifest... ")
  local man, merr = fetchText(src .. "manifest")
  if not man then
    io.stderr:write("failed.\napt: " .. tostring(merr) .. "\n")
    return 1
  end
  mkdirP(CACHE_DIR)
  local fd = fs.open(CACHE_MANIFEST, "w")
  if not fd then
    io.stderr:write("failed.\napt: cannot write cache\n")
    return 1
  end
  fs.write(fd, man)
  fs.close(fd)
  local vfd = fs.open(CACHE_VERSION, "w")
  if vfd then fs.write(vfd, remote .. "\n") fs.close(vfd) end
  local n = #parseManifest(man)
  io.write("Local: " .. localVersion() .. "  Remote: " .. remote .. "\n")
  if localVersion() == remote then
    io.write("Already up to date (" .. n .. " files).\n")
  else
    io.write(n .. " files available. Run `apt upgrade`.\n")
  end
  return
end

if cmd == "upgrade" then
  if not needNet() then return 1 end
  local src = effectiveSource()
  local man = fs.readFile(CACHE_MANIFEST)
  if not man then
    io.write("No cache, fetching manifest... ")
    local fresh, merr = fetchText(src .. "manifest")
    if not fresh then
      io.stderr:write("failed.\napt: " .. tostring(merr) .. "\n")
      return 1
    end
    man = fresh
    io.write("ok.\n")
  end
  local remote = "unknown"
  local cached = fs.readFile(CACHE_VERSION)
  if cached and cached:match("%S+") then
    remote = cached:match("%S+")
  else
    local body = fetchText(src .. "VERSION")
    if body and body:match("%S+") then remote = body:match("%S+") end
  end
  local files = parseManifest(man)
  if remote == "unknown" then
    io.stderr:write("apt: cannot determine remote version, aborting.\n")
    return 1
  end
  if localVersion() == remote and not (opts.force or opts.f) then
    io.write("Already up to date (" .. localVersion() .. ").\n")
    return
  end
  io.write("Upgrading " .. localVersion() .. " -> " .. remote ..
    " (" .. #files .. " files)...\n")
  local yes = opts.yes or opts.y
  if not yes then
    term.write("Continue? [Y/n]: ")
    local ans = term.readLine() or ""
    if ans ~= "" and ans:sub(1, 1):lower() ~= "y" then
      io.write("Cancelled.\n")
      return
    end
  end
  local okN, failN, skipN, fails = 0, 0, 0, {}
  local kernelTouched = false
  for _, dst in ipairs(files) do
    if SKIP_DEV[dst] or PRESERVE[dst] then
      skipN = skipN + 1
    elseif dst == "/etc/apt/sources.list" and fs.exists(dst) then
      -- custom mirror stays custom; install only when missing
      skipN = skipN + 1
    else
      local rel = dst:sub(2) -- strip leading / for URL join
      local tmp = dst .. ".apt-new"
      local parent = fs.dir(dst)
      if parent and parent ~= "/" and parent ~= "" then mkdirP(parent) end
      local ok, err = fetchToFile(src .. rel, tmp)
      if not ok then
        failN = failN + 1
        fails[#fails + 1] = dst .. ": " .. tostring(err)
        io.write("FAIL " .. dst .. "\n")
      else
        local sz = fs.size(tmp) or 0
        if sz <= 0 then
          fs.remove(tmp)
          failN = failN + 1
          fails[#fails + 1] = dst .. ": empty download"
          io.write("FAIL " .. dst .. " (empty)\n")
        else
          local rok, rerr = os.rename(tmp, dst)
          if not rok then
            fs.remove(tmp)
            failN = failN + 1
            fails[#fails + 1] = dst .. ": " .. tostring(rerr)
            io.write("FAIL " .. dst .. "\n")
          else
            okN = okN + 1
            if NEEDS_REBOOT[dst] then kernelTouched = true end
          end
        end
      end
    end
  end
  io.write(string.format("Done: %d ok, %d failed, %d skipped.\n",
    okN, failN, skipN))
  for _, f in ipairs(fails) do io.stderr:write("  " .. f .. "\n") end
  if failN > 0 then
    io.stderr:write("apt: upgrade incomplete, VERSION kept at " ..
      localVersion() .. " (retry `apt upgrade`).\n")
    return 1
  end
  -- all files landed: publish the new version + manifest
  local vfd = fs.open("/VERSION", "w")
  if vfd then fs.write(vfd, remote .. "\n") fs.close(vfd) end
  local mfd = fs.open("/manifest", "w")
  if mfd then fs.write(mfd, man) fs.close(mfd) end
  io.write("Upgraded to " .. remote .. ".\n")
  if kernelTouched then
    term.write("Kernel updated. Reboot now? [y/N]: ")
    local ans = term.readLine() or ""
    if ans:sub(1, 1):lower() == "y" then freax.reboot() end
  end
  return
end

io.stderr:write("apt: unknown command `" .. tostring(cmd) .. "`\n")
usage()
return 1
