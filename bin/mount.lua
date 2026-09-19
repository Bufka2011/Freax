for _, m in ipairs(freax.fsMounts()) do
  local label = ""
  for _, d in ipairs(freax.fsDevices()) do
    if d.addr == m.addr then label = d.label or "" break end
  end
  local rw = "rw"
  for _, d in ipairs(freax.fsDevices()) do
    if d.addr == m.addr then rw = d.readonly and "ro" or "rw" break end
  end
  local addr = m.addr and m.addr:sub(1, 8) or "?"
  io.write(string.format("%s on %s (%s) %s\n", addr, m.path, rw, label))
end