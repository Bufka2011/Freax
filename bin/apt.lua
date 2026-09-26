-- apt: Freax package manager CLI (Debian-style).
-- Subcommands: update, upgrade, full-upgrade|dist-upgrade, install,
-- reinstall, remove|rm, purge, autoremove, search, show|info, list,
-- policy, download, clean, autoclean, source|sources, version, help.
-- The OS is not a package: it is the manifest-driven base system, presented
-- as the virtual package `sys` so that `apt update` / `apt upgrade` cover
-- both the repositories and the system itself. See lib/sysupdate.lua.

local fs = require("fs")
local term = require("term")
local shell = require("shell")
local apt

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
    repair = raw.repair or raw.r,
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
    "The base system is the virtual package `sys` (not a real archive):",
    "  apt update           refresh package indexes and the sys release",
    "  apt upgrade          upgrade packages and the system together",
    "  apt list             includes sys",
    "  apt policy sys       show installed/candidate system version",
    "  apt install sys      re-apply the current system release (repair)",
    "  apt verify [--repair] re-hash installed files, optionally refetch",
    "",
    "Options: -y/--yes --force/-f -q/--quiet -V --download-only",
    "         --no-install-recommends --reinstall --purge --autoremove",
    "         --source=URL",
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

-- The base system is presented as the virtual package "sys": not a real
-- .fpkg, just so users have one command for the whole system.
local function sysStatus(o)
  return require("sysupdate").status(o)
end

local function sysFields(st)
  return {
    Package = "sys",
    Version = st.installed,
    Architecture = "freax",
    Section = "system",
    Priority = "required",
    Maintainer = "freax",
    Description = "The Freax base system (OS files tracked by /manifest).\n"
      .. "Upgrades with `apt upgrade`; not a real package archive.",
    Status = "install ok installed",
  }
end

