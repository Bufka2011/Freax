local fs = require("fs")

local package = {}
package.config = "/\n;\n?\n!\n-\n"
package.path = "/lib/?.lua;/usr/lib/?.lua;/home/lib/?.lua;./?.lua;/lib/?/init.lua;/usr/lib/?/init.lua;/home/lib/?/init.lua;./?/init.lua"

local loading = {}
local preload = {}
local searchers = {}

local loaded = {
  _G = _G,
  bit32 = bit32,
  coroutine = coroutine,
  math = math,
  os = os,
  package = package,
  string = string,
  table = table,
}
package.loaded = loaded
package.preload = preload
package.searchers = searchers

function package.searchpath(name, path, sep, rep)
  if type(name) ~= "string" then error("bad argument #1 (string expected, got " .. type(name) .. ")") end
  if type(path) ~= "string" then error("bad argument #2 (string expected, got " .. type(path) .. ")") end
  sep = sep or '.'
  rep = rep or '/'
  name = string.gsub(name, '%' .. sep, rep)
  local errorFiles = {}
  for subPath in string.gmatch(path, "([^;]+)") do
    subPath = string.gsub(subPath, "?", name)
    if subPath:sub(1, 1) ~= "/" and os.getenv then
      subPath = fs.concat(os.getenv("PWD") or "/", subPath)
    end
    if fs.exists(subPath) then
      return subPath
    end
    table.insert(errorFiles, "no file '" .. subPath .. "'")
  end
  return nil, table.concat(errorFiles, "\n\t")
end

table.insert(searchers, function(module)
  if package.preload[module] then
    return package.preload[module]
  end
  return "no field package.preload['" .. module .. "']"
end)

table.insert(searchers, function(module)
  local library, path, status
  path, status = package.searchpath(module, package.path)
  if not path then
    return status
  end
  library, status = loadfile(path)
  if not library then
    error("error loading module '" .. module .. "' from file '" .. path .. "':\n\t" .. tostring(status))
  end
  return library, module
end)

require = function(module)
  if type(module) ~= "string" then error("bad argument #1 (string expected, got " .. type(module) .. ")") end
  if loaded[module] ~= nil then
    return loaded[module]
  elseif loading[module] then
    error("already loading: " .. module, 2)
  else
    local library, status, arg
    local errors = ""
    if type(searchers) ~= "table" then error("'package.searchers' must be a table") end
    for _, searcher in pairs(searchers) do
      library, arg = searcher(module)
      if type(library) == "function" then break end
      if library ~= nil then
        errors = errors .. "\n\t" .. tostring(library)
        library = nil
      end
    end
    if not library then error("module '" .. module .. "' not found:" .. errors) end
    loading[module] = true
    library, status = pcall(library, arg or module)
    loading[module] = false
    if not library then
      error("module '" .. module .. "' load failed:\n" .. tostring(status))
    end
    if status == nil then status = true end
    loaded[module] = status
    return status
  end
end

function package.delay(lib, file)
  local mt = {}
  function mt.__index(tbl, key)
    mt.__index = nil
    if lib.internal then
      setmetatable(lib.internal, mt)
    end
    setmetatable(lib, mt)
    dofile(file)
    return tbl[key]
  end
  if lib.internal then
    setmetatable(lib.internal, mt)
  end
  setmetatable(lib, mt)
end

return package
