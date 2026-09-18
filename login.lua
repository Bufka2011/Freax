-- login: console login prompt, getty-style (M2).
-- Loops forever: prompt -> verify -> shell -> back to prompt on logout.
-- Killing login just respawns it (started by the kernel), like init/getty.
local auth = require("auth")
local fs = require("fs")
local shell = require("shell")
local term = require("term")

local function hostname()
  local data = fs.readFile("/etc/hostname")
  return (data and data:match("%S+")) or "freax"
end

term.clear() -- pristine screen: never show boot leftovers at the prompt

while true do
  if not fs.exists("/etc/passwd") then
    -- Demo media: reset the boot drive to shipped files, then
    -- drop to a root setup shell. Mounts and dotfiles are spared.
    term.writeln("Demo mode. All data will be wiped on reboot.")
    local mf = fs.readFile("/manifest")
    if not mf then
      term.writeln("No manifest -- skipping wipe.")
    else
      local keep = {}
      for line in (mf .. "\n"):gmatch("(.-)\n") do
        if line ~= "" and line:sub(1, 1) ~= "#" then keep[line] = true end
      end
      local mounts = {}
      for _, m in ipairs(fs.mounts()) do
        if m.path ~= "/" then mounts[#mounts + 1] = m.path end
      end
      -- mount points, anything under them, and their ancestor dirs
      -- (except /) are never touched: other drives are not ours.
      local function protectedDir(dir)
        if dir == "/" then return false end
        for _, mp in ipairs(mounts) do
          if dir == mp then return true end
          if (dir .. "/"):sub(1, #mp + 1) == mp .. "/" then return true end
          if (mp .. "/"):sub(1, #dir + 1) == dir .. "/" then return true end
        end
        return false
      end
      local removed, dirs = 0, {}
      local function walk(dir)
        if protectedDir(dir) then return end
        local list = fs.list(dir)
        if not list then return end
        for _, name in ipairs(list) do
          if name:sub(1, 1) ~= "." then
            local isDir = name:sub(-1) == "/"
            local base = isDir and name:sub(1, -2) or name
            local full = (dir == "/" and "/" .. base or dir .. "/" .. base)
            if not protectedDir(full) then
              if isDir then
                walk(full)
                dirs[#dirs + 1] = full
              else
                local rel = full:sub(2)
                if not keep[rel] then
                  local ok = fs.remove(full)
                  if ok then removed = removed + 1 end
                end
              end
            end
          end
        end
      end
      walk("/")
      for i = #dirs, 1, -1 do pcall(fs.remove, dirs[i]) end
      term.writeln("Wiped " .. removed .. " files.")
    end
    term.writeln("Run install to set up this computer.")
    os.setenv("USER", "root")
    os.setenv("LOGNAME", "root")
    os.setenv("HOME", "/")
    freax.setCwd("/")
    local pid = freax.spawn("root-sh", "/bin/sh.lua", {})
    if pid then
      freax.wait(pid)
    else
      term.writeln("Cannot start shell.")
      return
    end
  else
  term.write(hostname() .. " login: ")
  local user = term.readLine() or ""
  user = user:match("%S+") or ""
  local entry = (user ~= "") and auth.getPasswd(user) or nil
  -- Prompt unless this is a known account with no password (nullok):
  -- unknown users still get a prompt (then fail) so the flow leaks
  -- nothing about which accounts exist.
  local pw = ""
  local needPw = true
  if entry then
    local sh = auth.getShadow(user)
    needPw = sh and not (sh.salt == "" and sh.hash == "")
  end
  if needPw then
    term.write("Password: ")
    pw = term.read(nil, true, nil, "*") or ""
  end
  local ok = entry and auth.verify(user, pw)
  if not ok then
    term.writeln("Login incorrect")
  else
    local motd = fs.readFile("/etc/motd")
    if motd then term.writeln(motd:gsub("\n$", "")) end
    -- session env (throwaway: reset on next login iteration)
    os.setenv("USER", entry.name)
    os.setenv("LOGNAME", entry.name)
    os.setenv("HOME", (entry.home ~= "" and entry.home) or "/")
    local home = os.getenv("HOME")
    if not fs.isDirectory(home) then
      term.writeln("No home " .. home .. ", staying in /")
      home = "/"
      os.setenv("HOME", "/")
    end
    freax.setCwd(home)
    local shellPath = (entry.shell ~= "" and entry.shell) or "/bin/sh.lua"
    local pid = freax.spawn(entry.name .. "-sh", shellPath, {})
    if pid then
      freax.wait(pid) -- logout returns here
    else
      term.writeln("Cannot start shell " .. shellPath)
    end
    term.writeln("")
    term.clear() -- fresh screen for the next login, like agetty
  end
  end
end
