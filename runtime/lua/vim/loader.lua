local fs = vim.fs -- "vim.fs" is a dependency, so must be loaded early.
local uv = vim.uv
local uri_encode = vim.uri_encode --- @type function

--- @type (fun(modename: string): fun()|string)[]
local loaders = package.loaders

local M = {}

---@alias CacheHash {mtime: {nsec: integer, sec: integer}, size: integer, type?: string}
---@alias CacheEntry {hash:CacheHash, chunk:string}

--- @class vim.loader.find.Opts
--- @inlinedoc
---
--- Search for modname in the runtime path.
--- (default: `true`)
--- @field rtp? boolean
---
--- Extra paths to search for modname
--- (default: `{}`)
--- @field paths? string[]
---
--- List of patterns to use when searching for modules.
--- A pattern is a string added to the basename of the Lua module being searched.
--- (default: `{"/init.lua", ".lua"}`)
--- @field patterns? string[]
---
--- Search for all matches.
--- (default: `false`)
--- @field all? boolean

--- @class vim.loader.ModuleInfo
--- @inlinedoc
---
--- Path of the module
--- @field modpath string
---
--- Name of the module
--- @field modname string
---
--- The fs_stat of the module path. Won't be returned for `modname="*"`
--- @field stat? uv.uv_fs_t

---@alias LoaderStats table<string, {total:number, time:number, [string]:number?}?>

---@nodoc
M.path = vim.fn.stdpath('cache') .. '/luac'

---@nodoc
M.enabled = false

---@class (private) Loader
---@field private _rtp string[]
---@field private _rtp_pure string[]
---@field private _rtp_key string
---@field private _hashes? table<string, CacheHash>
local Loader = {
  VERSION = 4,
  ---@type table<string, table<string,vim.loader.ModuleInfo>>
  _indexed = {},
  _loadfile = loadfile,
  ---@type LoaderStats
  _stats = {
    find = { total = 0, time = 0, not_found = 0 },
  },
}

--- @param path string
--- @return CacheHash
--- @private
function Loader.get_hash(path)
  if not Loader._hashes then
    return uv.fs_stat(path) --[[@as CacheHash]]
  end

  if not Loader._hashes[path] then
    -- Note we must never save a stat for a non-existent path.
    -- For non-existent paths fs_stat() will return nil.
    Loader._hashes[path] = uv.fs_stat(path)
  end
  return Loader._hashes[path]
end

local function normalize(path)
  return fs.normalize(path, { expand_env = false, _fast = true })
end

