-- lua: run a script file, or REPL with no args (M2).
local shell = require("shell")

local args = table.pack(...)

local function runSrc(src, name)
  local fn, err = load(src, "=" .. name, "t")
  if not fn then
    io.stderr:write(tostring(err) .. "\n")
    return false
  end
  local ok, res = pcall(fn)
  if not ok then io.stderr:write(tostring(res) .. "\n") end
  return ok
end

if args[1] then
  local path = shell.resolve(args[1])
  local f, err = io.open(path, "r")
  if not f then
    io.stderr:write("lua: " .. tostring(err) .. "\n")
    return
  end
  local src = f:read("*a") or ""
  f:close()
  src = src:gsub("^#![^\n]*\n?", "")
  runSrc(src, path)
  return
end

-- REPL (tty interactive, like OpenOS lua REPL tone)
local term = require("term")
term.writeln("Freax Lua -- Ctrl+D (code 4) or 'exit' quits")
while true do
  term.write("> ")
  local line = term.readLine()
  if not line or line == "exit" then return end
  if line:match("%S") then
    local fn = load("return " .. line, "=stdin", "t")
      or load(line, "=stdin", "t")
    if not fn then
      io.stderr:write("syntax error\n")
    else
      local res = table.pack(pcall(fn))
      if res[1] then
        for i = 2, res.n do
          if res[i] ~= nil then term.writeln(tostring(res[i])) end
        end
      else
        io.stderr:write(tostring(res[2]) .. "\n")
      end
    end
  end
end
