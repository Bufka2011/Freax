-- apt: package manager client (sources, indexes, resolver, pipelines).
-- Debian-style: deb lines in sources.list, dists/<suite>/Release plus
-- <comp>/binary-all/Packages, pool archives. Downloads stream to disk and
-- are SHA256/Size checked against the index. Package install/remove itself
-- is delegated to dpkg; this lib owns dependency resolution and the plan.

local fs = require("fs")

local apt = {}

apt.sourcesList = "/etc/apt/sources.list"
apt.sourcesDir  = "/etc/apt/sources.list.d"
apt.listsDir    = "/var/lib/apt/lists"
apt.archivesDir = "/var/cache/apt/archives"
apt.autoFile    = "/var/lib/apt/auto"

local PARTIAL_LISTS = apt.listsDir .. "/partial"
local PARTIAL_ARCH  = apt.archivesDir .. "/partial"

function apt.arch() return "all" end

------------------------------------------------------------------------------
-- small helpers

local function trim(s)
  return (tostring(s or ""):match("^%s*(.-)%s*$"))
end

local function mkdirP(path)
  local cur = ""
  for seg in tostring(path):gmatch("[^/]+") do
    cur = cur .. "/" .. seg
    if not fs.exists(cur) then fs.makeDirectory(cur) end
  end
end

local function ensureDirs()
  mkdirP(apt.listsDir)
  mkdirP(PARTIAL_LISTS)
  mkdirP(apt.archivesDir)
  mkdirP(PARTIAL_ARCH)
end

local function withSlash(u)
  u = tostring(u or "")
  if u:sub(-1) ~= "/" then u = u .. "/" end
  return u
end

-- GitHub raw serves stale copies after a push; a unique query bypasses it.
local function noCache(url)
  local sep = url:find("?", 1, true) and "&" or "?"
  return url .. sep .. "_=" .. tostring(math.random(1, 2147483647))
end

local function hashFile(path)
  local sha = require("sha256")
  local fd, err = fs.open(path, "r")
  if not fd then return nil, nil, err end
  local h = sha.new()
  local size = 0
  while true do
    local chunk = fs.read(fd, 4096)
    if not chunk then break end
    h:update(chunk)
    size = size + #chunk
  end
  fs.close(fd)
  return h:hex(), size
end

------------------------------------------------------------------------------
-- sources

