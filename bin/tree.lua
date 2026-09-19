local fs = require("fs")
local shell = require("shell")
local text = require("text")
local tx = require("transforms")

local args, opts = shell.parse(...)

if opts.help then
  io.write("Usage: tree [OPTION]... [FILE]...\n")
  io.write("  -a        show hidden files\n")
  io.write("  -l        long listing format\n")
  io.write("  -h        human-readable sizes\n")
  io.write("  -p        append / to dirs\n")
  io.write("  -Q        quote names\n")
  io.write("  -f        full path prefix\n")
  io.write("  -i        no indent lines\n")
  io.write("  -r        reverse sort\n")
  io.write("  -S        sort by size\n")
  io.write("  -X        sort by extension\n")
  io.write("  -C        no counting\n")
  io.write("  --level=N max depth\n")
  io.write("  --color=WHEN  auto/always/never\n")
  io.write("  --si      powers of 1000\n")
  return 0
end

local roots = #args > 0 and args or {"."}
local level = tonumber(opts.level) or math.huge
if level < 1 then io.stderr:write("Invalid level\n"); return 1 end

local colorMode = opts.color or "auto"
if colorMode == "auto" then colorMode = io.stdout.tty and "always" or "never" end
if colorMode ~= "always" and colorMode ~= "never" then io.stderr:write("Invalid color mode\n"); return 1 end

local lastYield = computer.uptime()
local function yieldopt()
  if computer.uptime() - lastYield > 2 then lastYield = computer.uptime(); os.sleep(0) end
end

local function peekable(iterator, state, var1)
  local nextItem = {iterator(state, var1)}
  return setmetatable({
    peek = function() return table.unpack(nextItem) end,
  }, {
    __call = coroutine.wrap(function()
      while true do
        local item = nextItem
        nextItem = {iterator(state, nextItem[1])}
        coroutine.yield(table.unpack(item))
        if nextItem[1] == nil then break end
      end
    end),
  })
end

local function filter(entry)
  return opts.a or entry:sub(1, 1) ~= "."
end

local function st(path)
  local s = {}
  s.path = path
  s.name = fs.name(path) or "/"
  s.sortName = s.name:gsub("^%.", "")
  s.isLink = fs.isLink(path)
  s.isDir = fs.isDirectory(path)
  s.size = s.isLink and 0 or fs.size(path)
  s.ext = s.name:match("(%.[^.]+)$") or ""
  return s
end

local function makeColorize()
  local colors = tx.foreach(text.split(os.getenv("LS_COLORS") or "", {":"}, true), function(e)
    local parts = text.split(e, {"="}, true)
    return parts[2], parts[1]
  end)
  return function(s)
    return s.isLink and (colors.ln or "0;33") or s.isDir and (colors.di or "0;36") or colors["*" .. s.ext] or (colors.fi or "0")
  end
end

local colorize = colorMode == "always" and makeColorize() or nil

local function listDir(dir)
  return coroutine.wrap(function()
    local l = {}
    for _, entry in ipairs(fs.list(dir) or {}) do
      if filter(entry) then table.insert(l, st(fs.concat(dir, entry))) end
    end
    if opts.S then table.sort(l, function(a, b) return a.size < b.size end)
    elseif opts.X then table.sort(l, function(a, b) return a.ext < b.ext end)
    else table.sort(l, function(a, b) return a.sortName < b.sortName end)
    end
    if opts.r then for i = #l, 1, -1 do coroutine.yield(l[i]) end
    else for _, item in ipairs(l) do coroutine.yield(item) end end
  end)
end

local function digRoot(rootPath)
  coroutine.yield(st(rootPath), {})
  if not fs.isDirectory(rootPath) then return end
  local iterStack = {peekable(listDir(rootPath))}
  local pathStack = {rootPath}
  local levelStack = {not not iterStack[#iterStack]:peek()}
  repeat
    local entry = iterStack[#iterStack]()
    if entry then
      levelStack[#levelStack] = not not iterStack[#iterStack]:peek()
      local path = fs.concat(fs.concat(table.unpack(pathStack)), entry.name)
      coroutine.yield(entry, levelStack)
      if entry.isDir and level > #levelStack then
        table.insert(iterStack, peekable(listDir(path)))
        table.insert(pathStack, entry.name)
        table.insert(levelStack, not not iterStack[#iterStack]:peek())
      end
    else
      table.remove(iterStack); table.remove(pathStack); table.remove(levelStack)
    end
  until #iterStack == 0
end

local function dig(roots)
  return coroutine.wrap(function()
    for _, root in ipairs(roots) do
      local rp = shell.resolve(root)
      if fs.exists(rp) then digRoot(rp) end
    end
  end)
end

local function nod(n)
  return n and tostring(n):gsub("(%.[0-9]+)0+$", "%1") or "0"
end

local function fmtSize(size)
  if not opts.h and not opts["human-readable"] then return tostring(size) end
  local sizes = {"", "K", "M", "G"}
  local u = 1
  local pow = opts.si and 1000 or 1024
  while size > pow and u < #sizes do u = u + 1 size = size / pow end
  return nod(math.floor(size * 10) / 10) .. sizes[u]
end

local dirCount, fileCount = 0, 0

for entry, levelStack in dig(roots) do
  local isDir = entry.isDir
  if not opts.C then
    if isDir then dirCount = dirCount + 1 else fileCount = fileCount + 1 end
  end
  for i, hasNext in ipairs(levelStack) do
    if opts.i then break end
    if i == #levelStack then io.write(hasNext and "├── " or "└── ")
    else io.write(hasNext and "│   " or "    ") end
  end
  if opts.l then
    io.write("[" .. (isDir and "d" or "f") .. " " .. fmtSize(entry.size) .. "] ")
  end
  if opts.Q then io.write('"') end
  if colorize then io.write("\27[" .. colorize(entry) .. "m") end
  if opts.f then io.write(entry.path) else io.write(entry.name) end
  if colorize then io.write("\27[0m") end
  if opts.p and isDir then io.write("/") end
  if opts.Q then io.write('"') end
  io.write("\n")
  yieldopt()
end

if not opts.C then io.write("\n" .. dirCount .. " director" .. (dirCount == 1 and "y" or "ies") .. ", " .. fileCount .. " file" .. (fileCount == 1 and "" or "s") .. "\n") end