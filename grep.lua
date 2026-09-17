-- grep: Lua-pattern search over files or stdin (pipe-clean).
-- NOTE: patterns are Lua patterns, not POSIX regex.
-- Flags: -v invert, -i case-fold, -n line numbers, -c counts only.
local fs = require("fs")
local shell = require("shell")

local args, opts = shell.parse(...)
if #args == 0 or opts.help then
  io.write("Usage: grep [-vin] [-c] PATTERN [FILE...]\n")
  return
end

local pat = table.remove(args, 1)
if opts.i then pat = pat:lower() end
if #args == 0 then args = { "-" } end

local ec, found = 0, false
for _, a in ipairs(args) do
  local iter, close, err, label = nil, nil, nil, a
  if a == "-" then
    iter = io.stdin:lines()
    label = "(stdin)"
  else
    local f
    f, err = io.open(shell.resolve(a), "r")
    if f then
      iter = f:lines()
      close = f
    end
  end
  if not iter then
    ec = 2
    io.stderr:write("grep: " .. a .. ": " .. tostring(err) .. "\n")
  else
    local ln, count = 0, 0
    for line in iter do
      ln = ln + 1
      local hay = opts.i and line:lower() or line
      local hit = hay:find(pat) ~= nil
      if opts.v then hit = not hit end
      if hit then
        count, found = count + 1, true
        if not opts.c then
          local pre = ""
          if #args > 1 then pre = label .. ":" end
          if opts.n then pre = pre .. ln .. ":" end
          io.write(pre .. line .. "\n")
        end
      end
    end
    if opts.c then io.write((#args > 1 and (label .. ":") or "") .. count .. "\n") end
    if close then close:close() end
  end
end
-- standard grep codes: 0 match, 1 no match, 2 file errors
if ec == 0 then return found and 0 or 1 end
return ec