local function parseDebLine(raw)
  local line = trim(raw)
  if line == "" or line:sub(1, 1) == "#" then return nil end
  local first, rest = line:match("^(%S+)%s*(.*)$")
  if first == "deb-src" then return nil end
  local options = {}
  if first == "deb" then
    if rest:sub(1, 1) == "[" then
      local close = rest:find("]", 1, true)
      if not close then return nil, "unterminated [options]" end
      for k, v in rest:sub(2, close - 1):gmatch("([%w%-_]+)=(%S+)") do
        options[k] = v
      end
      rest = trim(rest:sub(close + 1))
    end
    local uri, suite, comps = rest:match("^(%S+)%s+(%S+)%s+(.*)$")
    if not uri then
      uri, suite = rest:match("^(%S+)%s+(%S+)$")
      comps = "main"
    end
    if not uri or not suite then return nil, "malformed deb line" end
    local components = {}
    for c in comps:gmatch("%S+") do components[#components + 1] = c end
    if #components == 0 then components = { "main" } end
    return { uri = uri, suite = suite, components = components, options = options }
  end
  -- legacy bare URL: suite "freax", component "main"
  return { uri = first, suite = "freax", components = { "main" },
    options = {}, legacy = true }
end

function apt.readSources()
  ensureDirs()
  local sources = {}
  local function readFile(path, fname)
    local data = fs.readFile(path)
    if not data then return end
    local n = 0
    for raw in (data .. "\n"):gmatch("(.-)\n") do
      n = n + 1
      local s = parseDebLine(raw)
      if s then
        s.file = fname
        s.line = n
        s.raw = trim(raw)
        sources[#sources + 1] = s
      end
    end
  end
  readFile(apt.sourcesList, apt.sourcesList)
  local ok, entries = pcall(fs.list, apt.sourcesDir)
  if ok and type(entries) == "table" then
    local names = {}
    for _, name in ipairs(entries) do
      if name:sub(-5) == ".list" then names[#names + 1] = name end
    end
    table.sort(names)
    for _, name in ipairs(names) do
      readFile(apt.sourcesDir .. "/" .. name, apt.sourcesDir .. "/" .. name)
    end
  end
  return sources
end

local function mangle(uri)
  return (tostring(uri):gsub("[/:]", "_"))
end

function apt.listPath(source, component)
  return apt.listsDir .. "/" .. mangle(source.uri) .. "_" .. source.suite
    .. "_" .. component .. "_binary-all_Packages"
end

function apt.releasePath(source)
  return apt.listsDir .. "/" .. mangle(source.uri) .. "_" .. source.suite
    .. "_Release"
end

------------------------------------------------------------------------------
-- network

function apt.fetchText(url, limit)
  if not freax.netAvail() then return nil, "needs an internet card" end
  local internet = require("internet")
  limit = limit or 262144
  local ok, handle = pcall(internet.request, noCache(url), nil,
    { ["user-agent"] = "Apt/Freax" })
  if not ok then return nil, tostring(handle) end
  local parts, total = {}, 0
  local ok2, err = pcall(function()
    for chunk in handle do
      parts[#parts + 1] = chunk
      total = total + #chunk
      if total > limit then error("response too large") end
    end
  end)
  if not ok2 then return nil, tostring(err) end
  return table.concat(parts)
end

-- Stream a remote file to disk; never hold a whole archive in RAM.
function apt.fetchToFile(url, dest)
  if not freax.netAvail() then return nil, "needs an internet card" end
  local internet = require("internet")
  local ok, handle = pcall(internet.request, url, nil,
    { ["user-agent"] = "Apt/Freax" })
  if not ok then return nil, tostring(handle) end
  local fd, oerr = fs.open(dest, "w")
  if not fd then return nil, tostring(oerr or ("cannot write " .. dest)) end
  local ok2, werr = pcall(function()
    for chunk in handle do
      local wok, wmsg = fs.write(fd, chunk)
      if not wok then error(tostring(wmsg or "write failed")) end
    end
  end)
  fs.close(fd)
  if not ok2 then
    fs.remove(dest)
    return nil, tostring(werr)
  end
  return true
end

local function downloadFile(uri, dest)
  ensureDirs()
  dest = dest or (apt.archivesDir .. "/" .. (uri:match("([^/]+)$") or "download"))
  local base = dest:match("([^/]+)$") or "part"
  local tmp = PARTIAL_ARCH .. "/" .. base .. ".part"
  local ok, err = apt.fetchToFile(uri, tmp)
  if not ok then return nil, err end
  if fs.exists(dest) then fs.remove(dest) end
  local rok, rerr = fs.rename(tmp, dest)
  if not rok then
    fs.remove(tmp)
    return nil, tostring(rerr or "rename failed")
  end
  return true
end

function apt.downloadTo(uri)
  return downloadFile(uri)
end

------------------------------------------------------------------------------
-- index update

local function parseRelease(text)
  local hashes, inSha = {}, false
  for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    if line:match("^%S") then
      inSha = line:match("^SHA256:") and true or false
    elseif inSha then
      local hash, size, path = line:match("^%s*(%x%x%x%x+)%s+(%d+)%s+(.+%S)%s*$")
      if hash then
        hashes[path] = { sha256 = hash:lower(), size = tonumber(size) }
      end
    end
  end
  return hashes
end

local indexCache

local function invalidateIndex() indexCache = nil end

function apt.update(opts)
  opts = opts or {}
  ensureDirs()
  if not freax.netAvail() then return nil, "needs an internet card" end
  local sources = apt.readSources()
  local summary = { sources = #sources, components = 0, fetched = 0, failed = {} }
  for _, src in ipairs(sources) do
    local base = src.uri:gsub("/+$", "")
    local releaseUrl = base .. "/dists/" .. src.suite .. "/Release"
    local body, err = apt.fetchText(releaseUrl, 262144)
    if not body then
      summary.failed[#summary.failed + 1] = src.uri .. ": " .. tostring(err)
    else
      local hashes = parseRelease(body)
      local rfd = fs.open(apt.releasePath(src), "w")
      if rfd then fs.write(rfd, body) fs.close(rfd) end
      for _, comp in ipairs(src.components) do
        summary.components = summary.components + 1
        local rel = comp .. "/binary-all/Packages"
        local url = base .. "/dists/" .. src.suite .. "/" .. rel
        local lp = apt.listPath(src, comp)
        local tmp = PARTIAL_LISTS .. "/" .. (lp:match("([^/]+)$")) .. ".part"
        local ok, derr = apt.fetchToFile(noCache(url), tmp)
        if not ok then
          summary.failed[#summary.failed + 1] = url .. ": " .. tostring(derr)
        else
          local expect = hashes[rel]
          local got, gsize = hashFile(tmp)
          if expect and (got ~= expect.sha256 or gsize ~= expect.size) then
            fs.remove(tmp)
            summary.failed[#summary.failed + 1] = url .. ": SHA256 mismatch"
          else
            if fs.exists(lp) then fs.remove(lp) end
            local rok, rerr = fs.rename(tmp, lp)
            if not rok then
              fs.remove(tmp)
              summary.failed[#summary.failed + 1] = url .. ": " .. tostring(rerr)
            else
              summary.fetched = summary.fetched + 1
            end
          end
        end
      end
    end
  end
  invalidateIndex()
  return summary
end

------------------------------------------------------------------------------
-- index queries

function apt.loadIndex()
  if indexCache then return indexCache end
  local fpkg = require("fpkg")
  local index = {}
  for _, src in ipairs(apt.readSources()) do
    for _, comp in ipairs(src.components) do
      local data = fs.readFile(apt.listPath(src, comp))
      if data then
        for _, st in ipairs(fpkg.parseStanzas(data)) do
          local f = st.fields
          local name, ver = f.Package, f.Version
          if name and ver then
            index[name] = index[name] or {}
            if not index[name][ver] then
              index[name][ver] = {
                fields = f,
                uri = src.uri,
                component = comp,
                filename = f.Filename,
                sha256 = f.SHA256 and f.SHA256:lower() or nil,
                size = tonumber(f.Size),
              }
            end
          end
        end
      end
    end
  end
  indexCache = index
  return index
end

local function bestCandidate(name, op, ver)
  local fpkg = require("fpkg")
  local byver = apt.loadIndex()[name]
  if not byver then return nil end
  local best
  for _, c in pairs(byver) do
    if not op or fpkg.satisfies(c.fields.Version, op, ver) then
      if not best or fpkg.versionCompare(c.fields.Version, best.fields.Version) > 0 then
        best = c
      end
    end
  end
  return best
end

local providesName

-- Packages that Provide a (possibly virtual) name; newest version each.
local function providerCandidates(name, op, ver)
  local fpkg = require("fpkg")
  local out = {}
  for _, byver in pairs(apt.loadIndex()) do
    local best
    for _, c in pairs(byver) do
      if not best or fpkg.versionCompare(c.fields.Version, best.fields.Version) > 0 then
        best = c
      end
    end
    if best and providesName(best.fields, name, op, ver) then
      out[#out + 1] = best
    end
  end
  table.sort(out, function(a, b) return a.fields.Package < b.fields.Package end)
  return out
end

local function candidatesFor(opt)
  local out = {}
  local direct = bestCandidate(opt.name, opt.op, opt.version)
  if direct then out[#out + 1] = direct end
  for _, pc in ipairs(providerCandidates(opt.name, opt.op, opt.version)) do
    out[#out + 1] = pc
  end
  return out
end

function apt.candidate(name, wantVersion)
  local byver = apt.loadIndex()[name]
  if not byver then return nil end
  if wantVersion then return byver[wantVersion] end
  local best
  for _, c in pairs(byver) do
    if not best or require("fpkg").versionCompare(c.fields.Version,
      best.fields.Version) > 0 then
      best = c
    end
  end
  return best
end

function apt.versions(name)
  local byver = apt.loadIndex()[name]
  local out = {}
  if byver then
    for _, c in pairs(byver) do out[#out + 1] = c end
    table.sort(out, function(a, b)
      return require("fpkg").versionCompare(a.fields.Version,
        b.fields.Version) > 0
    end)
  end
  return out
end

function apt.search(pattern)
  local pl = tostring(pattern or ""):lower()
  local names = {}
  for name in pairs(apt.loadIndex()) do names[#names + 1] = name end
  table.sort(names)
  local out = {}
  for _, name in ipairs(names) do
    local cand = apt.candidate(name)
    local f = cand and cand.fields
    if f then
      local hay = (name .. " " .. (f.Description or "")):lower()
      if hay:find(pl, 1, true) then out[#out + 1] = f end
    end
  end
  return out
end

function apt.show(name)
  local vs = apt.versions(name)
  if #vs == 0 then return nil end
  if #vs == 1 then return vs[1].fields end
  local out = {}
  for _, c in ipairs(vs) do out[#out + 1] = c.fields end
  return out
end

local function installedMap()
  local dpkg = require("dpkg")
  local m = {}
  for _, f in ipairs(dpkg.list()) do
    local st = f.Status or ""
    if st == "" or st:find("ok installed", 1, true)
      or st:find("ok unpacked", 1, true)
      or st:find("ok half-configured", 1, true)
      or st:find("ok half-installed", 1, true) then
      m[f.Package] = { version = f.Version, fields = f }
    end
  end
  return m
end

function apt.listInstalled()
  return require("dpkg").list()
end

function apt.listUpgradable()
  local fpkg = require("fpkg")
  local out = {}
  for name, ins in pairs(installedMap()) do
    local cand = apt.candidate(name)
    if cand and fpkg.versionCompare(cand.fields.Version, ins.version) > 0 then
      out[#out + 1] = {
        name = name,
        installed = ins.version,
        candidate = cand,
        installedVersion = ins.version,
        candidateVersion = cand.fields.Version,
      }
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

function apt.clean(opts)
  opts = opts or {}
  ensureDirs()
  local keep
  if opts.auto then
    keep = {}
    for name, byver in pairs(apt.loadIndex()) do
      for ver in pairs(byver) do
        keep[name .. "_" .. ver .. "_all.fpkg"] = true
      end
    end
  end
  local ok, entries = pcall(fs.list, apt.archivesDir)
  if ok and type(entries) == "table" then
    for _, e in ipairs(entries) do
      if e:sub(-5) == ".fpkg" and not (keep and keep[e]) then
        fs.remove(apt.archivesDir .. "/" .. e)
      end
    end
  end
  return true
end

function apt.download(names, opts)
  opts = opts or {}
  ensureDirs()
  local paths = {}
  for _, arg in ipairs(names) do
    local name, ver = arg:match("^([^=]+)=(.*)$")
    if not name then name, ver = arg, nil end
    local cand = ver and apt.candidate(name, ver) or apt.candidate(name)
    if not cand then return nil, "unable to locate package " .. name end
    if not cand.filename then return nil, name .. ": no Filename in index" end
    local dest = apt.archivesDir .. "/" .. name .. "_" .. cand.fields.Version
      .. "_all.fpkg"
    if not fs.exists(dest) or opts.reinstall then
      local base = cand.uri:gsub("/+$", "")
      local ok, err = downloadFile(base .. "/" .. cand.filename, dest)
      if not ok then return nil, name .. ": " .. tostring(err) end
    end
    local got, gsize = hashFile(dest)
    if cand.sha256 and got ~= cand.sha256 then
      fs.remove(dest)
      return nil, name .. ": SHA256 mismatch"
    end
    if cand.size and gsize ~= cand.size then
      fs.remove(dest)
      return nil, name .. ": size mismatch"
    end
    paths[#paths + 1] = dest
  end
  return paths
end

------------------------------------------------------------------------------
-- dependency resolver

local function depsOf(fields, key)
  local s = fields[key]
  if not s or s == "" then return {} end
  return require("fpkg").parseDepends(s)
end

providesName = function(fields, depName, op, ver)
  local s = fields.Provides
  if not s or s == "" then return false end
  local fpkg = require("fpkg")
  for _, group in ipairs(fpkg.parseDepends(s)) do
    for _, opt in ipairs(group) do
      if opt.name == depName then
        if not op then return true end
        if opt.version and fpkg.satisfies(opt.version, op, ver) then return true end
      end
    end
  end
  return false
end

local function optionSatisfied(opt, ctx)
  local fpkg = require("fpkg")
  local sc = ctx.sel[opt.name]
  if sc and (not opt.op or fpkg.satisfies(sc.fields.Version, opt.op, opt.version)) then
    return true
  end
  local ins = ctx.installed[opt.name]
  if ins and not ctx.removing[opt.name]
    and (not opt.op or fpkg.satisfies(ins.version, opt.op, opt.version)) then
    return true
  end
  for _, c in pairs(ctx.sel) do
    if providesName(c.fields, opt.name, opt.op, opt.version) then return true end
  end
  for name, ins2 in pairs(ctx.installed) do
    if not ctx.removing[name]
      and providesName(ins2.fields, opt.name, opt.op, opt.version) then
      return true
    end
  end
  return false
end

local function groupSatisfied(ctx, group)
  for _, opt in ipairs(group) do
    if optionSatisfied(opt, ctx) then return true end
  end
  return false
end

-- The already-selected candidate satisfying an option (direct or Provides).
local function selectedSatisfier(opt, ctx)
  local fpkg = require("fpkg")
  local sc = ctx.sel[opt.name]
  if sc and (not opt.op or fpkg.satisfies(sc.fields.Version, opt.op, opt.version)) then
    return sc
  end
  for _, c in pairs(ctx.sel) do
    if providesName(c.fields, opt.name, opt.op, opt.version) then return c end
  end
  return nil
end

local function groupString(group)
  local parts = {}
  for _, opt in ipairs(group) do
    local s = opt.name
    if opt.op then s = s .. " (" .. opt.op .. " " .. tostring(opt.version) .. ")" end
    parts[#parts + 1] = s
  end
  return table.concat(parts, " | ")
end

local function selectPkg(ctx, name, cand)
  local prev = ctx.sel[name]
  if prev and prev.fields.Version == cand.fields.Version then return false end
  ctx.journal[#ctx.journal + 1] = { name = name, prev = prev }
  ctx.sel[name] = cand
  if prev then ctx.resolved[name] = nil end
  return true
end

local function rollback(ctx, jmark, omark)
  while #ctx.journal > jmark do
    local e = table.remove(ctx.journal)
    ctx.sel[e.name] = e.prev
    ctx.resolved[e.name] = nil
  end
  while #ctx.order > omark do table.remove(ctx.order) end
end

local resolveGroup, resolveCandidate

resolveGroup = function(ctx, group)
  if groupSatisfied(ctx, group) then
    -- a selected-but-unresolved dependency must land in the order first
    for _, opt in ipairs(group) do
      local s = selectedSatisfier(opt, ctx)
      if s and not ctx.resolved[s.fields.Package]
        and not ctx.resolving[s.fields.Package] then
        local ok, err = resolveCandidate(ctx, s)
        if not ok then return false, err end
      end
    end
    return true
  end
  for _, opt in ipairs(group) do
    if not ctx.removing[opt.name] then
      for _, cand in ipairs(candidatesFor(opt)) do
        local jmark, omark = #ctx.journal, #ctx.order
        selectPkg(ctx, cand.fields.Package, cand)
        if optionSatisfied(opt, ctx) then
          local ok = resolveCandidate(ctx, cand)
          if ok then return true end
        end
        rollback(ctx, jmark, omark)
      end
    end
  end
  return false, "unmet dependency: " .. groupString(group)
end

resolveCandidate = function(ctx, cand)
  local name = cand.fields.Package
  if ctx.resolved[name] or ctx.resolving[name] then return true end
  ctx.resolving[name] = true
  for _, key in ipairs({ "Pre-Depends", "Depends" }) do
    for _, group in ipairs(depsOf(cand.fields, key)) do
      local ok, err = resolveGroup(ctx, group)
      if not ok then
        ctx.resolving[name] = nil
        return false, err
      end
    end
  end
  if not ctx.noRecommends then
    for _, group in ipairs(depsOf(cand.fields, "Recommends")) do
      if not groupSatisfied(ctx, group) then
        local picked = false
        for _, opt in ipairs(group) do
          if not picked and not ctx.removing[opt.name] then
            for _, c2 in ipairs(candidatesFor(opt)) do
              local jmark, omark = #ctx.journal, #ctx.order
              selectPkg(ctx, c2.fields.Package, c2)
              if not resolveCandidate(ctx, c2) then
                rollback(ctx, jmark, omark)
              else
                picked = true
                break
              end
            end
          end
        end
      end
    end
  end
  ctx.resolving[name] = nil
  ctx.resolved[name] = true
  ctx.order[#ctx.order + 1] = cand
  return true
end

local function conflictPass(ctx, opts)
  local fpkg = require("fpkg")
  local toRemove = {}
  for name, cand in pairs(ctx.sel) do
    for _, key in ipairs({ "Conflicts", "Breaks" }) do
      for _, group in ipairs(depsOf(cand.fields, key)) do
        for _, opt in ipairs(group) do
          local other = ctx.sel[opt.name]
          if other and (not opt.op
            or fpkg.satisfies(other.fields.Version, opt.op, opt.version)) then
            return nil, "conflict: " .. name .. " conflicts with " .. opt.name
          end
          local ins = ctx.installed[opt.name]
          if ins and not ctx.sel[opt.name] and not ctx.removing[opt.name]
            and (not opt.op
              or fpkg.satisfies(ins.version, opt.op, opt.version)) then
            if opts.full or opts.force then
              ctx.removing[opt.name] = true
              toRemove[#toRemove + 1] = opt.name
            else
              return nil, name .. " conflicts with installed " .. opt.name
            end
          end
        end
      end
    end
  end
  return toRemove
end

function apt.resolveInstall(names, opts)
  opts = opts or {}
  local ctx = {
    installed = installedMap(),
    sel = {}, journal = {}, order = {}, resolved = {}, resolving = {},
    removing = {},
    noRecommends = opts.noInstallRecommends,
  }
  local roots = {}
  for _, arg in ipairs(names) do
    local name, ver = arg:match("^([^=]+)=(.*)$")
    if not name then name, ver = arg, nil end
    local cand = ver and bestCandidate(name, "=", ver) or bestCandidate(name)
    if not cand then return nil, "unable to locate package " .. tostring(name) end
    selectPkg(ctx, name, cand)
    roots[#roots + 1] = name
  end
  for _, name in ipairs(roots) do
    local cand = ctx.sel[name]
    if cand and not ctx.resolved[name] then
      local ok, err = resolveCandidate(ctx, cand)
      if not ok then return nil, err end
    end
  end
  local toRemove, cerr = conflictPass(ctx, opts)
  if not toRemove then return nil, cerr end
  return { order = ctx.order, toRemove = toRemove, sel = ctx.sel }
end

local function dependsOn(fields, depName)
  for _, key in ipairs({ "Depends", "Pre-Depends" }) do
    for _, group in ipairs(depsOf(fields, key)) do
      for _, opt in ipairs(group) do
        if opt.name == depName then return true end
      end
    end
  end
  return false
end

local function groupSatisfiedRemaining(group, installed, removing)
  local fpkg = require("fpkg")
  for _, opt in ipairs(group) do
    local ins = installed[opt.name]
    if ins and not removing[opt.name]
      and (not opt.op or fpkg.satisfies(ins.version, opt.op, opt.version)) then
      return true
    end
    for name, pins in pairs(installed) do
      if not removing[name]
        and providesName(pins.fields, opt.name, opt.op, opt.version) then
        return true
      end
    end
  end
  return false
end

local function breaksWithout(fields, installed, removing)
  for _, key in ipairs({ "Depends", "Pre-Depends" }) do
    for _, group in ipairs(depsOf(fields, key)) do
      if not groupSatisfiedRemaining(group, installed, removing) then
        return true
      end
    end
  end
  return false
end

function apt.resolveRemove(names, opts)
  opts = opts or {}
  local installed = installedMap()
  local removing = {}
  for _, name in ipairs(names) do
    if not installed[name] then return nil, name .. " is not installed" end
    removing[name] = true
  end
  if opts.auto then
    local changed = true
    while changed do
      changed = false
      for name, ins in pairs(installed) do
        if not removing[name] and breaksWithout(ins.fields, installed, removing) then
          removing[name] = true
          changed = true
        end
      end
    end
  end
  if not opts.force then
    for name, ins in pairs(installed) do
      if not removing[name] and breaksWithout(ins.fields, installed, removing) then
        return nil, "removing would break " .. name
          .. " (use --force or --autoremove)"
      end
    end
  end
  local result, seen = {}, {}
  local visit
  visit = function(name)
    if seen[name] then return end
    seen[name] = true
    for other, oins in pairs(installed) do
      if removing[other] and not seen[other] and dependsOn(oins.fields, name) then
        visit(other)
      end
    end
    result[#result + 1] = name
  end
  for _, name in ipairs(names) do visit(name) end
  for name in pairs(removing) do visit(name) end
  return { order = result, toRemove = result }
end

------------------------------------------------------------------------------
-- pipelines

local function loadAuto()
  local set = {}
  local data = fs.readFile(apt.autoFile)
  if data then
    for line in data:gmatch("[^\n]+") do set[trim(line)] = true end
  end
  return set
end

local function saveAuto(set)
  mkdirP(apt.autoFile:match("^(.*)/[^/]*$") or "/var/lib/apt")
  local names = {}
  for n in pairs(set) do names[#names + 1] = n end
  table.sort(names)
  local text = #names > 0 and (table.concat(names, "\n") .. "\n") or ""
  fs.writeFile(apt.autoFile, text)
end

local function confirm(prompt)
  local term = require("term")
  term.write(prompt or "Do you want to continue? [Y/n] ")
  local ans = term.readLine() or ""
  return ans == "" or ans:sub(1, 1):lower() == "y"
end

local function printPlan(plan, opts, installed)
  if opts.quiet then return end
  installed = installed or installedMap()
  local new, up, re, rem = {}, {}, {}, {}
  for _, cand in ipairs(plan.order) do
    local name = cand.fields.Package
    local ins = installed[name]
    if not ins then
      new[#new + 1] = name
    elseif ins.version == cand.fields.Version then
      if opts.reinstall then re[#re + 1] = name end
    else
      up[#up + 1] = name .. " (" .. ins.version .. " -> "
        .. cand.fields.Version .. ")"
    end
  end
  for _, name in ipairs(plan.toRemove or {}) do rem[#rem + 1] = name end
  local function list(label, t)
    if #t == 0 then return end
    io.write(label .. "\n")
    for _, n in ipairs(t) do io.write("  " .. n .. "\n") end
  end
  list("The following NEW packages will be installed:", new)
  list("The following packages will be upgraded:", up)
  list("The following packages will be reinstalled:", re)
  list("The following packages will be REMOVED:", rem)
  if #new + #up + #re + #rem == 0 then
    io.write("Nothing to do.\n")
  else
    io.write(string.format("%d upgraded, %d newly installed, %d to remove.\n",
      #up, #new, #rem))
  end
end

local function runPlan(plan, requested, opts)
  opts = opts or {}
  local dpkg = require("dpkg")
  local installed = installedMap()
  -- already-newest roots need no work unless --reinstall
  local todo = {}
  for _, cand in ipairs(plan.order) do
    local name = cand.fields.Package
    local ins = installed[name]
    if not (ins and ins.version == cand.fields.Version and not opts.reinstall) then
      todo[#todo + 1] = cand
    end
  end
  printPlan(plan, opts, installed)
  if #todo == 0 and #(plan.toRemove or {}) == 0 then return true end
  if not opts.yes and not opts.downloadOnly then
    if not confirm() then return nil, "aborted" end
  end
  local paths = {}
  for _, cand in ipairs(todo) do
    local name = cand.fields.Package
    local dest = apt.archivesDir .. "/" .. name .. "_" .. cand.fields.Version
      .. "_all.fpkg"
    if not fs.exists(dest) or opts.reinstall then
      if not cand.filename then return nil, name .. ": no Filename in index" end
      if not freax.netAvail() then return nil, "needs an internet card" end
      local base = cand.uri:gsub("/+$", "")
      local ok, derr = downloadFile(base .. "/" .. cand.filename, dest)
      if not ok then return nil, name .. ": " .. tostring(derr) end
    end
    local got, gsize = hashFile(dest)
    if cand.sha256 and got ~= cand.sha256 then
      fs.remove(dest)
      return nil, name .. ": SHA256 mismatch"
    end
    if cand.size and gsize ~= cand.size then
      fs.remove(dest)
      return nil, name .. ": size mismatch"
    end
    paths[name] = dest
  end
  if opts.downloadOnly then return true end
  for _, rname in ipairs(plan.toRemove or {}) do
    local ok, rerr = dpkg.remove(rname, { purge = opts.purge })
    if not ok then return nil, "remove " .. rname .. ": " .. tostring(rerr) end
  end
  for _, cand in ipairs(todo) do
    local name = cand.fields.Package
    local ok, ierr = dpkg.installFile(paths[name], { reinstall = opts.reinstall })
    if not ok then return nil, "install " .. name .. ": " .. tostring(ierr) end
  end
  local auto = loadAuto()
  local req = {}
  for _, r in ipairs(requested or {}) do
    local n = r:match("^([^=]+)") or r
    req[n] = true
    auto[n] = nil
  end
  for _, cand in ipairs(plan.order) do
    local n = cand.fields.Package
    if not req[n] and not installed[n] then auto[n] = true end
  end
  for _, r in ipairs(plan.toRemove or {}) do auto[r] = nil end
  saveAuto(auto)
  return true
end

function apt.install(names, opts)
  opts = opts or {}
  if #names == 0 then return nil, "no packages given" end
  local plan, err = apt.resolveInstall(names, opts)
  if not plan then return nil, err end
  return runPlan(plan, names, opts)
end

function apt.reinstall(names, opts)
  opts = opts or {}
  opts.reinstall = true
  return apt.install(names, opts)
end

function apt.remove(names, opts)
  opts = opts or {}
  if #names == 0 then return nil, "no packages given" end
  local plan, err = apt.resolveRemove(names, opts)
  if not plan then return nil, err end
  if not opts.quiet then
    io.write("The following packages will be REMOVED:\n")
    for _, n in ipairs(plan.order) do io.write("  " .. n .. "\n") end
  end
  if not opts.yes then
    if not confirm("Remove the above packages? [Y/n] ") then
      return nil, "aborted"
    end
  end
  local dpkg = require("dpkg")
  for _, name in ipairs(plan.order) do
    local ok, rerr = dpkg.remove(name, { purge = opts.purge })
    if not ok then return nil, name .. ": " .. tostring(rerr) end
  end
  local auto = loadAuto()
  for _, name in ipairs(plan.order) do auto[name] = nil end
  saveAuto(auto)
  if opts.autoremove then apt.autoremove(opts) end
  return true
end

local function upgradableNames()
  local names = {}
  for _, u in ipairs(apt.listUpgradable()) do names[#names + 1] = u.name end
  return names
end

function apt.upgrade(opts)
  opts = opts or {}
  local names = upgradableNames()
  if #names == 0 then
    if not opts.quiet then io.write("0 upgraded, 0 newly installed, 0 to remove.\n") end
    return true
  end
  local plan, err = apt.resolveInstall(names, opts)
  if not plan then return nil, err end
  if #(plan.toRemove or {}) > 0 and not opts.force then
    return nil, "upgrade would remove packages; run full-upgrade"
  end
  return runPlan(plan, names, opts)
end

function apt.fullUpgrade(opts)
  opts = opts or {}
  opts.full = true
  local names = upgradableNames()
  if #names == 0 then
    if not opts.quiet then io.write("0 upgraded, 0 newly installed, 0 to remove.\n") end
    return true
  end
  local plan, err = apt.resolveInstall(names, opts)
  if not plan then return nil, err end
  return runPlan(plan, names, opts)
end

function apt.autoremove(opts)
  opts = opts or {}
  local auto = loadAuto()
  local installed = installedMap()
  local needed = {}
  local function mark(name)
    if needed[name] then return end
    needed[name] = true
    local ins = installed[name]
    if not ins then return end
    for _, key in ipairs({ "Depends", "Pre-Depends" }) do
      for _, group in ipairs(depsOf(ins.fields, key)) do
        for _, opt in ipairs(group) do
          if installed[opt.name] and not auto[opt.name] then mark(opt.name) end
        end
      end
    end
  end
  for name in pairs(installed) do
    if not auto[name] then mark(name) end
  end
  local toRemove = {}
  for name in pairs(auto) do
    if installed[name] and not needed[name] then toRemove[#toRemove + 1] = name end
  end
  table.sort(toRemove)
  if #toRemove == 0 then
    if not opts.quiet then
      io.write("0 upgraded, 0 newly installed, 0 to remove.\n")
    end
    return true
  end
  local plan, err = apt.resolveRemove(toRemove, { auto = true, force = opts.force })
  if not plan then return nil, err end
  if not opts.quiet then
    io.write("The following packages will be REMOVED:\n")
    for _, n in ipairs(toRemove) do io.write("  " .. n .. "\n") end
  end
  if not opts.yes then
    if not confirm("Remove the above packages? [Y/n] ") then
      return nil, "aborted"
    end
  end
  local dpkg = require("dpkg")
  for _, name in ipairs(plan.order) do
    local ok, rerr = dpkg.remove(name, { purge = opts.purge })
    if not ok then return nil, name .. ": " .. tostring(rerr) end
  end
  local a = loadAuto()
  for _, n in ipairs(toRemove) do a[n] = nil end
  saveAuto(a)
  return true
end

return apt