--- Gets the rtp excluding after directories.
--- The result is cached, and will be updated if the runtime path changes.
--- When called from a fast event, the cached value will be returned.
--- @return string[] rtp, boolean updated
---@private
function Loader.get_rtp()
  if vim.in_fast_event() then
    return (Loader._rtp or {}), false
  end
  local updated = false
  local key = vim.go.rtp
  if key ~= Loader._rtp_key then
    Loader._rtp = {}
    for _, path in ipairs(vim.api.nvim_get_runtime_file('', true)) do
      path = normalize(path)
      -- skip after directories
      if
        path:sub(-6, -1) ~= '/after'
        and not (Loader._indexed[path] and vim.tbl_isempty(Loader._indexed[path]))
      then
        Loader._rtp[#Loader._rtp + 1] = path
      end
    end
    updated = true
    Loader._rtp_key = key
  end
  return Loader._rtp, updated
end

--- Returns the cache file name
---@param name string can be a module name, or a file name
---@return string file_name
---@private
function Loader.cache_file(name)
  local ret = ('%s/%s'):format(M.path, uri_encode(name, 'rfc2396'))
  return ret:sub(-4) == '.lua' and (ret .. 'c') or (ret .. '.luac')
end

--- Saves the cache entry for a given module or file
---@param cname string cache filename
---@param hash CacheHash
---@param chunk function
---@private
function Loader.write(cname, hash, chunk)
  local f = assert(uv.fs_open(cname, 'w', 438))
  local header = {
    Loader.VERSION,
    hash.size,
    hash.mtime.sec,
    hash.mtime.nsec,
  }
  uv.fs_write(f, table.concat(header, ',') .. '\0')
  uv.fs_write(f, string.dump(chunk))
  uv.fs_close(f)
end

--- @param path string
--- @param mode integer
--- @return string? data
local function readfile(path, mode)
  local f = uv.fs_open(path, 'r', mode)
  if f then
    local hash = assert(uv.fs_fstat(f))
    local data = uv.fs_read(f, hash.size, 0) --[[@as string?]]
    uv.fs_close(f)
    return data
  end
end

--- Loads the cache entry for a given module or file
---@param cname string cache filename
---@return CacheHash? hash
---@return string? chunk
---@private
function Loader.read(cname)
  local data = readfile(cname, 438)
  if not data then
    return
  end

  local zero = data:find('\0', 1, true)
  if not zero then
    return
  end

  ---@type integer[]|{[0]:integer}
  local header = vim.split(data:sub(1, zero - 1), ',')
  if tonumber(header[1]) ~= Loader.VERSION then
    return
  end

  local hash = {
    size = tonumber(header[2]),
    mtime = { sec = tonumber(header[3]), nsec = tonumber(header[4]) },
  }

  local chunk = data:sub(zero + 1)

  return hash, chunk
end

--- The `package.loaders` loader for Lua files using the cache.
---@param modname string module name
---@return string|function
---@private
function Loader.loader(modname)
  Loader._hashes = {}
  local ret = M.find(modname)[1]
  if ret then
    -- Make sure to call the global loadfile so we respect any augmentations done elsewhere.
    -- E.g. profiling
    local chunk, err = loadfile(ret.modpath)
    Loader._hashes = nil
    return chunk or error(err)
  end
  Loader._hashes = nil
  return ("\n\tcache_loader: module '%s' not found"):format(modname)
end

local is_win = vim.fn.has('win32') == 1

--- The `package.loaders` loader for libs
---@param modname string module name
---@return string|function
---@private
function Loader.loader_lib(modname)
  local ret = M.find(modname, { patterns = { is_win and '.dll' or '.so' } })[1]
  if not ret then
    return ("\n\tcache_loader_lib: module '%s' not found"):format(modname)
  end

  -- Making function name in Lua 5.1 (see src/loadlib.c:mkfuncname) is
  -- a) strip prefix up to and including the first dash, if any
  -- b) replace all dots by underscores
  -- c) prepend "luaopen_"
  -- So "foo-bar.baz" should result in "luaopen_bar_baz"
  local dash = modname:find('-', 1, true)
  local funcname = dash and modname:sub(dash + 1) or modname
  local chunk, err = package.loadlib(ret.modpath, 'luaopen_' .. funcname:gsub('%.', '_'))
  return chunk or error(err)
end

--- `loadfile` using the cache
--- Note this has the mode and env arguments which is supported by LuaJIT and is 5.1 compatible.
---@param filename? string
---@param mode? "b"|"t"|"bt"
---@param env? table
---@return function?, string?  error_message
---@private
function Loader.loadfile(filename, mode, env)
  local modpath = normalize(filename)
  local hash = Loader.get_hash(modpath)
  local cname = Loader.cache_file(modpath)
  if hash then
    local e_hash, e_chunk = Loader.read(cname)
    if Loader.eq(e_hash, hash) and e_chunk then
      -- found in cache and up to date
      local chunk, err = load(e_chunk, '@' .. modpath, mode, env)
      if not (err and err:find('cannot load incompatible bytecode', 1, true)) then
        return chunk, err
      end
    end
  end

  local chunk, err = Loader._loadfile(modpath, mode, env)
  if chunk then
    Loader.write(cname, hash, chunk)
  end
  return chunk, err
end

--- Checks whether two cache hashes are the same based on:
--- * file size
--- * mtime in seconds
--- * mtime in nanoseconds
---@param a? CacheHash
---@param b? CacheHash
---@private
function Loader.eq(a, b)
  return a
    and b
    and a.size == b.size
    and a.mtime.sec == b.mtime.sec
    and a.mtime.nsec == b.mtime.nsec
