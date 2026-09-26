local raw = table.pack(...)
local args, options = {}, {}
local error_code = 0

local i = 1
while i <= raw.n do
  local arg = tostring(raw[i])
  if arg == "--" then
    for j = i + 1, raw.n do args[#args + 1] = raw[j] end
    break
  elseif arg:match("^%-%d+$") then
    options.lines = arg:sub(2)
    options.bytes = nil
  elseif arg == "-n" or arg == "--lines" or arg == "-c" or arg == "--bytes" then
    local key = (arg == "-n" or arg == "--lines") and "lines" or "bytes"
    i = i + 1
    if i > raw.n then
      io.stderr:write("head: option requires an argument -- '" .. arg .. "'\n")
      options.help = true
      error_code = 1
      break
    end
    options[key] = raw[i]
    options[key == "lines" and "bytes" or "lines"] = nil
  elseif arg:match("^%-n.+") then
    options.lines = arg:sub(3)
    options.bytes = nil
  elseif arg:match("^%-c.+") then
    options.bytes = arg:sub(3)
    options.lines = nil
  elseif arg:match("^%-%-lines=") then
    options.lines = arg:sub(9)
    options.bytes = nil
  elseif arg:match("^%-%-bytes=") then
    options.bytes = arg:sub(9)
    options.lines = nil
  elseif arg == "-q" or arg == "--quiet" or arg == "--silent" then
    options.quiet = true
  elseif arg == "-v" or arg == "--verbose" then
    options.verbose = true
  elseif arg == "--help" then
    options.help = true
  elseif arg:sub(1, 1) == "-" and arg ~= "-" then
    options[arg] = true
  else
    args[#args + 1] = raw[i]
  end
  i = i + 1
end

local function pop(key, convert)
  local result = options[key]
  options[key] = nil
  if result and convert then
    local c = tonumber(result)
    if not c then
      io.stderr:write(string.format("head: invalid number of %s: '%s'\n",
        key, tostring(result)))
      options.help = true
      error_code = 1
    end
    result = c
  end
  return result
end

local bytes = pop('bytes', true)
local lines = pop('lines', true)
local quiet = {pop('q'), pop('quiet'), pop('silent')}
quiet = quiet[1] or quiet[2] or quiet[3]
local verbose = {pop('v'), pop('verbose')}
verbose = verbose[1] or verbose[2]
local help = pop('help')

if help or next(options) then
  local invalid_key = next(options)
  if invalid_key then
    io.stderr:write(string.format("head: invalid option -- '%s'\n", invalid_key))
    error_code = 1
  end
  io.write([[Usage: head [OPTION]... [FILE]...
Print the first 10 lines of each FILE to standard output.
With no FILE, or when FILE is -, read standard input.
  -c, --bytes=[-]NUM    print the first NUM bytes
  -n, --lines=[-]NUM    print the first NUM lines instead of the first 10
  -q, --quiet, --silent never print headers giving file names
  -v, --verbose         always print headers giving file names
      --help            display this help and exit
]])
  os.exit(error_code)
end

if #args == 0 then
  args = {'-'}
end

if quiet and verbose then
  quiet = false
end

local function new_stream()
  local capacity = math.abs(lines or bytes or 10)
  return
  {
    open = capacity > 0,
    capacity = capacity,
    bytes = bytes,
    buffer = (lines and lines < 0 and {}) or (bytes and bytes < 0 and '')
  }
end

local function close(stream)
  if stream.buffer then
    if type(stream.buffer) == 'table' then
      stream.buffer = table.concat(stream.buffer)
    end
    io.stdout:write(stream.buffer)
    stream.buffer = nil
  end
  stream.open = false
end

local function push(stream, line)
  if not line then
    return close(stream)
  end

  local cost = stream.bytes and line:len() or 1
  stream.capacity = stream.capacity - cost

  if not stream.buffer then
    if stream.bytes and stream.capacity < 0 then
      line = line:sub(1, stream.capacity - 1)
    end
    io.write(line)
    if stream.capacity <= 0 then
      return close(stream)
    end
  else
    if type(stream.buffer) == 'table' then -- line storage
      stream.buffer[#stream.buffer + 1] = line
      if stream.capacity < 0 then
        table.remove(stream.buffer, 1)
        stream.capacity = 0 -- zero out
      end
    else -- byte storage
      stream.buffer = stream.buffer .. line
      if stream.capacity < 0 then
        stream.buffer = stream.buffer:sub(-stream.capacity + 1)
        stream.capacity = 0 -- zero out
      end
    end
  end
end

for i = 1, #args do
  local arg = args[i]
  local is_stdin = arg == '-'
  local file, reason
  if is_stdin then
    file = io.stdin
  else
    file, reason = io.open(arg, 'r')
    if not file then
      io.stderr:write(string.format("head: cannot open '%s' for reading: %s\n",
        arg, tostring(reason)))
      error_code = 1
    end
  end
  if file then
    -- stdin never gets a header; -q suppresses, -v forces, else >1 files
    if not is_stdin and not quiet and (verbose or #args > 1) then
      io.write(string.format('==> %s <==\n', arg))
    end

    local stream = new_stream()

    while stream.open do
      push(stream, file:read('*L'))
    end

    if not is_stdin then file:close() end
  end
end

return error_code