-- Apply the system update (if any) and then the package plan, asking once.
local function upgradeAll(cmd, o)
  local sysu = require("sysupdate")
  local st = sysStatus(o)
  local wantSys = (st.upgradable or o.force) and st.candidate ~= nil
    and not o.downloadOnly
  if wantSys then
    io.write(string.format("%-24s %s -> %s\n", "sys", st.installed, st.candidate))
  end
  if not o.yes and not o.downloadOnly then
    term.write("Apply these upgrades? [Y/n]: ")
    local ans = term.readLine() or ""
    if ans ~= "" and ans:sub(1, 1):lower() ~= "y" then
      io.write("Cancelled.\n")
      return 0
    end
    o.yes = true
  end
  local kernelTouched = false
  if wantSys then
    local so = { yes = true, force = o.force, source = o.source,
      deferReboot = true, downloadOnly = o.downloadOnly }
    local rc, touched = sysu.upgrade(so)
    if rc ~= 0 then
      io.stderr:write("apt: system update failed, packages left untouched.\n")
      return 1
    end
    kernelTouched = touched and true or false
  end
  local fn = (cmd == "upgrade") and apt.upgrade or apt.fullUpgrade
  local ok, err = fn(o)
  if not ok then
    io.stderr:write("apt: " .. tostring(err) .. "\n")
    return 1
  end
  if kernelTouched then
    term.write("Kernel updated. Reboot now? [y/N]: ")
    local ans = term.readLine() or ""
    if ans:sub(1, 1):lower() == "y" then freax.reboot() end
  end
  return 0
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

  if cmd == "verify" then
    return require("sysupdate").verify(o)
  end

  if cmd == "version" then
    require("sysupdate").version()
    io.write("apt 1.0 (freax package manager)\n")
    io.write("dpkg (freax)\n")
    return 0
  end

  local rootCommands = {
    update = true, upgrade = true, ["full-upgrade"] = true,
    ["dist-upgrade"] = true, install = true, reinstall = true,
    remove = true, rm = true, purge = true, autoremove = true,
    clean = true, autoclean = true, download = true,
  }
  if rootCommands[cmd] and freax.geteuid() ~= 0 then
    io.stderr:write("apt: " .. cmd .. " requires root\n")
    return 1
  end

  apt = require("apt")

  if cmd == "source" or cmd == "sources" then
    if o.os then
      -- the source `sys` is fetched from
      io.write(require("sysupdate").effectiveSource(o) .. "\n")
      return 0
    end
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
    local rc = 0
    local summary, err = apt.update(o)
    if not summary then
      io.stderr:write("apt: " .. tostring(err) .. "\n")
      rc = 1
    else
      io.write(string.format("Fetched %d/%d index files from %d sources.\n",
        summary.fetched, summary.components, summary.sources))
      for _, f in ipairs(summary.failed) do
        io.stderr:write("  W: " .. f .. "\n")
      end
      if #summary.failed > 0 then
        io.stderr:write("apt: some indexes failed to update.\n")
        rc = 1
      end
    end
    -- the OS is the virtual package "sys": refreshing it is part of update
    local sysRc = require("sysupdate").update(o)
    if sysRc ~= 0 then rc = 1 end
    return rc
  end

  if cmd == "upgrade" or cmd == "full-upgrade" or cmd == "dist-upgrade" then
    return upgradeAll(cmd, o)
  end

  if cmd == "install" or cmd == "reinstall" then
    local pkgs, wantSys = {}, false
    for i = 2, #args do
      if args[i] == "sys" then
        wantSys = true
      else
        pkgs[#pkgs + 1] = args[i]
      end
    end
    if wantSys then
      -- re-apply the current system release: a repair path for a botched
      -- update, since every manifest file is fetched and verified again
      local rc = require("sysupdate").upgrade({ yes = true, force = true,
        source = o.source })
      if rc ~= 0 then return 1 end
      o.force = true
    end
    if #pkgs == 0 then return 0 end
    local fn = (cmd == "reinstall") and apt.reinstall or apt.install
    local ok, err = fn(pkgs, o)
    if not ok then
      io.stderr:write("apt: " .. tostring(err) .. "\n")
      return 1
    end
    return 0
  end

  if cmd == "remove" or cmd == "rm" or cmd == "purge" then
    for i = 2, #args do
      if args[i] == "sys" then
        io.stderr:write("apt: sys is the base system and cannot be removed\n")
        return 1
      end
    end
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
      if args[i] == "sys" then
        showFields(sysFields(sysStatus(o)))
        io.write("\n")
      else
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
    end
    return rc
  end

  if cmd == "list" then
    local st = sysStatus(o)
    if o.installed then
      io.write(string.format("sys/%s installed\n", st.installed))
      for _, f in ipairs(apt.listInstalled()) do
        io.write(string.format("%s/%s %s\n", tostring(f.Package),
          tostring(f.Version), f.Status or "installed"))
      end
    elseif o.upgradable then
      if st.upgradable then
        io.write(string.format("sys/%s [upgradable from: %s]\n",
          st.candidate, st.installed))
      end
      for _, u in ipairs(apt.listUpgradable()) do
        io.write(string.format("%s/%s %s [upgradable from: %s]\n",
          u.name, u.candidateVersion, u.candidate.uri, u.installed))
      end
    else
      local pattern = args[2] or ""
      if pattern == "" or pattern == "sys" then
        io.write(string.format("sys/%s\n", st.installed))
      end
      for _, f in ipairs(apt.search(pattern)) do
        io.write(string.format("%s/%s\n", tostring(f.Package),
          tostring(f.Version)))
      end
    end
    return 0
  end

  if cmd == "policy" then
    if args[2] == "sys" then
      local st = sysStatus(o)
      io.write("sys:\n")
      io.write("  Installed: " .. tostring(st.installed) .. "\n")
      io.write("  Candidate: " .. tostring(st.candidate or "(none)") .. "\n")
      io.write("  Version table:\n")
      io.write("   *** " .. tostring(st.candidate or "?") .. " " ..
        tostring(st.source) .. "\n")
      if st.upgradable then
        io.write("  Upgradable: yes (" .. st.changed .. " of " ..
          st.files .. " files differ)\n")
      end
      io.write("\n")
      return 0
    end
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