end

--- Finds Lua modules for the given module name.
---
--- @since 0
---
---@param modname string Module name, or `"*"` to find the top-level modules instead
---@param opts? vim.loader.find.Opts Options for finding a module:
---@return vim.loader.ModuleInfo[]
function M.find(modname, opts)
  opts = opts or {}

  modname = modname:gsub('/', '.')
  local basename = modname:gsub('%.', '/')
  local idx = modname:find('.', 1, true)

  -- HACK: fix incorrect require statements. Really not a fan of keeping this,
  -- but apparently the regular Lua loader also allows this
  if idx == 1 then
    modname = modname:gsub('^%.+', '')
    basename = modname:gsub('%.', '/')
    idx = modname:find('.', 1, true)
  end

  -- get the top-level module name
  local topmod = idx and modname:sub(1, idx - 1) or modname

  -- OPTIM: search for a directory first when topmod == modname
  local patterns = opts.patterns
    or (topmod == modname and { '/init.lua', '.lua' } or { '.lua', '/init.lua' })
  for p, pattern in ipairs(patterns) do
    patterns[p] = '/lua/' .. basename .. pattern
  end

  ---@type vim.loader.ModuleInfo[]
  local results = {}

  -- Only continue if we haven't found anything yet or we want to find all
  local function continue()
    return #results == 0 or opts.all
  end

  -- Checks if the given paths contain the top-level module.
  -- If so, it tries to find the module path for the given module name.
  ---@param paths string[]
  local function _find(paths)
    for _, path in ipairs(paths) do
      if topmod == '*' then
        for _, r in pairs(Loader.lsmod(path)) do
          results[#results + 1] = r
          if not continue() then
            return
          end
        end
      elseif Loader.lsmod(path)[topmod] then
        for _, pattern in ipairs(patterns) do
          local modpath = path .. pattern
          Loader._stats.find.stat = (Loader._stats.find.stat or 0) + 1
          local hash = Loader.get_hash(modpath)
          if hash then
            results[#results + 1] = { modpath = modpath, stat = hash, modname = modname }
            if not continue() then
              return
            end
          end
        end
      end
    end
  end

  -- always check the rtp first
  if opts.rtp ~= false then
    _find(Loader._rtp or {})
    if continue() then
      local rtp, updated = Loader.get_rtp()
      if updated then
        _find(rtp)
      end
    end
  end

  -- check any additional paths
  if continue() and opts.paths then
    _find(opts.paths)
  end

  if #results == 0 then
    -- module not found
    Loader._stats.find.not_found = Loader._stats.find.not_found + 1
  end

  return results
end

--- Resets the cache for the path, or all the paths if path is nil.
---
--- @since 0
---
---@param path string? path to reset
function M.reset(path)
  if path then
    Loader._indexed[normalize(path)] = nil
  else
    Loader._indexed = {}
  end

  -- Path could be a directory so just clear all the hashes.
  if Loader._hashes then
    Loader._hashes = {}
  end
end

--- Enables the experimental Lua module loader:
--- * overrides loadfile
--- * adds the Lua loader using the byte-compilation cache
--- * adds the libs loader
--- * removes the default Nvim loader
---
--- @since 0
function M.enable()
  if M.enabled then
    return
  end
  M.enabled = true
  vim.fn.mkdir(vim.fn.fnamemodify(M.path, ':p'), 'p')
  _G.loadfile = Loader.loadfile
  -- add Lua loader
  table.insert(loaders, 2, Loader.loader)
  -- add libs loader
  table.insert(loaders, 3, Loader.loader_lib)
  -- remove Nvim loader
  for l, loader in ipairs(loaders) do
    if loader == vim._load_package then
      table.remove(loaders, l)
      break
    end
  end
end

--- Disables the experimental Lua module loader:
--- * removes the loaders
--- * adds the default Nvim loader
---
--- @since 0
function M.disable()
  if not M.enabled then
    return
  end
  M.enabled = false
  _G.loadfile = Loader._loadfile
  for l, loader in ipairs(loaders) do
    if loader == Loader.loader or loader == Loader.loader_lib then
      table.remove(loaders, l)
    end
  end
  table.insert(loaders, 2, vim._load_package)
end

--- Return the top-level \`/lua/*` modules for this path
---@param path string path to check for top-level Lua modules
---@private
function Loader.lsmod(path)
  if not Loader._indexed[path] then
    Loader._indexed[path] = {}
    for name, t in fs.dir(path .. '/lua') do
      local modpath = path .. '/lua/' .. name
      -- HACK: type is not always returned due to a bug in luv
      t = t or Loader.get_hash(modpath).type
      ---@type string
      local topname
      local ext = name:sub(-4)
      if ext == '.lua' or ext == '.dll' then
        topname = name:sub(1, -5)
      elseif name:sub(-3) == '.so' then
        topname = name:sub(1, -4)
      elseif t == 'link' or t == 'directory' then
        topname = name
      end
      if topname then
        Loader._indexed[path][topname] = { modpath = modpath, modname = topname }
      end
    end
  end
  return Loader._indexed[path]
end

--- Tracks the time spent in a function
--- @generic F: function
--- @param f F
--- @return F
--- @private
function Loader.track(stat, f)
  return function(...)
    local start = vim.uv.hrtime()
    local r = { f(...) }
    Loader._stats[stat] = Loader._stats[stat] or { total = 0, time = 0 }
    Loader._stats[stat].total = Loader._stats[stat].total + 1
    Loader._stats[stat].time = Loader._stats[stat].time + uv.hrtime() - start
    return unpack(r, 1, table.maxn(r))
  end
end

---@class (private) vim.loader._profile.Opts
---@field loaders? boolean Add profiling to the loaders

--- Debug function that wraps all loaders and tracks stats
---@private
---@param opts vim.loader._profile.Opts?
function M._profile(opts)
  Loader.get_rtp = Loader.track('get_rtp', Loader.get_rtp)
  Loader.read = Loader.track('read', Loader.read)
  Loader.loader = Loader.track('loader', Loader.loader)
  Loader.loader_lib = Loader.track('loader_lib', Loader.loader_lib)
  Loader.loadfile = Loader.track('loadfile', Loader.loadfile)
  M.find = Loader.track('find', M.find)
  Loader.lsmod = Loader.track('lsmod', Loader.lsmod)

  if opts and opts.loaders then
    for l, loader in pairs(loaders) do
      local loc = debug.getinfo(loader, 'Sn').source:sub(2)
      loaders[l] = Loader.track('loader ' .. l .. ': ' .. loc, loader)
    end
  end
end

--- Prints all cache stats
---@param opts? {print?:boolean}
---@return LoaderStats
---@private
function M._inspect(opts)
  if opts and opts.print then
    local function ms(nsec)
      return math.floor(nsec / 1e6 * 1000 + 0.5) / 1000 .. 'ms'
    end
    local chunks = {} ---@type string[][]
    ---@type string[]
    local stats = vim.tbl_keys(Loader._stats)
    table.sort(stats)
    for _, stat in ipairs(stats) do
      vim.list_extend(chunks, {
        { '\n' .. stat .. '\n', 'Title' },
        { '* total:    ' },
        { tostring(Loader._stats[stat].total) .. '\n', 'Number' },
        { '* time:     ' },
        { ms(Loader._stats[stat].time) .. '\n', 'Bold' },
        { '* avg time: ' },
        { ms(Loader._stats[stat].time / Loader._stats[stat].total) .. '\n', 'Bold' },
      })
      for k, v in pairs(Loader._stats[stat]) do
        if not vim.list_contains({ 'time', 'total' }, k) then
          chunks[#chunks + 1] = { '* ' .. k .. ':' .. string.rep(' ', 9 - #k) }
          chunks[#chunks + 1] = { tostring(v) .. '\n', 'Number' }
        end
      end
    end
    vim.api.nvim_echo(chunks, true, {})
  end
  return Loader._stats
end

return M
