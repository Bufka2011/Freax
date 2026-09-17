-- label: show/set filesystem labels (M2).
-- Usage: label [-a] <mount-path|addr-prefix> [newlabel]
-- (-a kept for muscle memory; both forms match by path or address.)
local fs = require("fs")
local shell = require("shell")

local args, options = shell.parse(...)
if #args < 1 then
  io.write("Usage: label <device> [<label>]\n")
  return 1
end

local filter = args[1]
local function find()
  for _, d in ipairs(fs.devices()) do
    if (d.mount or "") == filter or d.addr == filter
      or d.addr:sub(1, #filter) == filter
      or (d.label or "") == filter then
      return d
    end
  end
  -- maybe a path on some mounted fs: resolve its mount
  local abs = shell.resolve(filter)
  for _, m in ipairs(fs.mounts()) do
    if abs == m.path or abs:sub(1, #m.path + 1) == m.path .. "/" then
      for _, d in ipairs(fs.devices()) do
        if d.addr == m.addr then return d end
      end
    end
  end
  return nil
end

local dev = find()
if not dev then
  io.stderr:write("label: no such device\n")
  return 1
end

if #args < 2 then
  local label = freax.fsLabel(dev.addr)
  if label and label ~= "" then print(label)
  else
    io.stderr:write("no label\n")
    return 1
  end
else
  local ok, err = freax.fsSetLabel(dev.addr, args[2])
  if not ok then
    io.stderr:write("label: " .. tostring(err) .. "\n")
    return 1
  end
end
