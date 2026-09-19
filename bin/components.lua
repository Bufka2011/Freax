-- components: list hardware (M2). -l method docs need proxies and
-- stay unsupported; addresses/types come from the kernel inventory.
local text = require("text")
local shell = require("shell")

local args, options = shell.parse(...)
local count = tonumber(options.limit) or math.huge

if #args == 0 then args[1] = "" end -- no filter = everything

if #args == 0 then args[1] = "" end

local matches = {}
for _, d in ipairs(freax.devices()) do
  for _, filter in ipairs(args) do
    if d.type:find(filter, 1, true) or d.address:find(filter, 1, true) then
      matches[#matches + 1] = d
    end
  end
end

local padTo = 1
for _, d in ipairs(matches) do
  if #d.type + 2 > padTo then padTo = #d.type + 2 end
end
padTo = padTo + 8 - padTo % 8
for _, d in ipairs(matches) do
  io.write(text.padRight(d.type, padTo) .. d.address .. "\n")
  if options.l then
    local ok, proxy = pcall(require, "component")
    if ok then
      proxy = proxy.proxy(d.address)
      local methods = {}
      for name, member in pairs(proxy) do
        if type(member) == "table" or type(member) == "function" then
          table.insert(methods, name)
        end
      end
      table.sort(methods)
      for _, name in ipairs(methods) do
        io.write("  " .. name .. " (method)\n")
      end
    end
  end
  count = count - 1
  if count <= 0 then break end
end
