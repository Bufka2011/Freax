local fs = require("fs")
local shell = require("shell")

local args, opts = shell.parse(...)

if opts.help then
  io.write([[Usage: ls [OPTION]... [FILE]...
  -a, --all             do not ignore entries starting with .
      --full-time       with -l, print time in full ISO format
  -h, --human-readable  with -l, print human readable sizes
      --si              likewise, but use powers of 1000 not 1024
  -l                    use a long listing format
  -r, --reverse         reverse order while sorting
  -R, --recursive       list subdirectories recursively
  -S                    sort by file size
  -t                    sort by modification time, newest first
  -X                    sort alphabetically by entry extension
  -1                    list one file per line
  -p                    append / indicator to directories
      --no-color        do not colorize output
      --help            display this help and exit
]])
  return 0
end

if #args == 0 then args = {"."} end

local all = opts.a or opts.all
local long = opts.l
local human = opts.h or opts["human-readable"]
local si = opts.si
local reverse = opts.r or opts.reverse
local recursive = opts.R or opts.recursive
local sortSize = opts.S
local sortTime = opts.t
local sortExt = opts.X
local appendSlash = opts.p
local fullTime = opts["full-time"]
local noColor = opts["no-color"] or not (io.stdout and io.stdout.tty)

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

local function getColor(isDir, isLink, ext)
  if noColor then return nil end
  if isLink then return colors.ln end
  if isDir then return colors.di end
  if colors["*"] and colors["*"][ext] then return colors["*"][ext] end
  return colors.fi
end

local function paint(s, c)
  if c then return "\27[" .. c .. "m" .. s .. "\27[0m" end
  return s
end

local function nod(n)
  return n and (tostring(n):gsub("(%.[0-9]+)0+$", "%1")) or "0"
end

local function fmtSize(size)
  if not human and not si then return tostring(size) end
  local units = {"", "K", "M", "G"}
  local u = 1
  local pow = si and 1000 or 1024
  while size > pow and u < #units do u = u + 1 size = size / pow end
  return nod(math.floor(size * 10) / 10) .. units[u]
end

local function pad2(txt)
  txt = tostring(txt)
  return #txt >= 2 and txt or "0" .. txt
end

local monthNames = {"January","February","March","April","May","June",
  "July","August","September","October","November","December"}

local function fmtTime(ms)
  if not ms or ms == 0 then return "" end
  local d = os.date("*t", math.floor(ms / 1000))
  if not d then return "" end
  local day, hour, min = nod(d.day), pad2(nod(d.hour)), pad2(nod(d.min))
  if fullTime then
    return string.format("%s-%s-%s %s:%s:%s", d.year, pad2(nod(d.month)), pad2(day),
      hour, min, pad2(nod(d.sec)))
  end
  return string.format("%s %2s %2s:%2s", monthNames[d.month]:sub(1, 3), day, hour, pad2(min))
end

local function stat(full, name)
  local isLink, link = fs.isLink(full)
  local isDir = fs.isDirectory(full)
  local size = isLink and 0 or (fs.size(full) or 0)
  local ext = name:match("%.([^./]+)$") or ""
  return {
    name = name .. (isDir and (appendSlash or not long) and "/" or ""),
    raw = name,
    full = full,
    isDir = isDir,
    isLink = isLink,
    link = link,
    size = size,
    time = (fs.lastModified and fs.lastModified(full)) or 0,
    ext = ext,
    sortName = name:gsub("^%.", ""),
    color = getColor(isDir, isLink, ext),
  }
end

local function sortList(list)
  if sortSize then
    table.sort(list, function(a, b) return a.size > b.size end)
  elseif sortTime then
    table.sort(list, function(a, b) return a.time > b.time end)
  elseif sortExt then
    table.sort(list, function(a, b) return a.ext > b.ext end)
  else
    table.sort(list, function(a, b) return a.sortName < b.sortName end)
  end
  if reverse then
    for i = 1, math.floor(#list / 2) do
      list[i], list[#list - i + 1] = list[#list - i + 1], list[i]
    end
  end
  return list
end

local function displayFile(info)
  if not long then
    io.write(paint(info.name, info.color) .. "\n")
    return
  end
  local typeChar = info.isLink and "l" or (info.isDir and "d" or "f")
  local rw = (fs.isReadOnly and fs.isReadOnly(info.full)) and "-" or "w"
  local target = info.isLink and (" -> " .. tostring(info.link)) or ""
  io.write(string.format("%s-r%s %6s %s %s%s\n",
    typeChar, rw, fmtSize(info.size), fmtTime(info.time),
    paint(info.name, info.color), target))
end

local ec = 0
local files, dirs = {}, {}
for _, a in ipairs(args) do
  local path = shell.resolve(a)
  if not fs.exists(path) and not fs.isLink(path) then
    ec = 1; io.stderr:write("ls: cannot access " .. a .. ": No such file or directory\n")
  elseif fs.isDirectory(path) then
    dirs[#dirs + 1] = {arg = a, path = path}
  else
    files[#files + 1] = stat(path, a)
  end
end

if #files > 0 then
  sortList(files)
  for _, f in ipairs(files) do displayFile(f) end
end

local showHeader = #dirs > 1 or recursive
local queue, first = {}, true
for _, d in ipairs(dirs) do queue[#queue + 1] = d end
local qi = 1
while qi <= #queue do
  local d = queue[qi]; qi = qi + 1
  if showHeader then
    if not first then io.write("\n") end
    first = false
    io.write(d.arg .. ":\n")
  end
  local entries, err = fs.list(d.path)
  if not entries then
    ec = 1; io.stderr:write("ls: cannot access " .. d.arg .. ": " .. tostring(err) .. "\n")
  else
    local list = {}
    for _, n in ipairs(entries) do
      if all or n:sub(1, 1) ~= "." then
        list[#list + 1] = stat(fs.concat(d.path, n:gsub("/$", "")), n)
      end
    end
    sortList(list)
    for _, e in ipairs(list) do
      displayFile(e)
      if recursive and e.isDir then
        queue[#queue + 1] = {arg = fs.concat(d.arg, e.raw), path = e.full}
      end
    end
  end
end
return ec
