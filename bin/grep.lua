local fs = require("fs")
local shell = require("shell")

local args, opts = shell.parse(...)
if #args == 0 or opts.help then
  io.write("Usage: grep [OPTION]... PATTERN [FILE...]\n")
  io.write("  -i  ignore case\n  -v  invert match\n  -n  line numbers\n")
  io.write("  -c  count only\n  -r  recursive\n  -q  quiet\n")
  io.write("  -w  whole word\n  -x  whole line\n  -F  fixed string\n")
  io.write("  -l  files with matches only\n  -L  files without matches\n")
  io.write("  -s  suppress errors\n  -o  only matching\n")
  io.write("  -C  colorize\n  --max-count=N\n  --label=L\n  --file=F\n")
  return
end

local pat = table.remove(args, 1)
local ci = opts.i
local fixed = opts.F or opts["fixed-strings"]
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
local filesOnly = opts.l
local noFiles = opts.L
local noErrors = opts.s or opts["no-messages"]
local onlyMatch = opts.o or opts["only-matching"]
local patternFile = opts.file

if whole then pat = "%f[%a]" .. pat .. "%f[%A]" end
if wholeLine then pat = "^" .. pat .. "$" end
if fixed then pat = pat:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1") end

if #args == 0 then args = {"-"} end

local ec, totalFound = 0, 0

local function getLabel(a)
  if label then return label end
  if #args == 1 then return nil end
  return a
end

-- read pattern from --file if given
local function loadPatterns(fpath)
  local f, err = io.open(shell.resolve(fpath), "r")
  if not f then io.stderr:write("grep: " .. fpath .. ": " .. tostring(err) .. "\n"); return end
  for line in f:lines() do
    if line ~= "" then
      local p = ci and line:lower() or line
      if fixed then p = p:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1") end
      table.insert(args, 2, p)
    end
  end
  f:close()
end

if patternFile then loadPatterns(patternFile) end

local function searchFile(path, a, patIdx)
  local f, err = io.open(path, "r")
  if not f then
    if not noErrors then io.stderr:write("grep: " .. a .. ": " .. tostring(err) .. "\n") end
    ec = 2; return
  end
  local rc, usedPat = 0, false
  for line in f:lines() do
    if ci and not usedPat then line = line:lower() end
    local hay = ci and line:lower() or line
    local thisPat = patIdx and args[patIdx] or pat
    local s, e = hay:find(thisPat)
    local hit = s ~= nil
    if inv then hit = not hit end
    if not hit then end
    if hit then
      rc = rc + 1; usedPat = true
      if not (filesOnly or noFiles or quiet) then
        local pre = ""
        local lbl = getLabel(a)
        if lbl then pre = lbl .. ":" end
        if nums then pre = pre .. rc .. ":" end
        if color and s then
          local out = onlyMatch and line:sub(s, e) or line
          io.write(pre .. line:sub(1, s - 1) .. "\27[31m" .. line:sub(s, e) .. "\27[0m" .. line:sub(e + 1) .. "\n")
        elseif onlyMatch then
          io.write(pre .. line:sub(s, e) .. "\n")
        else
          io.write(pre .. line .. "\n")
        end
      end
      if rc >= maxCount then break end
    end
  end
  f:close()
  if filesOnly and rc > 0 then io.write(a .. "\n") end
  if noFiles and rc == 0 then io.write(a .. "\n") end
  if cnt and not (filesOnly or noFiles) then
    local lbl = getLabel(a)
    io.write((lbl and (lbl .. ":") or "") .. rc .. "\n")
  end
  if rc > 0 then totalFound = totalFound + 1 end
end

local function searchDir(dir, a, patIdx)
  local entries = fs.list(dir) or {}
  for _, entry in ipairs(entries) do
    if entry ~= "." and entry ~= ".." then
      local full = fs.concat(dir, entry)
      if fs.isDirectory(full) then
        if rec then searchDir(full, a .. "/" .. entry, patIdx) end
      else
        searchFile(full, a .. "/" .. entry, patIdx)
      end
    end
  end
end

local function processArgs(a, patIdx)
  if a == "-" then
    local rc = 0
    for line in io.stdin:lines() do
      local hay = ci and line:lower() or line
      local thisPat = patIdx and args[patIdx] or pat
      local s = hay:find(thisPat)
      local hit = s ~= nil
      if inv then hit = not hit end
      if hit then
        rc = rc + 1
        if not quiet then io.write(line .. "\n") end
      end
    end
    if rc > 0 then totalFound = totalFound + 1 end
  elseif rec and fs.isDirectory(shell.resolve(a)) then
    searchDir(shell.resolve(a), a, patIdx)
  else
    searchFile(shell.resolve(a), a, patIdx)
  end
end

for _, a in ipairs(args) do processArgs(a) end

if quiet then return totalFound > 0 and 0 or 1 end
return ec == 0 and (totalFound > 0 and 0 or 1) or ec