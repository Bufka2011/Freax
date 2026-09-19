-- apt: Freax package manager CLI (Debian-style).
-- Subcommands: update, upgrade, full-upgrade|dist-upgrade, install,
-- reinstall, remove|rm, purge, autoremove, search, show|info, list,
-- policy, download, clean, autoclean, source|sources, version, help.
-- Legacy OS self-update: sysupdate, sysupgrade (manifest-based, see
-- lib/sysupdate.lua) and `sources --os`.

local fs = require("fs")
local shell = require("shell")
local apt = require("apt")

local args, raw = shell.parse(...)
local cmd = args[1]

local FIELD_ORDER = {
  "Package", "Version", "Architecture", "Maintainer", "Installed-Size",
  "Depends", "Pre-Depends", "Recommends", "Suggests", "Conflicts", "Breaks",
  "Replaces", "Provides", "Section", "Priority", "Essential", "Homepage",
  "Description", "Filename", "Size", "SHA256", "Status",
}

local function normOpts()
  return {
    yes = raw.yes or raw.y,
    force = raw.force or raw.f,
    quiet = raw.quiet or raw.q,
    verbose = raw.V or raw.verbose,
    downloadOnly = raw["download-only"] or raw.downloadOnly,
    noInstallRecommends = raw["no-install-recommends"] or raw.noInstallRecommends,
    reinstall = raw.reinstall,
    purge = raw.purge,
    autoremove = raw.autoremove,
    source = raw.source,
    installed = raw.installed,
    upgradable = raw.upgradable,
    all = raw.all,
    os = raw.os,
  }
end

local function usage()
  local lines = {
    "Usage: apt <command> [options] [package...]",
    "",
    "Commands:",
    "  update            refresh package indexes from sources",
    "  upgrade           upgrade installed packages",
    "  full-upgrade      upgrade, also add/remove packages as needed",
    "  install <pkg...>  install packages",
    "  reinstall <pkg...> reinstall packages",
    "  remove|rm <pkg...> remove packages",
    "  purge <pkg...>    remove packages and their conffiles",
    "  autoremove        remove automatically installed orphans",
    "  search <pattern>  search available packages",
    "  show|info <pkg>   show package details",
    "  list [--installed|--upgradable|pattern]",
    "  policy [pkg]      show installed/candidate versions",
    "  download <pkg...> download packages only",
    "  clean|autoclean   clear the package cache",
    "  source|sources    show package sources",
    "  version           show OS and apt versions",
    "",
    "Options: -y/--yes --force/-f -q/--quiet -V --download-only",
    "         --no-install-recommends --reinstall --purge --autoremove",
    "",
    "Legacy OS update:",
    "  sysupdate [--source=URL] [--yes]",
    "  sysupgrade [--source=URL] [--yes] [--force]",
    "  sources --os",
  }
  for _, l in ipairs(lines) do io.write(l .. "\n") end
end

