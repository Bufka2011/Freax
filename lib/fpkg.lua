-- fpkg: Freax package archive (.fpkg) format + control metadata.
-- Plain stream-oriented container (no compression): magic line, control
-- stanza, optional Lua maintainer scripts, then data entries. Everything
-- streams in 4K chunks so a package never has to fit in RAM.

local fs = require("fs")
local sha256 = require("sha256")

local fpkg = {}

fpkg.VERSION = 1

local SCRIPT_NAMES = { preinst = true, postinst = true, prerm = true, postrm = true }

function fpkg.arch() return "all" end

---------------------------------------------------------------
-- RFC822 control stanzas
---------------------------------------------------------------

local function splitLines(text)
  local out = {}
  for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    out[#out + 1] = line:gsub("\r$", "")
  end
  return out
end

function fpkg.parseControl(text)
  local fields, order = {}, {}
  local cur
  for _, line in ipairs(splitLines(text)) do
    if line:match("^[ \t]") then
      if cur then fields[cur] = fields[cur] .. "\n" .. line:sub(2) end
    elseif line == "" then
      cur = nil
    else
      local name, value = line:match("^([%w][%w%-]*):%s?(.*)$")
      if name then
        if fields[name] == nil then order[#order + 1] = name end
        fields[name] = value
        cur = name
      else
        cur = nil
      end
    end
  end
  return fields, order
end

local function fieldOrder(fields, order)
  if order and #order > 0 then return order end
  local out = {}
  for k in pairs(fields) do
    if type(k) == "string" then out[#out + 1] = k end
  end
  table.sort(out)
  return out
end

function fpkg.serializeControl(fields, order)
  local out = {}
  for _, name in ipairs(fieldOrder(fields, order)) do
    local value = fields[name]
    if value ~= nil then
      local first, rest = tostring(value):match("^([^\n]*)\n?(.*)$")
      out[#out + 1] = name .. ": " .. first
      if rest and #rest > 0 then
        for line in (rest .. "\n"):gmatch("(.-)\n") do
          out[#out + 1] = " " .. line
        end
      end
    end
  end
  return table.concat(out, "\n") .. "\n"
end

function fpkg.parseStanzas(text)
  local stanzas, block = {}, {}
  local function flush()
    if #block == 0 then return end
    local fields, order = fpkg.parseControl(table.concat(block, "\n"))
    stanzas[#stanzas + 1] = { fields = fields, order = order }
    block = {}
  end
  for _, line in ipairs(splitLines(text)) do
    if line:match("^%s*$") then flush() else block[#block + 1] = line end
  end
  flush()
  return stanzas
end

function fpkg.stanzaField(stanza, name)
  if not stanza then return nil end
  return stanza.fields and stanza.fields[name]
end

---------------------------------------------------------------
-- Version and dependency handling
---------------------------------------------------------------

local function order(c)
  if c == nil or c == "" then return 0 end
  local b = c:byte()
  if b >= 48 and b <= 57 then return 0 end
  if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) then return b end
  if c == "~" then return -1 end
  return b + 256
end

local function isDigit(c)
  return c ~= nil and c ~= "" and c:match("%d") ~= nil
end

local function verrevcmp(a, b)
  a, b = a or "", b or ""
  local i, j = 1, 1
  while i <= #a or j <= #b do
    local first_diff = 0
    while (i <= #a and not isDigit(a:sub(i, i)))
      or (j <= #b and not isDigit(b:sub(j, j))) do
      local ac = order(a:sub(i, i))
      local bc = order(b:sub(j, j))
      if ac ~= bc then return ac < bc and -1 or 1 end
      i, j = i + 1, j + 1
    end
    while a:sub(i, i) == "0" do i = i + 1 end
    while b:sub(j, j) == "0" do j = j + 1 end
    while isDigit(a:sub(i, i)) and isDigit(b:sub(j, j)) do
      if first_diff == 0 then first_diff = a:byte(i) - b:byte(j) end
      i, j = i + 1, j + 1
    end
    if isDigit(a:sub(i, i)) then return 1 end
    if isDigit(b:sub(j, j)) then return -1 end
    if first_diff ~= 0 then return first_diff < 0 and -1 or 1 end
  end
  return 0
end

local function splitVersion(v)
  v = tostring(v or "")
  local epoch, rest = v:match("^(%d+):(.*)$")
  epoch = tonumber(epoch) or 0
  if not rest then rest = v end
  local upstream, revision = rest:match("^(.*)%-(.*)$")
  if not upstream then upstream, revision = rest, "" end
  return epoch, upstream, revision
end

function fpkg.versionCompare(a, b)
  local ea, ua, ra = splitVersion(a)
  local eb, ub, rb = splitVersion(b)
  if ea ~= eb then return ea < eb and -1 or 1 end
  local c = verrevcmp(ua, ub)
  if c ~= 0 then return c end
  return verrevcmp(ra, rb)
end

function fpkg.satisfies(version, op, target)
  local c = fpkg.versionCompare(version, target)
  if op == ">=" then return c >= 0 end
  if op == "<=" then return c <= 0 end
  if op == "=" then return c == 0 end
  if op == ">>" or op == ">" then return c > 0 end
  if op == "<<" or op == "<" then return c < 0 end
  return false
end

function fpkg.parseDepends(str)
  local groups = {}
  for group in tostring(str or ""):gmatch("[^,]+") do
    group = group:match("^%s*(.-)%s*$")
    if group ~= "" then
      local opts = {}
      for alt in group:gmatch("[^|]+") do
        alt = alt:match("^%s*(.-)%s*$")
        local name, op, ver = alt:match("^([%w%+%.%-]+)%s*%(([<>=]+)%s*([^%)]+)%)")
        if name then
          opts[#opts + 1] = { name = name, op = op, version = ver:match("^%s*(.-)%s*$") }
        else
          name = alt:match("^([%w%+%.%-]+)")
          if name then opts[#opts + 1] = { name = name } end
        end
      end
      if #opts > 0 then groups[#groups + 1] = opts end
    end
  end
  return groups
end

---------------------------------------------------------------
-- Reading
---------------------------------------------------------------

local Reader = {}
Reader.__index = Reader

function Reader:readLine()
  local buf = self.buf
  while true do
    local nl = buf:find("\n", 1, true)
    if nl then
      self.buf = buf:sub(nl + 1)
      return buf:sub(1, nl - 1)
    end
    local chunk = fs.read(self.fd, 4096)
    if not chunk or chunk == "" then
      self.buf = ""
      if #buf > 0 then return buf end
      return nil
    end
    buf = buf .. chunk
    if #buf > 1048576 then return nil, "header too long" end
  end
end

function Reader:readHeader()
  while true do
    local line, err = self:readLine()
    if not line then return nil, err end
    if line ~= "" then
      local typ, len, path = line:match("^@entry%s+(%a+)%s+(%d+)%s+(.*)$")
      if typ then return typ, tonumber(len), path end
      if line:match("^@end%s*$") then return nil end
      return nil, "bad entry header: " .. line
    end
  end
end

function Reader:readPayload(n)
  local parts, got = {}, 0
  if #self.buf > 0 then
    local take = math.min(n, #self.buf)
    parts[#parts + 1] = self.buf:sub(1, take)
    self.buf = self.buf:sub(take + 1)
    got = take
  end
  while got < n do
    local chunk = fs.read(self.fd, math.min(4096, n - got))
    if not chunk or chunk == "" then break end
    local want = n - got
    if #chunk > want then
      parts[#parts + 1] = chunk:sub(1, want)
      self.buf = chunk:sub(want + 1) .. self.buf
      got = n
    else
      parts[#parts + 1] = chunk
      got = got + #chunk
    end
  end
  if got < n then return nil, "truncated payload" end
  return table.concat(parts)
end

function Reader:loadScripts()
  if self.scriptsLoaded then return self.scripts end
  self.scriptsLoaded = true
  while true do
    local typ, len, path = self:readHeader()
    if not typ then
      if len then return nil, len end
      break
    end
    if typ == "control" and path ~= "control" and path:sub(1, 1) ~= "/" then
      local src, err = self:readPayload(len)
      if not src then return nil, err end
      self.scripts[path] = src
    else
      self.pending = { type = typ, size = len, path = path }
      break
    end
  end
  return self.scripts
end

function Reader:next()
  if not self.scriptsLoaded then
    local _, err = self:loadScripts()
    if err then return nil, err end
  end
  if self.entry and self.entry.remaining > 0 then self:skip() end
  local typ, len, path
  if self.pending then
    typ, len, path = self.pending.type, self.pending.size, self.pending.path
    self.pending = nil
  else
    local t, l, p = self:readHeader()
    if not t then
      if l then return nil, l end
      return nil
    end
    typ, len, path = t, l, p
  end
  while typ == "control" and path:sub(1, 1) ~= "/" do
    local src, err = self:readPayload(len)
    if not src then return nil, err end
    self.scripts[path] = src
    local t, l, p = self:readHeader()
    if not t then
      if l then return nil, l end
      return nil
    end
    typ, len, path = t, l, p
  end
  local entry = { type = typ, path = path, size = len, remaining = len }
  if typ == "l" then
    local target, err = self:readPayload(len)
    if not target then return nil, err end
    entry.target = target
    entry.remaining = 0
  end
  self.entry = entry
  return entry
end

function Reader:readData(max)
  local entry = self.entry
  if not entry then return nil, "no current entry" end
  if entry.remaining <= 0 then return nil end
  max = tonumber(max) or 4096
  local want = math.min(max, entry.remaining)
  local parts, got = {}, 0
  if #self.buf > 0 then
    local take = math.min(want, #self.buf)
    parts[#parts + 1] = self.buf:sub(1, take)
    self.buf = self.buf:sub(take + 1)
    got = take
  end
  while got < want do
    local chunk = fs.read(self.fd, math.min(4096, want - got))
    if not chunk or chunk == "" then break end
    local room = want - got
    if #chunk > room then
      parts[#parts + 1] = chunk:sub(1, room)
      self.buf = chunk:sub(room + 1) .. self.buf
      got = want
    else
      parts[#parts + 1] = chunk
      got = got + #chunk
    end
  end
  entry.remaining = entry.remaining - got
  if got == 0 then return nil end
  return table.concat(parts)
end

function Reader:skip()
  local entry = self.entry
  if not entry then return true end
  while entry.remaining > 0 do
    if not self:readData(4096) then break end
  end
  return true
end

function Reader:close()
  if self.fd then
    fs.close(self.fd)
    self.fd = nil
  end
  return true
end

function fpkg.open(path)
  local fd, err = fs.open(path, "r")
  if not fd then return nil, err end
  local self = setmetatable({
    fd = fd, buf = "", scripts = {}, scriptsLoaded = false,
  }, Reader)
  local magic = self:readLine()
  if not magic then self:close() return nil, "empty package" end
  if magic ~= "FREAXPKG 1" then self:close() return nil, "not a freax package" end
  local typ, len, p = self:readHeader()
  if not typ or typ ~= "control" or p ~= "control" then
    self:close()
    return nil, "missing control entry"
  end
  local ctrl, cerr = self:readPayload(len)
  if not ctrl then self:close() return nil, cerr end
  self.fields, self.order = fpkg.parseControl(ctrl)
  return self
end

function fpkg.readControl(path)
  local fd, err = fs.open(path, "r")
  if not fd then return nil, err end
  local first, rest = "", ""
  local buf = ""
  while true do
    local nl = buf:find("\n", 1, true)
    if nl then
      first, rest = buf:sub(1, nl - 1), buf:sub(nl + 1)
      break
    end
    local chunk = fs.read(fd, 4096)
    if not chunk or chunk == "" then
      first, rest = buf, ""
      break
    end
    buf = buf .. chunk
  end
  if first == "FREAXPKG 1" then
    fs.close(fd)
    local reader, oerr = fpkg.open(path)
    if not reader then return nil, oerr end
    local fields = reader.fields
    reader:close()
    return fields
  end
  local parts = { rest }
  while true do
    local chunk = fs.read(fd, 4096)
    if not chunk or chunk == "" then break end
    parts[#parts + 1] = chunk
  end
  fs.close(fd)
  local fields = fpkg.parseControl(first .. "\n" .. table.concat(parts))
  return fields
end

---------------------------------------------------------------
-- Writing
---------------------------------------------------------------

local Writer = {}
Writer.__index = Writer

function Writer:raw(data)
  local ok, err = fs.write(self.fd, data)
  if not ok then return nil, err end
  return true
end

function Writer:control(fields, order)
  if self.wroteControl then return nil, "control already written" end
  local text = fpkg.serializeControl(fields, order)
  local ok, err = self:raw("FREAXPKG 1\n@entry control " .. #text .. " control\n" .. text)
  if not ok then return nil, err end
  self.wroteControl = true
  return true
end

function Writer:script(name, text)
  if not self.wroteControl then return nil, "control must be written first" end
  if text == nil then return true end
  if not SCRIPT_NAMES[name] then return nil, "bad script name: " .. tostring(name) end
  text = tostring(text)
  local ok, err = self:raw("@entry control " .. #text .. " " .. name .. "\n" .. text)
  if not ok then return nil, err end
  return true
end

function Writer:addFile(absPath, asConffile, sourcePath)
  local src = sourcePath or absPath
  local size = fs.size(src)
  if not size then return nil, "cannot stat " .. tostring(src) end
  local typ = asConffile and "c" or "f"
  local ok, err = self:raw("@entry " .. typ .. " " .. size .. " " .. absPath .. "\n")
  if not ok then return nil, err end
  local infd, oerr = fs.open(src, "r")
  if not infd then return nil, oerr end
  local written = 0
  while true do
    local chunk = fs.read(infd, 4096)
    if not chunk or chunk == "" then break end
    local wok, werr = fs.write(self.fd, chunk)
    if not wok then fs.close(infd) return nil, werr end
    written = written + #chunk
  end
  fs.close(infd)
  if written ~= size then return nil, "size changed while reading " .. tostring(src) end
  return true
end

function Writer:addLink(absPath, target)
  target = tostring(target)
  local ok, err = self:raw("@entry l " .. #target .. " " .. absPath .. "\n" .. target)
  if not ok then return nil, err end
  return true
end

function Writer:addDir(absPath)
  local ok, err = self:raw("@entry d 0 " .. absPath .. "\n")
  if not ok then return nil, err end
  return true
end

function Writer:finish()
  if self.finished then return true end
  local ok, err = self:raw("@end\n")
  if self.fd then fs.close(self.fd) self.fd = nil end
  if not ok then return nil, err end
  self.finished = true
  return true
end

function fpkg.writer(path)
  local fd, err = fs.open(path, "w")
  if not fd then return nil, err end
  return setmetatable({ fd = fd }, Writer)
end

---------------------------------------------------------------
-- Helpers
---------------------------------------------------------------

function fpkg.hashFile(path)
  local fd, err = fs.open(path, "r")
  if not fd then return nil, nil, err end
  local h = sha256.new()
  local size = 0
  while true do
    local chunk = fs.read(fd, 4096)
    if not chunk or chunk == "" then break end
    h:update(chunk)
    size = size + #chunk
  end
  fs.close(fd)
  return h:hex(), size
end

function fpkg.ensureDir(path)
  path = tostring(path or "")
  if path == "" or path == "/" then return true end
  if fs.isDirectory(path) then return true end
  local cur = ""
  for seg in path:gmatch("[^/]+") do
    cur = cur .. "/" .. seg
    if not fs.exists(cur) then
      local ok, err = fs.makeDirectory(cur)
      if not ok and not fs.isDirectory(cur) then
        return nil, err or ("cannot create " .. cur)
      end
    elseif not fs.isDirectory(cur) then
      return nil, cur .. " is not a directory"
    end
  end
  return true
end

return fpkg
