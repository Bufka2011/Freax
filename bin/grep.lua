local fs = require("fs")
local shell = require("shell")

local args, options = shell.parse(...)

local function printUsage(ostream, msg)
  local s = ostream or io.stdout
  if msg then s:write(msg .. "\n") end
  s:write("Usage: grep [OPTION]... PATTERN [FILE]...\nExample: grep -i 'hello world' menu.lua main.lua\n")
end

local pop = function(...)
  local result
  for _, key in ipairs({...}) do
    result = options[key] or result
    options[key] = nil
  end
  return result
end

local plain = pop("F", "fixed-strings")
plain = not pop("e", "--lua-regexp") and plain
local pattern_file = pop("file")
local match_whole_word = pop("w", "word-regexp")
local match_whole_line = pop("x", "line-regexp")
local ignore_case = pop("i", "ignore-case")
local stdin_label = pop("label") or "(standard input)"
local stderr = pop("s", "no-messages") and {write=function()end} or io.stderr
local invert_match = not not pop("v", "invert-match")

if pop("V", "version", "help") then printUsage(); return 0 end

local max_matches = tonumber(pop("max-count")) or math.huge
local print_line_num = pop("n", "line-number")
local search_recursively = pop("r", "recursive")

local colorize = pop("C", "color", "colour")
local f_only = pop("l", "files-with-matches")
local no_only = pop("L", "files-without-match") and not f_only
local include_filename = pop("H", "with-filename")
include_filename = not pop("h", "no-filename") or include_filename
local m_only = pop("o", "only-matching")
local quiet = pop("q", "quiet", "silent")
local print_count = pop("c", "count")
local trim = pop("t", "trim")
local binary = pop("a", "binary", "text")

if next(options) then
  if not quiet then
    printUsage(stderr, "unexpected option: " .. next(options))
    return 2
  end
  return 0
end

local PATTERNS = {args[1]}
local FILES = {select(2, table.unpack(args))}

if pattern_file then
  local pf, err = io.open(shell.resolve(pattern_file), "r")
  if not pf then stderr:write("grep: " .. pattern_file .. ": file not found\n"); return 2 end
  table.insert(FILES, 1, PATTERNS[1])
  PATTERNS = {}
  for line in pf:lines() do PATTERNS[#PATTERNS + 1] = line end
  pf:close()
end
if #PATTERNS == 0 then printUsage(stderr); return 2 end
if #FILES == 0 then FILES = search_recursively and {"."} or {"-"} end
if not options.h and search_recursively then include_filename = true end
if #FILES < 2 then include_filename = false end

if ignore_case then
  for i = 1, #PATTERNS do
    PATTERNS[i] = PATTERNS[i]:gsub("(%%?)(.)", function(pct, letter)
      if pct ~= "" or not letter:match("%a") then return pct .. letter end
      return "[" .. letter:lower() .. letter:upper() .. "]"
    end)
  end
end

if plain then
  for i = 1, #PATTERNS do
    PATTERNS[i] = PATTERNS[i]:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
  end
end

local noop = function(...) return ... end
local trim_front = trim and function(s) return s:gsub("^%s+", "") end or noop
local trim_back = trim and function(s) return s:gsub("%s+$", "") end or noop

local function resolve(file)
  if file:sub(1, 1) == "/" then
    return fs.canonical(file)
  else
    if file:sub(1, 2) == "./" then
      file = file:sub(3, -1)
    end
    return fs.canonical(fs.concat(shell.getWorkingDirectory(), file))
  end
end

local function getAllFiles(dir, file_list)
  for _, node in ipairs(fs.list(shell.resolve(dir)) or {}) do
    local rel = dir:gsub("/+$", "") .. "/" .. node
    local rp = resolve(rel)
    if fs.isDirectory(rp) then getAllFiles(rel, file_list) else file_list[#file_list + 1] = rel end
  end
end

if search_recursively then
  local files = {}
  for _, arg in ipairs(FILES) do
    if fs.isDirectory(shell.resolve(arg)) then getAllFiles(arg, files) else files[#files + 1] = arg end
  end
  FILES = files
end

local function readLines()
  local curHand, curFile, meta
  return function()
    if not curFile then
      local file = table.remove(FILES, 1)
      if not file then return end
      meta = {line_num = 0, hits = 0}
      if file == "-" then
        curFile = file; meta.label = stdin_label; curHand = io.input()
      else
        meta.label = file
        local rp, reason = resolve(file)
        if rp then
          curHand, reason = io.open(rp, "r")
          if not curHand then
            local msg = string.format("failed to read from %s: %s", meta.label, reason or "unknown error")
            stderr:write("grep: ", msg, "\n")
            return false, 2
          end
          curFile = meta.label
        else
          stderr:write("grep: ", meta.label, ": file not found\n")
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

local function write_color(part, ansi)
  if ansi then io.write("\27[" .. ansi .. "m" .. part .. "\27[0m") else io.write(part) end
end

local flush = (f_only or no_only or print_count) and function(m)
  if no_only and m.hits == 0 or f_only and m.hits ~= 0 then io.write(m.label .. "\n")
  elseif print_count then io.write((include_filename and (m.label .. ":") or "") .. m.hits .. "\n") end
end

local ec, any_hit_ec = nil, 1
local last_yield = computer.uptime()

local function test(m, p)
  local empty_line = true
  local last_index, slen = 1, #m.line
  local needs_filename, needs_line_num = include_filename, print_line_num
  local hit_value = 1
  while last_index <= slen and not m.close do
    local i, j = m.line:find(p, last_index, plain)
    local word_fail = match_whole_word and not (i and not (m.line:sub(i - 1, i - 1) .. m.line:sub(j + 1, j + 1)):find("[%a_]"))
    local line_fail = match_whole_line and not (i == 1 and j == slen)
    local matched = not ((m_only or last_index == 1) and not i)
    if (hit_value == 1 and word_fail) or line_fail then matched, i, j = false end
    if invert_match == matched then break end
    if max_matches == 0 then os.exit(1) end
    any_hit_ec = 0
    m.hits, hit_value = m.hits + hit_value, 0
    if f_only or no_only then m.close = true end
    if flush or quiet then return end
    if needs_filename then io.write(m.label .. ":"); needs_filename = nil end
    if needs_line_num then io.write(m.line_num .. ":"); needs_line_num = nil end
    local s = m_only and "" or m.line:sub(last_index, (i or 0) - 1)
    local g = i and m.line:sub(i, j) or ""
    if i == 1 then g = trim_front(g) elseif last_index == 1 then s = trim_front(s) end
    if j == slen then g = trim_back(g) elseif not i then s = trim_back(s) end
    io.write(s)
    if colorize and i then write_color(g, "31") else io.write(g) end
    empty_line = false
    last_index = (j or slen) + 1
    if m_only or last_index > slen then io.write("\n"); empty_line = true; needs_filename, needs_line_num = include_filename, print_line_num
    elseif p:find("^^") and not plain then p = "^$" end
  end
  if not empty_line then io.write("\n") end
  if max_matches ~= math.huge and m.hits >= max_matches then m.close = true end
end

for meta, status in readLines() do
  if computer.uptime() - last_yield > 1 then os.sleep(0); last_yield = computer.uptime() end
  if not meta then
    if type(status) == "table" then
      if flush then flush(status) end
    elseif status then ec = status or ec end
  else
    for _, p in ipairs(PATTERNS) do test(meta, p) end
  end
end
return ec or any_hit_ec