local fs = require("fs")
local shell = require("shell")

local args, opts = shell.parse(...)
if #args == 0 or opts.help then
  io.write("Usage: grep [-ivncrqwx] [-C] [--max-count=N] [--label=L] PATTERN [FILE...]\n")
  io.write("  -i  ignore case\n  -v  invert match\n  -n  line numbers\n  -c  count only\n  -r  recursive\n  -q  quiet (exit only)\n  -w  whole word\n  -x  whole line\n  -C  colorize matches\n")
  return
end

local pat = table.remove(args, 1)
local ci = opts.i
if ci then pat = pat:lower() end
local inv = opts.v
local nums = opts.n
local cnt = opts.c
local rec = opts.r or opts.R
local quiet = opts.q
local whole = opts.w
local wholeLine = opts.x
local color = opts.C or opts.color
local maxCount = tonumber(opts["max-count"]) or math.huge
local label = opts.label
local trim = opts.trim

if whole then
  pat = "%f[%a]" .. pat .. "%f[%A]"
end
if wholeLine then
  pat = "^" .. pat .. "$"
end

if #args == 0 then args = {"-"} end

local ec, rc, totalFound = 0, 0, 0

local function getLabel(a)
  if label then return label end
  if #args == 1 then return nil end
  return a
end

local function matchLine(line, a)
  local hay = ci and line:lower() or line
  local s, e = hay:find(pat)
  local hit = s ~= nil
  if inv then hit = not hit end
  if not hit then return end
  rc = rc + 1
  if quiet then return end
  local pre = ""
  local lbl = getLabel(a)
  if lbl then pre = lbl .. ":" end
  if nums then pre = pre .. rc .. ":" end
  if color and s then
    local colored = line:sub(1, s - 1) .. "\27[31m" .. line:sub(s, e) .. "\27[0m" .. line:sub(e + 1)
    io.write(pre .. colored .. "\n")
  else
    io.write(pre .. line .. "\n")
  end
end

local function searchLines(iter, close, a)
  rc = 0
  for line in iter do
    if trim then line = line:gsub("^%s+", ""):gsub("%s+$", "") end
    matchLine(line, a)
    if rc >= maxCount then break end
  end
  if cnt then
    local lbl = getLabel(a)
    io.write((lbl and (lbl .. ":") or "") .. rc .. "\n")
  end
  if close then close:close() end
  if rc > 0 then totalFound = totalFound + 1 end
end

local function searchFile(path, a)
  local f, err = io.open(path, "r")
  if not f then ec = 2; io.stderr:write("grep: " .. a .. ": " .. tostring(err) .. "\n") return end
  searchLines(f:lines(), f, a)
end

local function searchDir(dir, a)
  local entries = fs.list(dir) or {}
  for _, entry in ipairs(entries) do
    if entry ~= "." and entry ~= ".." then
      local full = fs.concat(dir, entry)
      if fs.isDirectory(full) then
        if rec then searchDir(full, a .. "/" .. entry) end
      else
        searchFile(full, a .. "/" .. entry)
      end
    end
  end
end

for _, a in ipairs(args) do
  if a == "-" then
    searchLines(io.stdin:lines(), nil, "(stdin)")
  elseif rec and fs.isDirectory(shell.resolve(a)) then
    searchDir(shell.resolve(a), a)
  else
    searchFile(shell.resolve(a), a)
  end
end

if quiet then return totalFound > 0 and 0 or 1 end
return ec == 0 and (totalFound > 0 and 0 or 1) or ec