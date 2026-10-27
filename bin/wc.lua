-- wc: line/word/byte counts over files or stdin (pipe-clean).
local fs = require("fs")
local shell = require("shell")

local args, opts = shell.parse(...)
if opts.help then
  io.write("Usage: wc [-lwc] [FILE...]\n")
  return
end
if #args == 0 then args = { "-" } end

local function columns(l, w, b)
  if opts.l or opts.w or opts.c then
    local cols = {}
    if opts.l then cols[#cols + 1] = l end
    if opts.w then cols[#cols + 1] = w end
    if opts.c then cols[#cols + 1] = b end
    return table.concat(cols, " ")
  end
  return l .. " " .. w .. " " .. b
end

local ec = 0
local tl, tw, tb = 0, 0, 0
for _, a in ipairs(args) do
  local src, close, err, label = nil, nil, nil, a
  if a == "-" then
    src = io.stdin
    label = ""
  else
    label = shell.resolve(a)
    src, err = io.open(label, "r")
    close = src
  end
  if not src then
    io.stderr:write("wc: " .. a .. ": " .. tostring(err) .. "\n")
    ec = 1
  else
    local l, w, b = 0, 0, 0
    local tailNonSpace = false -- previous chunk ended inside a word
    while true do
      local chunk = src:read(4096)
      if not chunk or chunk == "" then break end
      b = b + #chunk
      l = l + select(2, chunk:gsub("\n", ""))
      local runs = select(2, chunk:gsub("%S+", " "))
      if tailNonSpace and chunk:find("%S") == 1 then runs = runs - 1 end
      w = w + runs
      tailNonSpace = chunk:sub(-1):match("%S") ~= nil
    end
    tl, tw, tb = tl + l, tw + w, tb + b
    io.write(columns(l, w, b) .. ((a ~= "-") and (" " .. a) or "") .. "\n")
    if close then close:close() end
  end
end
if #args > 1 then
  io.write(columns(tl, tw, tb) .. " total\n")
end
return ec
