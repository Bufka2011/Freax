-- yes: repeat a line until killed or pipe closes (M2).
local s = (...) or "y"
while true do
  local ok = io.write(tostring(s) .. "\n")
  if not ok then return end -- reader went away (broken pipe)
end