local function fieldOrder(fields)
  local order, seen = {}, {}
  for _, k in ipairs(FIELD_ORDER) do
    if fields[k] ~= nil then
      order[#order + 1] = k
      seen[k] = true
    end
  end
  local extra = {}
  for k in pairs(fields) do if not seen[k] then extra[#extra + 1] = k end end
  table.sort(extra)
  for _, k in ipairs(extra) do order[#order + 1] = k end
  return order
end

local function showFields(fields)
  local fpkg = require("fpkg")
  io.write(fpkg.serializeControl(fields, fieldOrder(fields)))
end

local function run()
  local o = normOpts()

  if not cmd or cmd == "help" or raw.help or cmd == "--help" then
    usage()
    return 0
  end

  if cmd == "sysupdate" then
    return require("sysupdate").update(o)
  end
  if cmd == "sysupgrade" then
    return require("sysupdate").upgrade(o)
  end

  if cmd == "version" then
    require("sysupdate").version()
    io.write("apt 1.0 (freax package manager)\n")
    if pcall(require, "dpkg") then io.write("dpkg (freax)\n") end
    return 0
  end

  if cmd == "source" or cmd == "sources" then
    if o.os then return require("sysupdate").sources(o) end
    local sources = apt.readSources()
    if #sources == 0 then
      io.write("No package sources configured.\n")
    else
      for _, s in ipairs(sources) do
        io.write(string.format("deb %s %s %s\n", s.uri, s.suite,
          table.concat(s.components, " ")))
      end
    end
    return 0
  end

  if cmd == "update" then
    local summary, err = apt.update(o)
    if not summary then
      io.stderr:write("apt: " .. tostring(err) .. "\n")
      return 1
    end
    io.write(string.format("Fetched %d/%d index files from %d sources.\n",
      summary.fetched, summary.components, summary.sources))
    for _, f in ipairs(summary.failed) do
      io.stderr:write("  W: " .. f .. "\n")
    end
    if #summary.failed > 0 then
      io.stderr:write("apt: some indexes failed to update.\n")
      return 1
    end
    return 0
  end

  if cmd == "upgrade" then
    local ok, err = apt.upgrade(o)
    if not ok then
      io.stderr:write("apt: " .. tostring(err) .. "\n")
      return 1
    end
    return 0
  end

  if cmd == "full-upgrade" or cmd == "dist-upgrade" then
    local ok, err = apt.fullUpgrade(o)
    if not ok then
      io.stderr:write("apt: " .. tostring(err) .. "\n")
      return 1
    end
    return 0
  end

  if cmd == "install" then
    local pkgs = {}
    for i = 2, #args do pkgs[#pkgs + 1] = args[i] end
    local ok, err = apt.install(pkgs, o)
    if not ok then
      io.stderr:write("apt: " .. tostring(err) .. "\n")
      return 1
    end
    return 0
  end

  if cmd == "reinstall" then
    local pkgs = {}
    for i = 2, #args do pkgs[#pkgs + 1] = args[i] end
    local ok, err = apt.reinstall(pkgs, o)
    if not ok then
      io.stderr:write("apt: " .. tostring(err) .. "\n")
      return 1
    end
    return 0
  end

  if cmd == "remove" or cmd == "rm" or cmd == "purge" then
    if cmd == "purge" then o.purge = true end
    local pkgs = {}
    for i = 2, #args do pkgs[#pkgs + 1] = args[i] end
    local ok, err = apt.remove(pkgs, o)
    if not ok then
      io.stderr:write("apt: " .. tostring(err) .. "\n")
      return 1
    end
    return 0
  end

  if cmd == "autoremove" then
    local ok, err = apt.autoremove(o)
    if not ok then
      io.stderr:write("apt: " .. tostring(err) .. "\n")
      return 1
    end
    return 0
  end

  if cmd == "search" then
    local pattern = args[2] or ""
    for _, f in ipairs(apt.search(pattern)) do
      local desc = (f.Description or ""):gsub("\n.*$", "")
      io.write(string.format("%-28s %s\n",
        f.Package .. "/" .. tostring(f.Version), desc))
    end
    return 0
  end

  if cmd == "show" or cmd == "info" then
    if #args < 2 then
      io.stderr:write("apt: no package given\n")
      return 1
    end
    local rc = 0
    for i = 2, #args do
      local res = apt.show(args[i])
      if not res then
        io.stderr:write("N: Unable to locate package " .. args[i] .. "\n")
        rc = 1
      elseif res.Package then
        showFields(res)
        io.write("\n")
      else
        for _, f in ipairs(res) do
          showFields(f)
          io.write("\n")
        end
      end
    end
    return rc
  end

  if cmd == "list" then
    if o.installed then
      for _, f in ipairs(apt.listInstalled()) do
        io.write(string.format("%s/%s %s\n", tostring(f.Package),
          tostring(f.Version), f.Status or "installed"))
      end
    elseif o.upgradable then
      for _, u in ipairs(apt.listUpgradable()) do
        io.write(string.format("%s/%s %s [upgradable from: %s]\n",
          u.name, u.candidateVersion, u.candidate.uri, u.installed))
      end
    else
      local pattern = args[2] or ""
      for _, f in ipairs(apt.search(pattern)) do
        io.write(string.format("%s/%s\n", tostring(f.Package),
          tostring(f.Version)))
      end
    end
    return 0
  end

  if cmd == "policy" then
    local names = {}
    if args[2] then
      names[#names + 1] = args[2]
    else
      for _, f in ipairs(apt.listInstalled()) do
        names[#names + 1] = f.Package
      end
    end
    table.sort(names)
    for _, name in ipairs(names) do
      io.write(name .. ":\n")
      local inst = require("dpkg").getStanza(name)
      if inst then
        io.write("  Installed: " .. tostring(inst.Version) .. "\n")
      else
        io.write("  Installed: (none)\n")
      end
      local cand = apt.candidate(name)
      if cand then
        io.write("  Candidate: " .. tostring(cand.fields.Version) .. "\n")
        io.write("  Version table:\n")
        for _, v in ipairs(apt.versions(name)) do
          io.write(string.format("   *** %s %s\n", v.fields.Version, v.uri))
        end
      else
        io.write("  Candidate: (none)\n")
      end
      io.write("\n")
    end
    return 0
  end

  if cmd == "download" then
    local pkgs = {}
    for i = 2, #args do pkgs[#pkgs + 1] = args[i] end
    if #pkgs == 0 then
      io.stderr:write("apt: no packages given\n")
      return 1
    end
    local paths, err = apt.download(pkgs, o)
    if not paths then
      io.stderr:write("apt: " .. tostring(err) .. "\n")
      return 1
    end
    for _, p in ipairs(paths) do io.write("Get: " .. p .. "\n") end
    return 0
  end

  if cmd == "clean" or cmd == "autoclean" then
    local ok, err = apt.clean({ auto = cmd == "autoclean" })
    if not ok then
      io.stderr:write("apt: " .. tostring(err) .. "\n")
      return 1
    end
    io.write("Package cache cleared.\n")
    return 0
  end

  io.stderr:write("apt: unknown command `" .. tostring(cmd) .. "`\n")
  usage()
  return 1
end

return run()
