-- shell: Freax shell helper lib (M1).
-- Inspired by OpenOS lib/shell.lua: parse + resolve + cwd.
-- No unicode dep (Tier1 friendly, uses string).

local freax = freax

local shell = {}

-- parse("cp", "-rv", "--skip=x", "a", "b") -> {"a","b"}, {r=true,v=true,skip="x"}
-- OpenOS-compatible: --key=val, --flag, -abc, -- stops options.
function shell.parse(...)
  local params = table.pack(...)
  local args, opts = {}, {}
  local done = false
  for i = 1, params.n do
    local p = params[i]
    if not done and type(p) == "string" then
      if p == "--" then
        done = true
      elseif p:sub(1, 2) == "--" then
        local k, v = p:match("^%-%-(.-)=(.*)$")
        if not k then k, v = p:sub(3), true end
        opts[k] = v
      elseif p:sub(1, 1) == "-" and p ~= "-" then
        for j = 2, #p do opts[p:sub(j, j)] = true end
      else
        args[#args + 1] = p
      end
    else
      args[#args + 1] = p
    end
  end
  return args, opts
end

function shell.getWorkingDirectory() return freax.getCwd() end
function shell.setWorkingDirectory(dir)
  local ok, err = freax.setCwd(dir)
  if ok then return true end
  return nil, err
end

-- resolve relative paths against cwd; absolute passes through canonical.
function shell.resolve(path)
  path = tostring(path or "")
  if path:sub(1, 1) == "/" then return freax.fsCanonical(path) end
  return freax.fsCanonical(freax.fsConcat(freax.getCwd(), path))
end

-- resolve a command name via PATH (OpenOS-ish: /bin + cwd fallback).
function shell.resolveCmd(name)
  if name:find("/") then return shell.resolve(name) end
  local PATH = (os and os.getenv and os.getenv("PATH")) or "/bin"
  for dir in PATH:gmatch("[^:]+") do
    for _, cand in ipairs({ dir .. "/" .. name .. ".lua", dir .. "/" .. name }) do
      if freax.fsExists(cand) then return cand end
    end
  end
  return "/bin/" .. name .. ".lua"
end

-- foreground execute (whitespace split; real parser lands in M2 bash).
-- Delegates to os.execute so stdio redirection is honoured.
function shell.execute(cmd)
  if not cmd then return false end
  return os.execute(tostring(cmd))
end

-- aliases: stored, honoured by the M2 shell (M1 sh ignores them).
local aliases = {}
function shell.getAlias(a) return aliases[a] end
function shell.setAlias(a, v) aliases[a] = v end

return shell
