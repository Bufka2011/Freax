-- sysupdate: manifest-based Freax OS self-updater (legacy apt path).
-- Extracted from the original bin/apt.lua so `apt sysupdate` / `apt
-- sysupgrade` keep updating the running OS from /manifest while the new
-- package manager handles third-party packages.
-- Pulls core OS files over HTTP so you never leave the game to update:
-- no world restart, just `apt sysupdate`, `apt sysupgrade`, `reboot`.
-- Repo root mirrors the installed root (/), so each manifest entry maps
-- to <source><path>. Streaming 4K (never hold a whole file in RAM),
-- temp + rename (no half-written files), accounts/config preserved.

local fs = require("fs")
local term = require("term")
local sha256 = require("sha256")

local sysupdate = {}
-- summary of the last `apt update`, feeding sysupdate.status() so the OS can
-- be presented as the virtual "sys" package
local lastSummary

local DEFAULT_SOURCE = "https://raw.githubusercontent.com/Bufka2011/Freax/main/"
local CACHE_DIR = "/tmp/apt"
local CACHE_MANIFEST = CACHE_DIR .. "/manifest"
local CACHE_VERSION = CACHE_DIR .. "/VERSION"
local CACHE_SUMS = CACHE_DIR .. "/SHA256SUMS"
local CACHE_CHANGED = CACHE_DIR .. "/changed"

