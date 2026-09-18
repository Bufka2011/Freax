-- wc: line/word/byte counts over files or stdin (pipe-clean).
local fs = require("fs")
local shell = require("shell")

local args, opts = shell.parse(...)
if opts.help then
  io.write("Usage: wc [-lwc] [FILE...]\n")
  return
end
if #args == 0 then args = { "-" } end

local tl, tw, tb = 0, 0, 0
for _, a in ipairs(args) do
  local iter, close, err, label = nil, nil, nil, a
  if a == "-" then
    iter = io.stdin:lines()
    label = ""
  else
    local f
    f, err = io.open(shell.resolve(a), "r")
    if f then
      iter = f:lines()
      close = f
    end
  end
  if not iter then
    io.stderr:write("wc: " .. a .. ": " .. tostring(err) .. "\n")
  else
    local l, w, b = 0, 0, 0
    for line in iter do
      l = l + 1
      b = b + #line + 1
      for _ in line:gmatch("%S+") do w = w + 1 end
    end
    tl, tw, tb = tl + l, tw + w, tb + b
    local tag = (a == "-") and "" or (" " .. a)
    if opts.l then io.write(l .. tag .. "\n")
    elseif opts.w then io.write(w .. tag .. "\n")
    elseif opts.c then io.write(b .. tag .. "\n")
    else io.write(l .. " " .. w .. " " .. b .. tag .. "\n") end
    if close then close:close() end
  end
end
if not (opts.l or opts.w or opts.c) and #args > 1 then
  io.write(tl .. " " .. tw .. " " .. tb .. " total\n")
end
