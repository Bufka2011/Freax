-- /init.lua — Freax 0.1 boot entry (M0, patched loader)
local component = component
local computer = computer

-- OC filesystem proxies use paths WITHOUT a leading slash.
local function fspath(p)
return (p:gsub("^/+", ""))
end

-- Resolve the boot filesystem.
local bootaddr = computer.getBootAddress()
if not bootaddr then
    for addr in component.list("filesystem") do
        bootaddr = addr
        break
        end
        end
        if not bootaddr then
            error("freax: no filesystem found")
            end

            local bootfs = component.proxy(bootaddr)

            -- Clear the screen for a clean handoff; the kernel and
            -- login draw everything from here (see dmesg if needed).
            do
                local gpuaddr = component.list("gpu", true)()
                if gpuaddr then
                    local ok, gpu = pcall(component.proxy, gpuaddr)
                    if ok and gpu then
                        local w, h = gpu.getResolution()
                        gpu.setResolution(w, h)
                        gpu.fill(1, 1, w, h, " ")
                            end
                            end
                            end

                            local function openRead(path)
    local ok, handle = pcall(bootfs.open, fspath(path), "r")
    return (ok and handle) or nil
end

-- Read the whole file. Kept for kernel fallbacks that need a string.
local function readAll(path)
    local h = openRead(path)
    if not h then return nil end
    local data = ""
    while true do
        local rok, chunk = pcall(bootfs.read, h, 4096)
        if not rok or not chunk then break end
        data = data .. chunk
    end
    pcall(bootfs.close, h)
    return data
end

local readFile = readAll

-- Compile a file by STREAMING it into load(): no full-source string and no
-- O(n^2) `data = data .. chunk` garbage. Loading the 77K kernel via
-- concatenation peaked near 1.4MB on host; streaming keeps boot peak close
-- to the chunk's own compile cost. This is the low-RAM boot fix.
local function loadStreaming(path, name)
    local h = openRead(path)
    if not h then return nil end
    local fn, err = load(function()
        local rok, chunk = pcall(bootfs.read, h, 4096)
        if not rok then return nil end
        return chunk
    end, "=" .. name, "t")
    pcall(bootfs.close, h)
    if not fn then return nil, err end
    return fn
end

local modules = {}
local function loadModule(name)
    if modules[name] then return modules[name] end
    local stem = name:gsub("%.", "/")
    local candidates = { "/boot/" .. stem .. ".lua", "/lib/" .. stem .. ".lua" }
    for _, path in ipairs(candidates) do
        local fn = loadStreaming(path, name)
        if fn then
            local result = fn()
            modules[name] = result
            return result
        end
    end
    error("freax: module not found: " .. name ..
        " (tried " .. table.concat(candidates, ", ") .. ")")
end

                                                    -- Hand off to the kernel.
                                                    local kernel = loadModule("kernel.main")
                                                    if type(kernel.init) == "function" then
                                                        local ok = pcall(kernel.init, {
                                                            bootfs = bootfs,
                                                            bootaddr = bootaddr,
                                                            loadModule = loadModule,
                                                            readFile = readFile,
                                                        })
                                                        if not ok then
                                                            -- fallback for old K.init(bootfs, readFile)
                                                            pcall(kernel.init, bootfs, readFile)
                                                        end
                                                        end
                                                        if type(kernel.start) == "function" then
                                                            kernel.start()
                                                        elseif type(kernel.loop) == "function" then
                                                            kernel.loop()
                                                        else
                                                            error("freax: kernel has neither start nor loop")
                                                        end
