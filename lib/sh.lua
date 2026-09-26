-- sh: Freax port of OpenOS lib/sh.lua (core) plus the complex-command
-- execution that OpenOS keeps in lib/core/full_sh.lua. Freax has no
-- process.load / pipe.buildPipeChain coroutine machinery, so command
-- execution is expressed with kernel primitives (freax.spawnIO, freax.pipe,
-- freax.wait) and io handles. Everything else mirrors OpenOS semantics.

local fs = require("fs")
local shell = require("shell")
local text = require("text")
local tx = require("transforms")

local sh = {}
sh.internal = {}

-- Builtins are registered by the shell front-end (bin/sh.lua). They run
-- in-process with io redirection instead of being spawned.
sh.internal.builtins = {}

-- tx.sub / tx.partition live in OpenOS lib/core/full_transforms.lua, which
-- Freax does not ship. Inline the pieces sh needs.
local adjust = tx.internal.range_adjust
local view = tx.internal.table_view

local function tsub(tbl, f, l)
  local r, s = {}, #tbl
  f, l = adjust(f, l, s)
  l = math.min(l, s)
  for i = math.max(f, 1), l do
    r[#r + 1] = tbl[i]
  end
  return r
end

local function partition(tbl, partitioner, dropEnds, f, l)
  if type(partitioner) == "table" then
    return partition(tbl, function(e, i, t)
      return tx.first(t, partitioner, i)
    end, dropEnds, f, l)
  end
  local s = #tbl
  f, l = adjust(f, l, s)
  local cut = view(tbl, f, l)
  local result = {}
  local need = true
  local exp = function()
    if need then
      result[#result + 1] = {}
      need = false
    end
  end
  local i = f
  while i <= l do
    local e = cut[i]
    local ds, de = partitioner(e, i, cut)
    if ds == true then
      ds, de = i, i
    elseif ds == false then
      ds, de = nil, nil
    end
    if ds ~= nil then
      ds, de = adjust(ds, de, l)
      ds = ds >= i and ds
    end
    if not ds then
      exp()
      table.insert(result[#result], e)
    else
      local sub = tsub(cut, i, not dropEnds and de or (ds - 1))
      if #sub > 0 then
        exp()
        result[#result + math.min(#result[#result], 1)] = sub
      end
      local ensured = math.max(math.max(de or ds, ds), i)
      if de and ds and de < ds and ensured == i then
        if #result == 0 then result[1] = {} end
        table.insert(result[#result], e)
      end
      i = ensured
      need = true
    end
    i = i + 1
  end
  return result
end

-------------------------------------------------------------------------------

function sh.internal.isWordOf(w, vs)
  return w and #w == 1 and not w[1].qr and tx.first(vs, {{w[1].txt}}) ~= nil
end

local isWordOf = sh.internal.isWordOf

-------------------------------------------------------------------------------

-- SH API

sh.internal.ec = {}
sh.internal.ec.parseCommand = 127
sh.internal.ec.last = 0

function sh.getLastExitCode()
  return sh.internal.ec.last
end

function sh.internal.command_result_as_code(ec, reason)
  -- convert lua result to bash ec
  local code
  if ec == false then
    code = 1
  elseif ec == nil or ec == true then
    code = 0
  elseif type(ec) ~= "number" then
    code = 2 -- illegal number
  else
    code = ec
  end

  if reason and code ~= 0 then io.stderr:write(reason, "\n") end
  return code
end

function sh.internal.tokenize(input, options)
  return text.internal.tokenize(input, options)
end

function sh.internal.resolveActions(input, resolved)
  resolved = resolved or {}

  local processed = {}

  local prev_was_delim = true
  local words, reason = sh.internal.tokenize(input)

  if not words then
    return nil, reason
  end

  while #words > 0 do
    local next = table.remove(words, 1)
    if isWordOf(next, {";", "&&", "||", "|"}) then
      prev_was_delim = true
      resolved = {}
    elseif prev_was_delim then
      prev_was_delim = false
      -- if current is actionable, resolve, else pop until delim
      if next and #next == 1 and not next[1].qr then
        local key = next[1].txt
        if key == "!" then
          prev_was_delim = true -- special redo
        elseif not resolved[key] then
          resolved[key] = shell.getAlias(key)
          local value = resolved[key]
          if value and key ~= value then
            local replacement_tokens, resolve_reason = sh.internal.resolveActions(value, resolved)
            if not replacement_tokens then
              return replacement_tokens, resolve_reason
            end
            words = tx.concat(replacement_tokens, words)
            next = table.remove(words, 1)
          end
        end
      end
    end

    table.insert(processed, next)
  end

  return processed
end

-- returns true if key is a string that represents a valid command line identifier
function sh.internal.isIdentifier(key)
  if type(key) ~= "string" then
    return false
  end

  return key:match("^[%a_][%w_]*$") == key
end

-- expand (interpret) a single quoted area
-- examples: $foo or "$foo"
function sh.expand(value)
  local expanded = value
  :gsub("%$([_%w%?]+)", function(key)
    if key == "?" then
      return tostring(sh.getLastExitCode())
    end
    return os.getenv(key) or ''
  end)
  :gsub("%${([^}]*)}", function(key)
    if sh.internal.isIdentifier(key) then
      return os.getenv(key) or ''
    end
    -- Never exit here: this runs inside the shell's own process, so os.exit
    -- would kill the interactive shell (it looked like a shell restart).
    io.stderr:write("${" .. key .. "}: bad substitution\n")
    return "${" .. key .. "}"
  end)
  return expanded
end

-------------------------------------------------------------------------------
-- command execution (Freax-native replacement for full_sh's thread machinery)

-- redirects as built by buildCommandRedirects. Freax spawns children with
-- explicit fds, so return a { [0]=in, [1]=out, [2]=err } fd map instead of
-- mutating a process io table. Opened handles are appended to `owned`.
function sh.internal.openCommandRedirects(redirects, defaults, owned)
  defaults = defaults or {}
  local fds = { [0] = defaults.in_, [1] = defaults.out, [2] = defaults.err }

  for _, rjob in ipairs(redirects or {}) do
    local from_io, to_io, mode = table.unpack(rjob)

    if type(to_io) == "number" then -- io to io
      fds[from_io] = fds[to_io]
    else
      local file, reason = io.open(shell.resolve(to_io), mode)
      if not file then
        return nil, "could not open '" .. to_io .. "': " .. tostring(reason)
      end
      owned[#owned + 1] = file
      fds[from_io] = file._fd
    end
  end

  return fds
end

local function closeOwned(owned)
  for _, h in ipairs(owned) do
    if h and h.close then h:close() end
  end
end

local function waitAll(pids)
  local code = 0
  for _, pid in ipairs(pids) do
    code = freax.wait(pid) or 0
  end
  return code
end

-- Run a registered builtin in-process. Redirects are applied to the
-- process io table (io.input/output/error) and restored afterwards.
-- Returns command_passed(...) plus an optional reason, like executePipes.
function sh.internal.runBuiltin(name, args, redirects)
  local builtin = sh.internal.builtins[name]
  if not builtin then return false, name .. ": not a builtin" end

  local oldIn, oldOut, oldErr = io.input(), io.output(), io.error()
  local owned = {}

  local function restore()
    io.input(oldIn)
    io.output(oldOut)
    io.error(oldErr)
    closeOwned(owned)
  end

  for _, rjob in ipairs(redirects or {}) do
    local from_io, to_io, mode = table.unpack(rjob)
    if type(to_io) == "number" then
      local target
      if to_io == 0 then target = io.input()
      elseif to_io == 1 then target = io.output()
      elseif to_io == 2 then target = io.error()
      end
      if from_io == 0 then io.input(target)
      elseif from_io == 1 then io.output(target)
      elseif from_io == 2 then io.error(target) end
    else
      local file, reason = io.open(shell.resolve(to_io), mode)
      if not file then
        restore()
        return false, "could not open '" .. to_io .. "': " .. tostring(reason)
      end
      owned[#owned + 1] = file
      if from_io == 0 then io.input(file)
      elseif from_io == 1 then io.output(file)
      elseif from_io == 2 then io.error(file) end
    end
  end

  local result = table.pack(pcall(builtin, table.unpack(args)))
  restore()
  if not result[1] then return false, tostring(result[2]) end
  return sh.internal.command_passed(result[2]), result[3]
end

function sh.internal.executePipes(pipe_parts, eargs, env)
  local stages = {}
  for _, words in ipairs(pipe_parts) do
    local args, redirects = sh.internal.evaluate(words)
    if not args then
      return false, redirects -- in this failure case, redirects holds the message
    end
    stages[#stages + 1] = { args = args, redirects = redirects }
  end

  if #stages == 0 then
    return true
  end

  -- extra args from sh.execute(...) go to the final command
  if eargs and (eargs.n or #eargs) > 0 then
    local last = stages[#stages].args
    for i = 1, (eargs.n or #eargs) do
      last[#last + 1] = eargs[i]
    end
  end

  local pids, owned = {}, {}
  local prev_r
  for i, st in ipairs(stages) do
    local name = table.remove(st.args, 1)
    if not name then
      closeOwned(owned)
      waitAll(pids)
      return false, "syntax error: empty command"
    end

    if sh.internal.builtins[name] then
      if #stages > 1 then
        closeOwned(owned)
        waitAll(pids)
        return false, name .. ": builtin in pipeline unsupported"
      end
      closeOwned(owned)
      waitAll(pids)
      return sh.internal.runBuiltin(name, st.args, st.redirects)
    end

    local path = shell.resolveCmd(name)
    if not path or not freax.fsExists(path) then
      closeOwned(owned)
      waitAll(pids)
      return false, name .. ": command not found"
    end

    local outFd, next_r
    if i < #stages then
      local rfd, wfd = freax.pipe()
      local rh, wh = freax.wrapFd(rfd), freax.wrapFd(wfd)
      if rh then owned[#owned + 1] = rh end
      if wh then owned[#owned + 1] = wh end
      outFd, next_r = wfd, rfd
    end

    local fds, reason = sh.internal.openCommandRedirects(st.redirects, {
      in_ = prev_r, out = outFd, err = nil,
    }, owned)
    if not fds then
      closeOwned(owned)
      waitAll(pids)
      return false, reason
    end

    local pid, err = freax.spawnIO(name, path, st.args, fds[0], fds[1], fds[2])
    if not pid then
      closeOwned(owned)
      waitAll(pids)
      return false, err
    end
    pids[#pids + 1] = pid
    prev_r = next_r
  end

  -- children hold their own dups; closing ours lets downstream readers EOF
  closeOwned(owned)
  return waitAll(pids)
end

-------------------------------------------------------------------------------
-- complex command handling (ported from OpenOS lib/core/full_sh.lua)

function sh.internal.command_passed(ec)
  return sh.internal.command_result_as_code(ec) == 0
end

-- takes ewords and searches for redirections (may not have any)
-- removes the redirects and their arguments from the ewords
-- returns a redirection table that is used during process load
-- returns false if no redirections are defined
function sh.internal.buildCommandRedirects(words)
  local redirects = {}
  local index = 1 -- we move index manually to allow removals from ewords
  local from_io, to_io, mode
  local syn_err_msg = "syntax error near unexpected token "

  -- hasValidPiping has been modified, it does not verify redirects now
  -- we could have bad redirects such as "echo hi > > foo"
  -- we must validate the input here

  while true do
    local word = words[index]
    if not word then break end

    -- redirections are
    -- 1. single part
    -- 2. not quoted
    local part = word[1]
    local token = not word[2] and not part.qr and part.txt or ""
    local _, _, from_io_txt, mode_txt, to_io_txt = token:find("(%d*)([<>]>?)%&?(.*)")
    if mode_txt then
      if mode then
        return nil, syn_err_msg .. token
      end
      mode = assert(({["<"] = "r", [">"] = "w", [">>"] = "a"})[mode_txt],
        "redirect failed to detect mode")
      from_io = from_io_txt ~= "" and tonumber(from_io_txt) or mode == "r" and 0 or 1
      to_io = to_io_txt ~= "" and tonumber(to_io_txt)
    elseif mode then
      token = sh.internal.evaluate({word})
      if #token > 1 then
        return nil, string.format("%s: ambiguous redirect", part.txt)
      end
      to_io = token[1]
    else
      index = index + 1
    end

    if mode then
      table.remove(words, index)
    end

    if to_io then
      table.insert(redirects, {from_io, to_io, mode})
      mode = nil
      to_io = nil
    end
  end

  if mode then
    return nil, syn_err_msg .. "newline"
  end

  return redirects
end

-- takes an eword, returns a list of glob hits or {word} if no globs exist
function sh.internal.glob(eword)
  -- words are parts, parts are txt and qr
  -- eword.txt is a convenience field of the parts
  local globbers = {{"*", ".*"}, {"?", "."}}
  local glob_pattern = ""
  local has_globits
  for _, part in ipairs(eword) do
    local next = part.txt
    -- globs only exist outside quotes
    if not part.qr then
      local escaped = text.escapeMagic(next)
      next = escaped

      for _, glob_rule in ipairs(globbers) do
        -- remove duplicates
        while true do
          local prev = next
          next = next:gsub(text.escapeMagic(glob_rule[1]):rep(2), glob_rule[1])
          if prev == next then
            break
          end
        end
        -- revert globit
        next = next:gsub("%%%" .. glob_rule[1], glob_rule[2])
      end

      has_globits = has_globits or next ~= escaped
    end
    glob_pattern = glob_pattern .. next
  end

  if not has_globits then
    return {eword.txt}
  end

  local segments = text.split(glob_pattern, {"/"}, true)
  local hiddens = {}
  for i, e in ipairs(segments) do hiddens[i] = e:match("^%%%.") == nil end
  local function is_visible(s, i)
    return not hiddens[i] or s:match("^%.") == nil
  end

  local function magical(s)
    for _, glob_rule in ipairs(globbers) do
      if (" " .. s):match("[^%%]" .. text.escapeMagic(glob_rule[2])) then
        return true
      end
    end
  end

  local is_abs = glob_pattern:sub(1, 1) == "/"
  local root = is_abs and '' or shell.getWorkingDirectory():gsub("([^/])$", "%1/")
  local paths = {is_abs and "/" or ''}
  local relative_separator = ''
  for i, segment in ipairs(segments) do
    local enclosed_pattern = string.format("^(%s)/?$", segment)
    local next_paths = {}
    for _, path in ipairs(paths) do
      if fs.isDirectory(root .. path) then
        if magical(segment) then
          for _, file in ipairs(fs.list(root .. path) or {}) do
            if file:match(enclosed_pattern) and is_visible(file, i) then
              table.insert(next_paths, path .. relative_separator .. file:gsub("/+$", ''))
            end
          end
        else -- not a globbing segment, just use it raw
          local plain = text.removeEscapes(segment)
          local fpath = root .. path .. relative_separator .. plain
          local hit = path .. relative_separator .. plain:gsub("/+$", '')
          if fs.exists(fpath) then
            table.insert(next_paths, hit)
          end
        end
      end
    end
    paths = next_paths
    if not next(paths) then
      -- if no next_paths were hit here, the ENTIRE glob value is not a path
      return {eword.txt}
    end
    relative_separator = "/"
  end
  return paths
end

-- verifies that no pipes are doubled up nor at the start nor end of words
function sh.internal.hasValidPiping(words, pipes)
  if #words == 0 then
    return true
  end

  local semi_split = tx.first(text.syntax, {{";"}})
  pipes = pipes or tsub(text.syntax, semi_split + 1)

  local state = "" -- cannot start on a pipe

  for w = 1, #words do
    local word = words[w]
    for p = 1, #word do
      local part = word[p]
      if part.qr then
        state = nil
      elseif part.txt == "" then
        state = nil
      elseif #text.split(part.txt, pipes, true) == 0 then
        local prev = state
        state = part.txt
        if prev then -- cannot have two pipes in a row
          word = nil
          break
        end
      else
        state = nil
      end
    end
    if not word then -- bad pipe
      break
    end
  end

  if state then
    return false, "syntax error near unexpected token " .. state
  else
    return true
  end
end

function sh.internal.boolean_executor(chains, predicator)
  local function not_gate(result, reason)
    return sh.internal.command_passed(result) and 1 or 0, reason
  end

  local last = true
  local last_reason
  local boolean_stage = 1
  local negation_stage = 2
  local command_stage = 0
  local stage = negation_stage
  local skip = false

  for ci = 1, #chains do
    local next = chains[ci]
    local single = #next == 1 and #next[1] == 1 and not next[1][1].qr and next[1][1].txt

    if single == "||" then
      if stage ~= command_stage or #chains == 0 then
        return nil, "syntax error near unexpected token '" .. single .. "'"
      end
      if sh.internal.command_passed(last) then
        skip = true
      end
      stage = boolean_stage
    elseif single == "&&" then
      if stage ~= command_stage or #chains == 0 then
        return nil, "syntax error near unexpected token '" .. single .. "'"
      end
      if not sh.internal.command_passed(last) then
        skip = true
      end
      stage = boolean_stage
    elseif not skip then
      local chomped = #next
      local negate = sh.internal.remove_negation(next)
      chomped = chomped ~= #next
      if negate then
        local prev = predicator
        predicator = function(n, i)
          local result, reason = not_gate(prev(n, i))
          predicator = prev
          return result, reason
        end
      end
      if chomped then
        stage = negation_stage
      end
      if #next > 0 then
        last, last_reason = predicator(next, ci)
        stage = command_stage
      end
    else
      skip = false
      stage = command_stage
    end
  end

  if stage == negation_stage then
    last = not_gate(last)
  end

  return last, last_reason
end

function sh.internal.splitStatements(words, semicolon)
  semicolon = semicolon or ";"

  return partition(words, function(g, i)
    if isWordOf(g, {semicolon}) then
      return i, i
    end
  end, true)
end

function sh.internal.splitChains(s, pc)
  pc = pc or "|"
  return partition(s, function(w)
    -- each word has multiple parts due to quotes
    if isWordOf(w, {pc}) then
      return true
    end
  end, true) -- drop |s
end

function sh.internal.groupChains(s)
  return partition(s, function(w) return isWordOf(w, {"&&", "||"}) end)
end

function sh.internal.remove_negation(chain)
  if isWordOf(chain[1], {"!"}) then
    table.remove(chain, 1)
    return not sh.internal.remove_negation(chain)
  end
  return false
end

function sh.internal.execute_complex(words, eargs, env)
  -- we shall validate pipes before any statement execution
  local statements = sh.internal.splitStatements(words)
  for i = 1, #statements do
    local ok, why = sh.internal.hasValidPiping(statements[i])
    if not ok then return nil, why end
  end

  for si = 1, #statements do
    local s = statements[si]
    local chains = sh.internal.groupChains(s)
    local last_code, reason = sh.internal.boolean_executor(chains, function(chain, chain_index)
      local pipe_parts = sh.internal.splitChains(chain)
      local next_args = chain_index == #chains and si == #statements and eargs or {}
      return sh.internal.executePipes(pipe_parts, next_args, env)
    end)
    sh.internal.ec.last = sh.internal.command_result_as_code(last_code, reason)
  end
  return sh.internal.ec.last == 0
end

-- params: words[tokenized word list]
-- return: command args, redirects
function sh.internal.evaluate(words)
  local redirects, why = sh.internal.buildCommandRedirects(words)
  if not redirects then
    return nil, why
  end

  do
    local normalized = text.internal.normalize(words)
    local command_text = table.concat(normalized, " ")
    local subbed = sh.internal.parse_sub(command_text)
    if subbed ~= command_text then
      words = text.internal.tokenize(subbed)
    end
  end

  local repack = false
  for _, word in ipairs(words) do
    for _, part in pairs(word) do
      if not (part.qr or {})[3] then
        local expanded = sh.expand(part.txt)
        if expanded ~= part.txt then
          part.txt = expanded
          repack = true
        end
      end
    end
  end

  if repack then
    local normalized = text.internal.normalize(words)
    local command_text = table.concat(normalized, " ")
    words = text.internal.tokenize(command_text)
  end

  local args = {}
  for _, word in ipairs(words) do
    local eword = { txt = "" }
    for _, part in ipairs(word) do
      eword.txt = eword.txt .. part.txt
      eword[#eword + 1] = { qr = part.qr, txt = part.txt }
    end
    for _, arg in ipairs(sh.internal.glob(eword)) do
      args[#args + 1] = arg
    end
  end

  return args, redirects
end

function sh.internal.parse_sub(input, quotes)
  -- unquoted command substituted text is parsed as individual parameters
  if quotes and quotes[1] == '`' then
    input = string.format("`%s`", input)
    quotes[1], quotes[2] = "", "" -- substitution removes the quotes
  end

  -- cannot use gsub here because it is a [C] call, and io.popen needs to yield
  local packed = {}
  local i, len = 1, #input

  while i <= len do
    local fi, si, capture = input:find("`([^`]*)`", i)

    if not fi then
      table.insert(packed, input:sub(i))
      break
    end
    table.insert(packed, input:sub(i, fi - 1))

    local sub, err = io.popen(capture)
    if not sub then error(tostring(err or "command substitution failed"), 2) end
    local result, rerr = sub:read("*a")
    sub:close()
    if not result then error(tostring(rerr or "command substitution read failed"), 2) end

    -- command substitution cuts trailing newlines
    table.insert(packed, (result:gsub("\n+$", "")))
    i = si + 1
  end

  return table.concat(packed)
end

-------------------------------------------------------------------------------

function sh.execute(env, command, ...)
  if type(command) ~= "string" then
    error("bad argument #2 (string expected)")
  end
  if command:find("^%s*#") then return true, 0 end

  local words, reason = sh.internal.resolveActions(command)
  if type(words) ~= "table" then
    return words, reason
  elseif #words == 0 then
    return true
  end

  -- MUST be table.pack for non contiguous ...
  local eargs = table.pack(...)

  -- simple
  if not command:find("[;%$&|!<>]") then
    sh.internal.ec.last = sh.internal.command_result_as_code(sh.internal.executePipes({words}, eargs, env))
    return sh.internal.ec.last == 0
  end

  return sh.internal.execute_complex(words, eargs, env)
end

return sh
