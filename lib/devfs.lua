-- devfs: OpenOS-style device filesystem, ported to Freax (OC Lua 5.2).
-- The kernel owns mounts, so this module exposes the mountable api.proxy
-- plus api.mount/api.umount wrappers. OpenOS-only pieces (device_labeling
-- rules, /lib/core/devfs auto-registration) are stubbed locally.

local fs = require("fs")
local text = require("text")

-- Freax's fs.lua omits OpenOS's fs.segments; supply it here so the rest of
-- this port can keep the OpenOS fs.segments/fs.path/fs.name dot-calls.
if not fs.segments then
  function fs.segments(path)
    local parts = {}
    for part in tostring(path):gmatch("[^/\\]+") do
      if part == "." or part == "" then
        -- skip
      elseif part == ".." then
        if #parts > 0 then table.remove(parts) end
      else
        parts[#parts + 1] = part
      end
    end
    return parts
  end
end

local function checkArg(n, val, ...)
  local t = type(val)
  for i = 1, select("#", ...) do
    if t == select(i, ...) then return end
  end
  error(string.format("bad argument #%d (%s expected, got %s)",
    n, table.concat({...}, "/"), t))
end

local api = {}

local function new_node(proxy)
  local node = {proxy=proxy}
  if not proxy or not proxy.list then
    node.children = {}
  end
  return node
end

local function array_read(array, separator)
  separator = separator or " "
  local builder = {}
  for _,value in ipairs(array) do
    table.insert(builder, tostring(value))
  end
  return table.concat(builder, separator)
end

local function child_iterator(node)
  -- a node can either list or have children, but not both (see add_child)
  -- a node can be a file, which has a proxy, but no children
  local listed = {}
  if node then
    if node.proxy and node.proxy.list then
      -- list should return a table, not another iterator
      -- the elements in the list are not nodes, but proxies
      -- we have to wrap each entry with a virtual node (a node that is not in a child-parent tree)
      -- list can be a function that returns a table, or the table already
      local list = node.proxy.list
      listed = type(list) == "table" and list or list()
    elseif node.children then
      listed = node.children
    end
  end
  local availables = {}
  for name, item in pairs(listed) do
    if name:len() > 0 then
      if not item.proxy then item = new_node(item) end
      if not item.proxy.isAvailable or item.proxy.isAvailable() then
        availables[name] = item
      end
    end
  end
  return pairs(availables)
end

local function get_child(node, name)
  for child_name, child in child_iterator(node) do
    if child_name == name then
      return child
    end
  end
end

local function add_child(node, name, proxy)
  if not node or node.proxy and node.proxy.list then
    return nil, "cannot add child to listing proxy"
  end

  local child = new_node(proxy)
  node.children[name] = child
  return child
end

local function findNode(path, bCreate)
  local segments = fs.segments(path)
  local node = api.root
  while #segments > 0 do
    local name = table.remove(segments, 1)
    local next = get_child(node, name)
    if not next then
      if bCreate then
        if not add_child(node, name) then
          return nil, "cannot create child node"
        end
      else
        return nil, "no such file or directory"
      end
    end
    node = next or get_child(node, name)
  end
  return node
end

-- devfs api

api.root = new_node()

function api.create(path, proxy)
  checkArg(1, path, "string")
  checkArg(2, proxy, "table", "nil")
  local pwd = fs.path(path)
  local name = fs.name(path)
  if not name then return nil, "invalid devfs path" end
  local pnode, why = findNode(pwd, true)
  if not pnode then
    return nil, why
  end

  if get_child(pnode, name) then
    return nil, "file or directory exists"
  end

  return add_child(pnode, name, proxy)
end

-- the filesystem object as seen from the system mount interface
api.proxy = {}

-- forward declare injector
local inject_dynamic_pairs
local function dynamic_list(path, fsnode)
  local nodes, links, dirs = {}, {}, {}
  local node = findNode(path)
  if node then
    for name,cnode in child_iterator(node) do
      if cnode.proxy and cnode.proxy.link then
        links[name] = cnode.proxy.link
      elseif cnode.proxy and cnode.proxy.list then
        local child = {name=name,parent=fsnode}
        local child_path = path .. "/" .. name
        inject_dynamic_pairs(child, child_path, true)
        dirs[name] = child
      else
        nodes[name] = cnode
      end
    end
  end
  return nodes, links, dirs
end

inject_dynamic_pairs = function(fsnode, path, bStoreUse)
  if getmetatable(fsnode) then return end
  fsnode.children = nil
  fsnode.links = nil
  setmetatable(fsnode,
  {
    __index = function(tbl, key)
      local bLinks = key == "links"
      local bChildren = key == "children"
      if not bLinks and not bChildren then return end
      local _, links, dirs = dynamic_list(path, tbl)
      if bStoreUse then
        tbl.children = dirs
        tbl.links = links
      end
      return bLinks and links or dirs
    end
  })
end

-- OpenOS loads /lib/core/device_labeling.lua here. Freax ships no such
-- module, so labels go straight to the underlying device proxy.
function api.getDeviceLabel(proxy)
  if type(proxy) == "string" then proxy = fs.get(proxy) end
  if proxy and proxy.getLabel then return proxy.getLabel() end
  return nil
end

function api.setDeviceLabel(proxy, label)
  if type(proxy) == "string" then proxy = fs.get(proxy) end
  if proxy and proxy.setLabel then return proxy.setLabel(label) end
  return nil, "cannot set label"
end

local registered = false
function api.register(public_proxy)
  if registered then return end
  registered = true

  -- OpenOS scans /lib/core/devfs/*.lua for built-in nodes. Freax ships no
  -- such directory, so this is a no-op unless one is present.
  local start_path = "/lib/core/devfs/"
  if fs.exists(start_path) then
    for _, starter in ipairs(fs.list(start_path) or {}) do
      local full_path = start_path .. starter
      local _,matched = starter:gsub("%.lua$","")
      if matched > 0 and dofile then
        local data = dofile(full_path)
        for name, entry in pairs(data) do
          api.create(name, entry)
        end
      end
    end
  end

  if rawget(public_proxy, "fsnode") then
    inject_dynamic_pairs(public_proxy.fsnode, "")
  end
end

-- Freax's kernel owns the mount table and exposes no runtime hook for
-- mounting a pure-Lua proxy (freax.fsMount takes a device address), so these
-- wrappers delegate to the filesystem shim for API compatibility.
function api.mount(path)
  checkArg(1, path, "string", "nil")
  return fs.mount(api.proxy, path or "/dev")
end

function api.umount(path)
  checkArg(1, path, "string", "nil")
  return fs.umount(path or "/dev")
end

-- Freax's text.lua omits OpenOS's text.internal stream handles (they live in
-- full_text.lua upstream). Provide minimal equivalents so devfs nodes can be
-- opened/read/written through the same code path.
if not text.internal.reader then
  local function stream_seek(handle, whence, to)
    if not handle.txt then
      return nil, "bad file descriptor"
    end
    to = to or 0
    local offset = handle.index
    if whence == "cur" then
      offset = offset + to
    elseif whence == "set" then
      offset = to
    elseif whence == "end" then
      offset = handle.len + to
    end
    offset = math.max(0, math.min(offset, handle.len))
    handle.index = offset
    return offset
  end

  function text.internal.reader(txt, mode)
    local handle = {txt = txt, len = string.len(txt), index = 0}
    function handle.read(_, n)
      if not handle.txt then
        return nil, "bad file descriptor"
      end
      if handle.index >= handle.len then
        return nil
      end
      local next = handle.txt:sub(handle.index + 1, handle.index + n)
      handle.index = handle.index + #next
      return next
    end
    function handle.close(_)
      if not handle.txt then
        return nil, "bad file descriptor"
      end
      handle.txt = nil
      return true
    end
    function handle.seek(_, whence, to)
      return stream_seek(handle, whence, to)
    end
    return handle
  end

  function text.internal.writer(ostream, mode, append_txt)
    local handle = {txt = "", len = 0, index = 0}
    function handle.write(_, ...)
      if not handle.txt then
        return nil, "bad file descriptor"
      end
      local pre = handle.txt:sub(1, handle.index)
      local pos = handle.txt:sub(handle.index + 1)
      local vs = {}
      for _, v in ipairs({...}) do
        table.insert(vs, v)
      end
      vs = table.concat(vs)
      handle.index = handle.index + #vs
      handle.txt = pre .. vs .. pos
      handle.len = string.len(handle.txt)
      return true
    end
    function handle.close(_)
      if not handle.txt then
        return nil, "bad file descriptor"
      end
      ostream((append_txt or "") .. handle.txt)
      handle.txt = nil
      return true
    end
    function handle.seek(_, whence, to)
      return stream_seek(handle, whence, to)
    end
    return handle
  end
end

function api.proxy.list(path)
  local result = {}
  -- dynamic_list returns nodes, links and directories separately; passing it
  -- straight into pairs() only ever saw the first table
  local nodes, links, dirs = dynamic_list(path, false)
  for name in pairs(nodes) do result[#result + 1] = name end
  for name in pairs(links) do result[#result + 1] = name end
  for name in pairs(dirs) do
    if not links[name] then result[#result + 1] = name .. "/" end
  end
  table.sort(result)
  return result
end

function api.proxy.isDirectory(path)
  local node = findNode(path)
  if not node then return false end
  -- a node is a directory when it has children, or its proxy can list
  if next(node.children or {}) then return true end
  return not not (node.proxy and node.proxy.list)
end

function api.proxy.size(path)
  checkArg(1, path, "string")
  local node = findNode(path)
  if not node or not node.proxy then
    return 0
  end

  local proxy = node.proxy
  if proxy.list then return 0 end
  if proxy.size then return proxy.size() end
  if proxy.open then return 0 end
  if proxy.read then return proxy.read():len() end
  if proxy[1] ~= nil then return array_read(proxy):len() end
  return 0
end

function api.proxy.lastModified()
  return 0
end

function api.proxy.exists(path)
  checkArg(1, path, "string")
  return not not findNode(path)
end

function api.getDevice(path)
  checkArg(1, path, "string")
  local device
  local reason = "no such device"
  local real, why = fs.realPath(fs.resolve(path))
  if not real then return nil, why end
  if fs.exists(real) then
    -- we don't have a good way of knowing where dev is mounted still
    -- similar hack in api.proxy.open
    real = fs.concat(fs.path(real), fs.name(real) or "")
    local part, subbed = real:gsub("^/dev/", "")
    if subbed > 0 and part:len() > 0 then
      local node = findNode(part)
      if node and node.proxy then
        -- must be a special device node
        device = node.proxy.device
      end
      if not device then
        reason = "not a device"
      end
    else
      device, reason = fs.get(real)
    end
  end
  return device, reason
end

function api.proxy.open(path, mode)
  checkArg(1, path, "string")
  checkArg(2, mode, "string", "nil")

  mode = mode or "r"
  local bRead = mode:match("[ra]")
  local bWrite = mode:match("[wa]")

  if not bRead and not bWrite then
    return nil, "invalid mode"
  end

  local node, why = findNode(path)
  if not node then
    return nil, why
  elseif not node.proxy or node.proxy.list then
    return nil, "is a directory"
  end

  local proxy = node.proxy

  -- in case someone tries to open a link directly, refer them back to fs.
  -- Freax's kernel expands virtual links before dispatch, so this is mostly
  -- vestigial, but kept for OpenOS parity.
  if proxy.link then
    return fs.open("/dev/"..path, mode)
  end

  -- special (but common) simple readonly cases
  if proxy[1] ~= nil then -- contains special readonly value
    local array = proxy
    proxy.read = function()return array_read(array) end
  end

  if proxy.open then
    return proxy.open(mode)
  end

  if bRead and not proxy.read then
    return nil, "cannot open for read"
  elseif bWrite and not proxy.write then
    return nil, "cannot open for write"
  end

  local txtRead = bRead and proxy.read()

  if bWrite then
    return text.internal.writer(proxy.write, mode, txtRead)
  end

  return text.internal.reader(txtRead, mode)
end

-- as long as the fsnode hack is used, fs.isLink is not needed here
-- function api.proxy.isLink(path) end

local function checked_invoke(handle, method, ...)
  checkArg(1, handle, "table")
  checkArg(2, method, "string")
  checkArg(3, handle[method], "function", "table", "nil")
  local m = handle[method]
  if not m then
    return nil, "bad file handle"
  elseif type(m) == "table" then
    local mm = getmetatable(m)
    assert(mm and mm.__call, string.format("FILE handle [%s] method defined, but is not callable", tostring(method)))
  end
  return m(handle, ...)
end

function api.proxy.read(h, ...)
  return checked_invoke(h, "read", ...)
end

function api.proxy.close(h, ...)
  return checked_invoke(h, "close", ...)
end

function api.proxy.write(h, ...)
  return checked_invoke(h, "write", ...)
end

function api.proxy.seek(h, ...)
  return checked_invoke(h, "seek", ...)
end

function api.proxy.remove()
  return nil, "cannot remove file or directory"
end

function api.proxy.makeDirectory()
  return nil, "use create in the devfs api"
end

function api.proxy.setLabel()
  return nil, "cannot set label on devfs"
end

return api
