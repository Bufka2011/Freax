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

                            local function readAll(path)
                            -- Try exact path first, then flat fallback (M0 dev layout:
                            -- all files in /). e.g. /lib/term.lua -> term.lua,
                            -- /boot/kernel/main.lua -> main.lua
                            local tries = { path }
                            local base = path:match("([^/]+)$")
                            if base then
                                local flat1 = "/" .. base
                                local flat2 = base
                                if flat1 ~= path then tries[#tries + 1] = flat1 end
                                if flat2 ~= path then tries[#tries + 1] = flat2 end
                            end
                            for _, p in ipairs(tries) do
                                -- NOTE: OC proxies use dot-calls: fs.open(path),
                                -- NOT fs:open(). So no self arg in pcall.
                                local ok, handle = pcall(bootfs.open, fspath(p), "r")
                                local h = ok and handle or nil
                                if h then
                                    local data = ""
                                    while true do
                                        local rok, chunk = pcall(bootfs.read, h, 4096)
                                        if not rok or not chunk then break end
                                        data = data .. chunk
                                    end
                                    pcall(bootfs.close, h)
                                    return data
                                end
                            end
                            return nil
                            end

                                    local function readFile(path)
                                        return readAll(path)
                                    end

                                    local modules = {}
                                    local function loadModule(name)
                                    if modules[name] then return modules[name] end
                                        local stem = name:gsub("%.", "/")
                                        local last = name:match("[^.]+$")
                                        local candidates = {
                                            "/boot/" .. stem .. ".lua",
                                            "/lib/"  .. stem .. ".lua",
                                            "/" .. stem .. ".lua",
                                            stem .. ".lua",
                                            "/" .. last .. ".lua",
                                            last .. ".lua",
                                        }
                                        for _, path in ipairs(candidates) do
                                            local data = readAll(path)
                                            if data then
                                                local fn, err = load(data, "=" .. name, "t")
                                                if not fn then error("freax: load error in " .. name .. ": " .. tostring(err)) end
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
