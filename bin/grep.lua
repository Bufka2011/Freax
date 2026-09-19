local fs = require("fs")
local shell = require("shell")

local args, options = shell.parse(...)
local function usage(msg)
  local s = msg and io.stderr or io.stdout
  if msg then s:write(msg .. "\n") end
  s:write("Usage: grep [OPTION]... PATTERN [FILE]...\n  -i ignore case  -v invert  -n line numbers  -c count\n  -r recursive  -q quiet  -w whole word  -x whole line\n  -F fixed string  -l files-with-matches  -L without-match\n  -s suppress errors  -o only-matching  -C color\n  --max-count=N  --label=L  --file=F  --trim\n")
  return msg and 2 or 0
end

local function pop(...)
  local r
  for _, k in ipairs({...}) do r = options[k] or r; options[k] = nil end
  return r
end

local plain = pop("F", "fixed-strings")
local patFile = pop("file")
local wholeWord = pop("w", "word-regexp")
local wholeLine = pop("x", "line-regexp")
local ignoreCase = pop("i", "ignore-case")
local stdinLabel = pop("label") or "(standard input)"
local stderr = pop("s", "no-messages") and {write=function()end} or io.stderr
local invert = not not pop("v", "invert-match")
local maxCount = tonumber(pop("max-count")) or math.huge
local lineNum = pop("n", "line-number")
local recurse = pop("r", "recursive")
local fOnly = pop("l", "files-with-matches")
local noOnly = pop("L", "files-without-match") and not fOnly
local inclFile = pop("H", "with-filename")
local noFile = pop("h", "no-filename")
local mOnly = pop("o", "only-matching")
local quiet = pop("q", "quiet", "silent")
local countOnly = pop("c", "count")
local trim = pop("t", "trim")
local color = pop("C", "color", "colour")

if pop("help", "V", "version") then return usage() end
if next(options) then return usage("unexpected option: " .. next(options)) end

if #args == 0 then io.stderr:write("grep: missing pattern\n"); return 2 end
local patterns = {table.remove(args, 1)}
local files = #args > 0 and args or (recurse and {"."} or {"-"})

if patFile then
  local f, err = io.open(shell.resolve(patFile), "r")
  if not f then stderr:write("grep: " .. patFile .. ": " .. tostring(err) .. "\n"); return 2 end
  for line in f:lines() do if line ~= "" then patterns[#patterns + 1] = line end end
  f:close()
end

if recurse and not noFile then inclFile = true end
if #files < 2 and not noFile then inclFile = false end

if ignoreCase then
  for i, p in ipairs(patterns) do
    patterns[i] = p:gsub("(%%?)(.)", function(pct, ch)
      if pct ~= "" or not ch:match("%a") then return pct .. ch end
      return "[" .. ch:lower() .. ch:upper() .. "]"
    end)
  end
end

if plain then
  for i, p in ipairs(patterns) do
    patterns[i] = p:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
  end
end

local function resolve(file)
  return shell.resolve(file)
end

local function getAllFiles(dir, list)
  for _, node in ipairs(fs.list(shell.resolve(dir)) or {}) do
    local rel = dir:gsub("/+$", "") .. "/" .. node
    local abs = shell.resolve(rel)
    if fs.isDirectory(abs) then getAllFiles(rel, list) else list[#list + 1] = rel end
  end
end

if recurse then
  local tmp = {}
  for _, arg in ipairs(files) do
    if fs.isDirectory(shell.resolve(arg)) then getAllFiles(arg, tmp) else tmp[#tmp + 1] = arg end
  end
  files = tmp
end

local noop = function(...) return ... end
local trimFront = trim and function(s) return s:gsub("^%s+", "") end or noop
local trimBack = trim and function(s) return s:gsub("%s+$", "") end or noop

local function readLines()
  local curHand, curFile, meta
  return function()
    if not curFile then
      local file = table.remove(files, 1)
      if not file then return end
      meta = {line_num = 0, hits = 0}
      if file == "-" then
        curFile = file; meta.label = stdinLabel; curHand = io.input()
      else
        meta.label = file
        local rp = resolve(file)
        if fs.exists(rp) then
          curHand, _ = io.open(rp, "r")
          if not curHand then
            stderr:write("grep: " .. meta.label .. ": failed to read\n")
            return false, 2
          end
          curFile = meta.label
        else
          stderr:write("grep: " .. meta.label .. ": file not found\n")
          return false, 2
        end
      end
    end
    meta.line = nil
    if not meta.close and curHand then
      meta.line_num = meta.line_num + 1
      meta.line = curHand:read("*l")
    end
    if not meta.line then
      curFile = nil
      if curHand then curHand:close(); curHand = nil end
      return false, meta
    else
      return meta, curFile
    end
  end
end

local ec, anyHit = nil, 1
local lastYield = computer.uptime()

local function test(m, p)
  local empty = true
  local idx, slen = 1, #m.line
  local needFile, needLine = inclFile, lineNum
  local hitVal = 1
  while idx <= slen and not m.close do
    local i, j = m.line:find(p, idx, plain)
    local wf = wholeWord and not (i and not (m.line:sub(i - 1, i - 1) .. m.line:sub(j + 1, j + 1)):find("[%a_]"))
    local lf = wholeLine and not (i == 1 and j == slen)
    local matched = not ((mOnly or idx == 1) and not i)
    if (hitVal == 1 and wf) or lf then matched, i, j = false end
    if invert == matched then break end
    if maxCount == 0 then return end
    anyHit = 0; m.hits = m.hits + hitVal; hitVal = 0
    if fOnly or noOnly then m.close = true end
    if (fOnly or noOnly or countOnly) and not quiet and not m.close then
      if noOnly and m.hits == 0 or fOnly and m.hits ~= 0 then io.write(m.label .. "\n")
      elseif countOnly then io.write((inclFile and (m.label .. ":") or "") .. m.hits .. "\n") end
    end
    if quiet then return end
    if needFile then io.write(m.label .. ":"); needFile = nil end
    if needLine then io.write(m.line_num .. ":"); needLine = nil end
    local s = mOnly and "" or (m.line:sub(idx, (i or 0) - 1))
    local g = i and m.line:sub(i, j) or ""
    if i == 1 then g = trimFront(g) elseif idx == 1 then s = trimFront(s) end
    if j == slen then g = trimBack(g) elseif not i then s = trimBack(s) end
    io.write(s)
    if color and i then io.write("\27[31m" .. g .. "\27[0m") else io.write(g) end
    empty = false
    idx = (j or slen) + 1
    if mOnly or idx > slen then io.write("\n"); empty = true; needFile, needLine = inclFile, lineNum end
  end
  if not empty then io.write("\n") end
  if maxCount ~= math.huge and m.hits >= maxCount then m.close = true end
end

for meta, status in readLines() do
  if computer.uptime() - lastYield > 1 then os.sleep(0); lastYield = computer.uptime() end
  if not meta then
    if type(status) == "table" then
      if noOnly and status.hits == 0 or fOnly and status.hits ~= 0 then io.write(status.label .. "\n") end
      if countOnly and not (fOnly or noOnly) then io.write((inclFile and (status.label .. ":") or "") .. status.hits .. "\n") end
    elseif status then ec = status or ec end
  else
    for _, p in ipairs(patterns) do test(meta, p) end
  end
end

return ec or anyHit