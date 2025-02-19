local EventEmitter = require "mason-core.EventEmitter"
local Optional = require "mason-core.optional"
local _ = require "mason-core.functional"
local fs = require "mason-core.fs"
local log = require "mason-core.log"
local path = require "mason-core.path"
local sources = require "mason-registry.sources"

---@class RegistrySource
---@field id string
---@field get_package fun(self: RegistrySource, pkg_name: string): Package?
---@field get_all_package_names fun(self: RegistrySource): string[]
---@field get_display_name fun(self: RegistrySource): string
---@field is_installed fun(self: RegistrySource): boolean
---@field get_installer fun(self: RegistrySource): Optional # Optional<async fun (): Result>

---@class MasonRegistry : EventEmitter
---@diagnostic disable-next-line: assign-type-mismatch
local M = setmetatable({}, { __index = EventEmitter })
EventEmitter.init(M)

local scan_install_root

do
    ---@type table<string, true>?
    local cached_dirs

    local get_directories = _.compose(
        _.set_of,
        _.filter_map(function(entry)
            if entry.type == "directory" then
                return Optional.of(entry.name)
            else
                return Optional.empty()
            end
        end)
    )

    ---@return table<string, true>
    scan_install_root = function()
        if cached_dirs then
            return cached_dirs
        end
        log.trace "Scanning installation root dir"
        local ok, entries = pcall(fs.sync.readdir, path.package_prefix())
        if not ok then
            log.debug("Failed to scan installation root dir", entries)
            -- presume installation root dir has not been created yet (i.e., no packages installed)
            return {}
        end
        cached_dirs = get_directories(entries)
        vim.schedule(function()
            cached_dirs = nil
        end)
        log.trace("Resolved installation root dirs", cached_dirs)
        return cached_dirs
    end
end

---Checks whether the provided package name is installed.
---In many situations, this is a more efficient option than the Package:is_installed() method due to a smaller amount of
---modules required to load.
---@param package_name string
function M.is_installed(package_name)
    return scan_install_root()[package_name] == true
end

---Returns an instance of the Package class if the provided package name exists. This function errors if a package cannot be found.
---@param package_name string
---@return Package
function M.get_package(package_name)
    for source in sources.iter() do
        local pkg = source:get_package(package_name)
        if pkg then
            return pkg
        end
    end
    log.fmt_error("Cannot find package %q.", package_name)
    error(("Cannot find package %q."):format(package_name))
end

---Returns true if the provided package_name can be found in the registry.
---@param package_name string
---@return boolean
function M.has_package(package_name)
    local ok = pcall(M.get_package, package_name)
    return ok
end

local get_packages = _.map(M.get_package)

---Returns all installed package names. This is a fast function that doesn't load any extra modules.
---@return string[]
function M.get_installed_package_names()
    return _.keys(scan_install_root())
end

---Returns all installed package instances. This is a slower function that loads more modules.
---@return Package[]
function M.get_installed_packages()
    return get_packages(M.get_installed_package_names())
end

---Returns all package names. This is a fast function that doesn't load any extra modules.
---@return string[]
function M.get_all_package_names()
    local pkgs = {}
    for source in sources.iter() do
        for _, name in ipairs(source:get_all_package_names()) do
            pkgs[name] = true
        end
    end
    return _.keys(pkgs)
end

---Returns all package instances. This is a slower function that loads more modules.
---@return Package[]
function M.get_all_packages()
    return get_packages(M.get_all_package_names())
end

local STATE_FILE = path.concat { vim.fn.stdpath "cache", "mason-registry-update" }

---@param time integer
local function get_store_age(time)
    local checksum = sources.checksum()
    if fs.sync.file_exists(STATE_FILE) then
        local parse_state_file =
            _.compose(_.evolve { timestamp = tonumber }, _.zip_table { "checksum", "timestamp" }, _.split "\n")
        local state = parse_state_file(fs.sync.read_file(STATE_FILE))
        if checksum == state.checksum then
            return math.abs(time - state.timestamp)
        end
    end
    return time
end

---@async
---@param time integer
local function update_store_timestamp(time)
    fs.async.write_file(STATE_FILE, _.join("\n", { sources.checksum(), tostring(time) }))
end

---@param callback? fun(success: boolean, updated_registries: RegistrySource[])
function M.update(callback)
    local a = require "mason-core.async"
    local Result = require "mason-core.result"
    return a.run(function()
        return Result.try(function(try)
            local updated_sources = {}
            for source in sources.iter { include_uninstalled = true } do
                source:get_installer():if_present(function(installer)
                    try(installer():map_err(function(err)
                        return ("%s failed to install: %s"):format(source, err)
                    end))
                    table.insert(updated_sources, source)
                end)
            end
            return updated_sources
        end):on_success(function(updated_sources)
            if #updated_sources > 0 then
                M:emit("update", updated_sources)
            end
        end)
    end, function(success, result)
        if not callback then
            return
        end
        if not success then
            return callback(false, result)
        end
        result
            :on_success(function(value)
                callback(true, value)
            end)
            :on_failure(function(err)
                callback(false, err)
            end)
    end)
end

local REGISTRY_STORE_TTL = 86400 -- 24 hrs

---@param cb? fun()
function M.refresh(cb)
    local a = require "mason-core.async"

    ---@async
    local function refresh()
        if vim.in_fast_event() then
            a.scheduler()
        end
        local is_outdated = get_store_age(os.time()) > REGISTRY_STORE_TTL
        if is_outdated or not sources.is_installed() then
            if a.wait(M.update) then
                if vim.in_fast_event() then
                    a.scheduler()
                end
                update_store_timestamp(os.time())
            end
        end
    end

    if not cb then
        a.run_blocking(refresh)
    else
        a.run(refresh, cb)
    end
end

return M
