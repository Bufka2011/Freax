local fs = require("fs")
local shell = require("shell")

local args, opts = shell.parse(...)
if opts.help then
  io.write("Usage: ls [-a] [-l] [FILE]...\n"); return
end
if #args == 0 then args = {"."} end

local lsColors = os.getenv("LS_COLORS") or "di=0;36:fi=0:ln=0;33:*.lua=0;32"
local colors = {}
for part in lsColors:gmatch("[^:]+") do
  local k, v = part:match("^([^=]+)=(.*)$")
  if k then
    if k:sub(1, 1) == "*" then
      colors["*"] = colors["*"] or {}; colors["*"][k:sub(2)] = v
    else
      colors[k] = v
    end
  end
end

local function getColor(name, isDir, isLink, ext)
  if isLink then return colors.ln end
  if isDir then return colors.di end
  if colors["*"] and colors["*"][ext] then return colors["*"][ext] end
  return colors.fi
end

local ec = 0
for _, a in ipairs(args) do
  local path = shell.resolve(a)
  local isDir = fs.isDirectory(path)
  if isDir == nil then
    ec = 1; io.stderr:write("ls: cannot access " .. a .. ": no such file\n")
  elseif not isDir then
    local isLink, target = fs.isLink(path)
    local ext = path:match("%.([^./]+)$") or ""
    local c = getColor(path, false, isLink, ext)
    if opts.l and isLink then
      io.write(string.format("l %6d \27[%sm%s\27[0m -> %s\n", fs.size(path), c, a, tostring(target)))
    elseif opts.l then
      io.write(string.format("f %6d \27[%sm%s\27[0m\n", fs.size(path), c, a))
    else
      io.write("\27[" .. c .. "m" .. a .. "\27[0m\n")
    end
  else
    local list, err = fs.list(path)
    if not list then
      ec = 1; io.stderr:write("ls: " .. a .. ": " .. tostring(err) .. "\n")
    else
      local names = {}
      for _, n in ipairs(list) do
        if opts.a or n:sub(1, 1) ~= "." then names[#names + 1] = n end
      end
      table.sort(names)
      if #args > 1 then io.write(a .. ":\n") end
      for _, n in ipairs(names) do
        local full = fs.concat(path, n:gsub("/$", ""))
        local isLink, target = fs.isLink(full)
        local dir = fs.isDirectory(full)
        local sz = dir and 0 or fs.size(full)
        local ext = n:match("%.([^./]+)$") or ""
        local c = getColor(n, dir, isLink, ext)
        if opts.l then
          local typeChar = isLink and "l" or (dir and "d" or "f")
          if isLink then
            io.write(string.format("%s %6d \27[%sm%s\27[0m -> %s\n", typeChar, sz, c, n, tostring(target)))
          else
            io.write(string.format("%s %6d \27[%sm%s\27[0m\n", typeChar, sz, c, n))
          end
        else
          local suffix = dir and "/" or ""
          io.write("\27[" .. c .. "m" .. n .. "\27[0m" .. suffix .. "\n")
        end
      end
    end
  end
end
return ec
