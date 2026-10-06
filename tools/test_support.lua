-- Shared plumbing for the offline test tools.
--
-- The mod's files load each other with the game's `dofile_once` and absolute
-- `mods/spell_bracket_visualizer/...` paths.  Outside the game those paths mean
-- nothing, so every test starts by installing the loader below.  It also knows
-- where the game's own Lua lives (.gun_ref/, written by tools/extract_gun.py) so the engine can be built without Noita.
--
-- Usage, at the top of a test script:
--     local here = arg[0]:match("^(.*)[/\\]") or "."
--     local support = dofile(here .. "/test_support.lua")
--     support.install_mod_loader()
--     local engine = support.new_engine()

local here = (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]")) or "."
local MOD_ROOT = here .. "/.."
local MOD_PREFIX = "mods/spell_bracket_visualizer/"

local M = { MOD_ROOT = MOD_ROOT }

local function read_file(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local text = fh:read("*a")
	fh:close()
	return text
end

--- Make `dofile_once("mods/spell_bracket_visualizer/<rel>")` load <rel> from
-- this checkout, with the same once-only caching the game gives.
function M.install_mod_loader()
	local cache = {}
	function dofile_once(path)
		local rel = path:match("^" .. MOD_PREFIX:gsub("%p", "%%%0") .. "(.*)$")
		assert(rel, "unexpected dofile_once path: " .. tostring(path))
		if cache[path] == nil then cache[path] = { dofile(MOD_ROOT .. "/" .. rel) } end
		return cache[path][1]
	end
end

--- `read_source` backed by .gun_ref/, mirroring the game's data/ layout.
function M.gun_ref_reader()
	return function(path) return read_file(MOD_ROOT .. "/.gun_ref/" .. path) end
end

--- True when the game's cast code has been extracted locally.
function M.has_gun_ref()
	return read_file(MOD_ROOT .. "/.gun_ref/data/scripts/gun/gun.lua") ~= nil
end

--- Build the engine from .gun_ref/, or stop with instructions.
function M.new_engine(world)
	if not M.has_gun_ref() then
		error("\n.gun_ref/ is missing -- the engine needs the game's own cast code.\n"
			.. "Run:  python3 tools/extract_gun.py            (reads your data.wak)\n", 0)
	end
	local engine_module = dofile_once(MOD_PREFIX .. "files/engine/engine.lua")
	local engine, err = engine_module.new(M.gun_ref_reader(), world)
	if not engine then error("engine failed to start: " .. tostring(err), 0) end
	return engine
end

return M
