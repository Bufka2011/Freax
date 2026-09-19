-- mksums: regenerate SHA256SUMS from manifest (dev tool, run on the host).
--
--   luajit mksums.lua
--
-- SHA256SUMS lets `apt sysupgrade` download only files whose content
-- actually changed. Run this after editing any shipped file and commit
-- SHA256SUMS together with the change, or the updater will fall back to a
-- full download (it detects a stale checksum file via /VERSION).
--
-- Dev-only: listed in the manifest for demo protection, never installed.

local sha256 = dofile("lib/sha256.lua")

local function readFile(path)
  local f = assert(io.open(path, "rb"))
  local data = f:read("*a")
  f:close()
  return data
end

local mf = assert(io.open("manifest", "r"))
local manifest = mf:read("*a")
mf:close()

local out = {}
for line in (manifest .. "\n"):gmatch("(.-)\n") do
  line = line:match("^%s*(.-)%s*$")
  if line ~= "" and line:sub(1, 1) ~= "#" and line ~= "SHA256SUMS" then
    local ok, data = pcall(readFile, line)
    if not ok then
      io.stderr:write("mksums: cannot read " .. line .. "\n")
      os.exit(1)
    end
    out[#out + 1] = sha256.digest(data) .. "  " .. line
  end
end

local of = assert(io.open("SHA256SUMS", "w"))
of:write(table.concat(out, "\n") .. "\n")
of:close()
io.write("mksums: wrote SHA256SUMS (" .. #out .. " files)\n")