-- Manifest entries that are dev-only: shipped for the demo wipe guard
-- but never installed, so the updater must not create them either.
local SKIP_DEV = {
  ["/.gitignore"] = true,
  ["/README.md"] = true,
  ["/mksums.lua"] = true,
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

local function trim(s)
  return (tostring(s or ""):match("^%s*(.-)%s*$"))
end

local function withSlash(u)
  u = tostring(u or "")
  if u:sub(-1) ~= "/" then u = u .. "/" end
  return u
end

function sysupdate.effectiveSource(opts)
  if opts and opts.source and trim(opts.source) ~= "" then
    return withSlash(trim(opts.source))
  end
  local data = fs.readFile("/etc/apt/sources.list")
  if data then
    for line in (data .. "\n"):gmatch("(.-)\n") do
      line = trim(line)
      -- skip deb/deb-src package lines: the OS mirror is a bare URL
      if line ~= "" and line:sub(1, 1) ~= "#"
        and line:sub(1, 4) ~= "deb " and line:sub(1, 8) ~= "deb-src " then
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
-- makes the version check see the previous VERSION/manifest. A unique
-- query string changes the URL, so the CDN is bypassed and the new
-- content is fetched immediately. Harmless for plain file servers too.
local function noCache(url)
  local sep = url:find("?", 1, true) and "&" or "?"
  return url .. sep .. "_=" .. tostring(math.random(1, 2147483647))
end

-- Small text fetch (VERSION, manifest: KBs, concat is fine).
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
  local out, seen = {}, {}
  for line in (tostring(data or "") .. "\n"):gmatch("(.-)\n") do
    line = trim(line)
    if line ~= "" and line:sub(1, 1) ~= "#" then
      if line:sub(1, 1) ~= "/" then line = "/" .. line end
      if line == "/" or fs.canonical(line) ~= line or seen[line] then
        return nil, "unsafe or duplicate manifest path: " .. line
      end
      seen[line] = true
      out[#out + 1] = line
    end
  end
  return out
end

-- SHA256SUMS: "<hex>  <path>" per shipped file (generated by mksums.lua).
-- sysupgrade uses it to download only files whose content changed.
local function parseSums(text)
  local out = {}
  for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    local hex, path = line:match("^(%x+)%s+%*?(.+)$")
    if hex and path then
      path = trim(path)
      if path:sub(1, 1) ~= "/" then path = "/" .. path end
      if #hex == 64 and path ~= "/" and fs.canonical(path) == path then
        out[path] = hex:lower()
      end
    end
  end
  return out
end

-- Streaming local file hash (never holds a whole file in RAM). Pure-Lua
-- SHA-256 is CPU-heavy, so yield between chunks: the OC sandbox kills a
-- script that runs "too long without yielding", and hashing every file
-- easily trips that.
local function sha256File(path)
  local fd, err = fs.open(path, "r")
  if not fd then return nil, err end
  local h = sha256.new()
  while true do
    local chunk = fs.read(fd, 4096)
    if not chunk or chunk == "" then break end
    h:update(chunk)
    coroutine.yield()
  end
  fs.close(fd)
  return h:hex()
end

local function kernelChanged(paths)
  for _, p in ipairs(paths) do if NEEDS_REBOOT[p] then return true end end
  return false
end

-- Replace an installed file with an already downloaded temp file.
-- OC filesystem proxies commonly refuse to rename over an existing file, so
-- the old file is moved aside first and the result is re-hashed: a silent
-- no-op rename must never be reported as a successful update.
local function replaceInstalled(tmp, dst, want)
  local backup = dst .. ".apt-old"
  if fs.exists(backup) or fs.isLink(backup) then fs.remove(backup) end
  local hadOld = fs.exists(dst) or fs.isLink(dst)
  if hadOld then
    local bok = os.rename(dst, backup)
    if not bok then
      -- cannot move the old file aside: drop it, the replacement is already
      -- hash-verified
      fs.remove(dst)
    end
  end
  local rok, rerr = os.rename(tmp, dst)
  if not rok then
    if hadOld and fs.exists(backup) then os.rename(backup, dst) end
    fs.remove(tmp)
    return nil, tostring(rerr or "rename failed")
  end
  if want then
    local landed = sha256File(dst)
    if landed ~= want then
      fs.remove(dst)
      if hadOld and fs.exists(backup) then os.rename(backup, dst) end
      return nil, "installed file does not match its checksum"
    end
  end
  if hadOld and (fs.exists(backup) or fs.isLink(backup)) then fs.remove(backup) end
  return true
end

-- Only trust remote checksums that describe the remote VERSION we just
-- fetched: a stale SHA256SUMS would otherwise hide changed files.
local function validSums(remoteBody, sums)
  if not sums then return nil end
  local vsum = sums["/VERSION"]
  if vsum and remoteBody and sha256.digest(remoteBody) ~= vsum then
    return nil
  end
  return sums
end

function sysupdate.version()
  io.write("freax " .. localVersion() .. "\n")
  local cached = fs.readFile(CACHE_VERSION)
  if cached then
    local rv = cached:match("%S+")
    if rv then io.write("cached remote: " .. rv .. "\n") end
  end
end

function sysupdate.sources(opts)
  io.write(sysupdate.effectiveSource(opts) .. "\n")
end

function sysupdate.update(opts)
  if not needNet() then return 1 end
  local src = sysupdate.effectiveSource(opts)
  fs.remove(CACHE_CHANGED)
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
  io.write("Fetching checksums... ")
  local sumsText, sumsErr = fetchText(src .. "SHA256SUMS")
  local sums = nil
  if sumsText then
    sums = parseSums(sumsText)
    if next(sums) == nil then sums = nil end
    local sfd = fs.open(CACHE_SUMS, "w")
    if sfd then fs.write(sfd, sumsText) fs.close(sfd) end
    io.write("ok.\n")
  else
    fs.remove(CACHE_SUMS)
    io.write("unavailable (" .. tostring(sumsErr) .. ").\n")
  end
  sums = validSums(body, sums)
  local files, parseErr = parseManifest(man)
  if not files then
    io.stderr:write("apt: " .. tostring(parseErr) .. "\n")
    return 1
  end
  local n = #files
  local changed = n
  local changedList = nil
  -- /SHA256SUMS on the installed system records the hashes of the files as
  -- of the last sync, so a changed-file scan is a table compare. Hashing
  -- every file with pure-Lua SHA-256 takes minutes; only do it when the
  -- file is missing (first run / pre-checksum install).
  local lsums = parseSums(fs.readFile("/SHA256SUMS"))
  local haveLocal = next(lsums) ~= nil
  if localVersion() ~= remote and sums then
    changedList = {}
    for _, dst in ipairs(files) do
      if not (SKIP_DEV[dst] or PRESERVE[dst])
        and dst ~= "/SHA256SUMS"
        and not (dst == "/etc/apt/sources.list" and fs.exists(dst)) then
        local want = sums[dst]
        local differs
        if haveLocal then
          differs = not fs.exists(dst) or lsums[dst] ~= want
        else
          differs = (not want) or (sha256File(dst) ~= want)
        end
        if differs then changedList[#changedList + 1] = dst end
      end
      coroutine.yield()
    end
    changed = #changedList
  elseif localVersion() == remote then
    changed = 0
  end
  -- Cache the changed set so `apt sysupgrade` does not re-hash every file.
  -- Only write it when checksums were valid; otherwise sysupgrade must
  -- assume everything changed.
  if changedList then
    local cfd = fs.open(CACHE_CHANGED, "w")
    if cfd then
      if #changedList > 0 then
        fs.write(cfd, table.concat(changedList, "\n") .. "\n")
      end
      fs.close(cfd)
    end
  end
  io.write("Local: " .. localVersion() .. "  Remote: " .. remote .. "\n")
  if localVersion() == remote then
    io.write("Already up to date (" .. n .. " files).\n")
  elseif sums then
    io.write(string.format("%d of %d files changed in release %s.\n",
      changed, n, remote))
  else
    io.write(n .. " files available (no checksums; full download).\n")
  end
  lastSummary = {
    installed = localVersion(), candidate = remote,
    files = n, changed = changed, sums = sums ~= nil,
  }
  return 0
end

-- Offline view of the virtual "sys" package, as recorded by the last
-- `apt update`. This is what `apt list`, `apt policy` and the upgrade plan
-- read, so the OS shows up like any other package.
function sysupdate.status(opts)
  local installed = localVersion()
  local candidate
  local cached = fs.readFile(CACHE_VERSION)
  if cached and cached:match("%S+") then candidate = cached:match("%S+") end
  local summary = lastSummary
  if summary and summary.candidate == candidate then
    installed = summary.installed
  end
  local files, changed = 0, 0
  if summary then
    files, changed = summary.files, summary.changed
  else
    local ctext = fs.readFile(CACHE_CHANGED)
    if ctext then
      for _ in ctext:gmatch("[^\n]+") do changed = changed + 1 end
    end
  end
  local upgradable = false
  if candidate and candidate ~= installed then
    local ok, fpkg = pcall(require, "fpkg")
    if ok then
      upgradable = fpkg.versionCompare(candidate, installed) > 0
    else
      upgradable = true
    end
  end
  return {
    name = "sys", installed = installed, candidate = candidate,
    upgradable = upgradable, files = files, changed = changed,
    source = sysupdate.effectiveSource(opts),
  }
end

function sysupdate.upgrade(opts)
  if not needNet() then return 1 end
  local src = sysupdate.effectiveSource(opts)
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
  local remote, versionBody = "unknown", nil
  local cached = fs.readFile(CACHE_VERSION)
  if cached and cached:match("%S+") then
    versionBody = cached
    remote = cached:match("%S+")
  else
    local body = fetchText(src .. "VERSION")
    if body and body:match("%S+") then versionBody, remote = body, body:match("%S+") end
  end
  local files, parseErr = parseManifest(man)
  if not files then io.stderr:write("apt: " .. tostring(parseErr) .. "\n") return 1 end
  -- Remote checksums (cached by `apt sysupdate`, else fetched now).
  local sumsRaw = fs.readFile(CACHE_SUMS)
  local sums = parseSums(sumsRaw)
  if next(sums) == nil then sums = nil end
  if not sums then
    local st = fetchText(src .. "SHA256SUMS")
    if st then
      sumsRaw = st
      sums = parseSums(st)
      if next(sums) == nil then sums = nil end
    end
  end
  sums = validSums(versionBody, sums)
  -- Local /SHA256SUMS: installed-file hashes, so skipping is a table
  -- compare instead of re-hashing every file.
  local lsums = parseSums(fs.readFile("/SHA256SUMS"))
  local haveLocal = next(lsums) ~= nil
  -- Changed set cached by `apt sysupdate`: avoids re-hashing every file.
  local changedSet = nil
  if sums then
    local ctext = fs.readFile(CACHE_CHANGED)
    if ctext then
      changedSet = {}
      for line in (ctext .. "\n"):gmatch("(.-)\n") do
        line = trim(line)
        if line ~= "" then
          if line:sub(1, 1) ~= "/" then line = "/" .. line end
          if fs.canonical(line) == line then changedSet[line] = true end
        end
      end
    end
  end
  if remote == "unknown" then
    io.stderr:write("apt: cannot determine remote version, aborting.\n")
    return 1
  end
  if localVersion() == remote and not (opts.force or opts.f) then
    io.write("Already up to date (" .. localVersion() .. ").\n")
    return 0
  end
  -- Report what will actually be fetched, not the whole manifest size.
  local toFetch
  if changedSet then
    toFetch = 0
    for _ in pairs(changedSet) do toFetch = toFetch + 1 end
  elseif haveLocal then
    toFetch = 0
    for _, dst in ipairs(files) do
      if not (SKIP_DEV[dst] or PRESERVE[dst]) and dst ~= "/SHA256SUMS"
        and not (dst == "/etc/apt/sources.list" and fs.exists(dst))
        and (not fs.exists(dst) or lsums[dst] ~= (sums and sums[dst])) then
        toFetch = toFetch + 1
      end
    end
  else
    toFetch = #files
  end
  io.write("Upgrading " .. localVersion() .. " -> " .. remote ..
    " (" .. toFetch .. " files)...\n")
  local yes = opts.yes or opts.y
  if not yes then
    term.write("Continue? [Y/n]: ")
    local ans = term.readLine() or ""
    if ans ~= "" and ans:sub(1, 1):lower() ~= "y" then
      io.write("Cancelled.\n")
      return 0
    end
  end
  local okN, failN, skipN, fails = 0, 0, 0, {}
  local kernelTouched = false
  for _, dst in ipairs(files) do
    if SKIP_DEV[dst] or PRESERVE[dst] then
      skipN = skipN + 1
    elseif dst == "/etc/apt/sources.list" and fs.exists(dst) then
      skipN = skipN + 1
    elseif dst == "/SHA256SUMS" then
      skipN = skipN + 1 -- written from the fetched remote sums below
    else
      local want = sums and sums[dst]
      local needs
      if changedSet then
        needs = changedSet[dst] and true or false
      elseif haveLocal then
        needs = not fs.exists(dst) or lsums[dst] ~= want
      elseif want then
        needs = sha256File(dst) ~= want
      else
        needs = true
      end
      if not needs then
        skipN = skipN + 1 -- content unchanged: no download
      else
        local rel = dst:sub(2)
        local tmp = dst .. ".apt-new"
        local parent = fs.dir(dst)
        if parent and parent ~= "/" and parent ~= "" then mkdirP(parent) end
        local ok, err = fetchToFile(src .. rel, tmp)
        if not ok then
          failN = failN + 1
          fails[#fails + 1] = dst .. ": " .. tostring(err)
          io.write("FAIL " .. dst .. "\n")
        else
          -- 0-byte files are legitimate (.gitkeep); fetchToFile already
          -- removed the temp on a real write error.
          local got = want and sha256File(tmp)
          if want and got ~= want then
            fs.remove(tmp)
            failN = failN + 1
            fails[#fails + 1] = dst .. ": checksum mismatch"
            io.write("FAIL " .. dst .. " (checksum)\n")
          else
            local rok, rerr = replaceInstalled(tmp, dst, want)
            if not rok then
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
  end
  io.write(string.format("Done: %d ok, %d failed, %d skipped.\n",
    okN, failN, skipN))
  for _, f in ipairs(fails) do io.stderr:write("  " .. f .. "\n") end
  if failN > 0 then
    io.stderr:write("apt: upgrade incomplete, VERSION kept at " ..
      localVersion() .. " (retry `apt upgrade`).\n")
    return 1
  end
  local vfd = fs.open("/VERSION", "w")
  if vfd then fs.write(vfd, remote .. "\n") fs.close(vfd) end
  local mfd = fs.open("/manifest", "w")
  if mfd then fs.write(mfd, man) fs.close(mfd) end
  -- Record the synced hashes so the next run needs no re-hashing.
  if sumsRaw and sums then
    local sfd = fs.open("/SHA256SUMS", "w")
    if sfd then fs.write(sfd, sumsRaw) fs.close(sfd) end
  end
  io.write("Upgraded to " .. remote .. ".\n")
  -- `apt upgrade` combines this with package upgrades, so it can defer the
  -- reboot prompt and ask once at the end.
  if kernelTouched and not (opts and opts.deferReboot) then
    term.write("Kernel updated. Reboot now? [y/N]: ")
    local ans = term.readLine() or ""
    if ans:sub(1, 1):lower() == "y" then freax.reboot() end
  end
  return 0, kernelTouched
end

-- Re-hash the installed tree against the recorded SHA256SUMS. Catches the
-- class of failure where an update reported success but a file never landed
-- (a refused rename looks exactly like a successful one). --repair
-- re-downloads only the files that differ.
function sysupdate.verify(opts)
  opts = opts or {}
  if not needNet() then return 1 end
  local text = fs.readFile("/SHA256SUMS")
  if not text then
    io.stderr:write("apt: no /SHA256SUMS recorded; run `apt sysupdate` first.\n")
    return 1
  end
  local sums = parseSums(text)
  local names = {}
  for path in pairs(sums) do names[#names + 1] = path end
  table.sort(names)
  local bad = {}
  io.write("Verifying " .. #names .. " files...\n")
  for _, path in ipairs(names) do
    if not (PRESERVE[path] or SKIP_DEV[path]) then
      if sha256File(path) ~= sums[path] then
        bad[#bad + 1] = path
        io.write("BAD  " .. path .. "\n")
      end
    end
  end
  if #bad == 0 then
    io.write("All installed files match.\n")
    return 0
  end
  io.write(string.format("%d of %d files differ.\n", #bad, #names))
  if not (opts.repair or opts.r) then
    io.write("Run `apt sysverify --repair` to re-download them.\n")
    return 1
  end
  if freax.geteuid() ~= 0 then
    io.stderr:write("apt: sysverify --repair requires root\n")
    return 1
  end
  local src = sysupdate.effectiveSource(opts)
  local fixed = 0
  for _, dst in ipairs(bad) do
    local tmp = dst .. ".apt-new"
    local parent = fs.dir(dst)
    if parent and parent ~= "/" and parent ~= "" then mkdirP(parent) end
    local ok, err = fetchToFile(src .. dst:sub(2), tmp)
    if not ok then
      io.stderr:write("  " .. dst .. ": " .. tostring(err) .. "\n")
    elseif sha256File(tmp) ~= sums[dst] then
      fs.remove(tmp)
      io.stderr:write("  " .. dst .. ": checksum mismatch on download\n")
    else
      local rok, rerr = replaceInstalled(tmp, dst, sums[dst])
      if rok then
        fixed = fixed + 1
        io.write("FIXED " .. dst .. "\n")
      else
        io.stderr:write("  " .. dst .. ": " .. tostring(rerr) .. "\n")
      end
    end
  end
  io.write(string.format("Repaired %d of %d files.\n", fixed, #bad))
  if kernelChanged(bad) then
    io.write("Kernel or boot files changed: reboot to apply.\n")
  end
  return fixed == #bad and 0 or 1
end

return sysupdate
