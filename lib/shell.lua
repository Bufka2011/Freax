local freax = freax

local shell = {}

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

function shell.resolve(path, ext)
  path = tostring(path or "")
  if path:sub(1, 1) == "/" then
    path = freax.fsCanonical(path)
  else
    path = freax.fsCanonical(freax.fsConcat(freax.getCwd(), path))
  end
  if not ext then
    return path
  end
  local name = freax.fsName(path)
  if not name then
    return path
  end
  local dir = path:sub(1, #path - #name)
  if dir == "" then dir = "/" end
  local has_slash = path:find("/")
  local search_in = has_slash and dir or (os.getenv("PATH") or "/sbin:/bin:/usr/bin:.")
  for search_path in search_in:gmatch("[^:]+") do
    local base = freax.fsCanonical(freax.fsConcat(shell.getWorkingDirectory(), search_path))
    local cand = freax.fsCanonical(base .. "/" .. name)
    if not freax.fsExists(cand) then
      cand = cand .. "." .. ext
    end
    if freax.fsExists(cand) and not freax.fsIsDir(cand) then
      return cand
    end
  end
  return nil, "file not found"
end

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

function shell.execute(cmd)
  if not cmd then return false end
  return os.execute(tostring(cmd))
end

local aliases = {}
function shell.getAlias(a) return aliases[a] end
function shell.setAlias(a, v) aliases[a] = v end
function shell.aliases()
  local i = 0
  local ks = {}
  for k in pairs(aliases) do ks[#ks + 1] = k end
  table.sort(ks)
  return coroutine.wrap(function()
    for _, k in ipairs(ks) do
      coroutine.yield(k, aliases[k])
    end
  end)
end

local shell_cache = {}
function shell.getShell()
  local path = os.getenv("SHELL") or "/bin/sh"
  local resolved, err = shell.resolve(path, "lua")
  if not resolved then return nil, err end
  if shell_cache[resolved] then return shell_cache[resolved] end
  local ok, fn = pcall(dofile, resolved)
  if not ok then return nil, fn end
  shell_cache[resolved] = fn
  return fn
end

return shell