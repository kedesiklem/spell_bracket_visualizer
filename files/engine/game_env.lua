-- A sandbox holding the game's own cast code, loaded but not yet driven.
--
-- Credit: evaluating a wand by running the game's own cast code in a sandbox is
-- the approach of kaliuresis' WandDBG (https://github.com/kaliuresis/WandDBG).
--
-- WHY A SANDBOX
--   gun.lua and gun_actions.lua are written as plain scripts over global state
--   (`deck`, `hand`, `discarded`, `c`, `mana`, ...) and call the live engine API
--   (`EntityLoad`, `GameGetFrameNum`, ...).  Run against the real globals they
--   would overwrite other mods' state and spawn real entities in the player's
--   game.  The cast code runs unmodified; it just must not see, or touch,
--   anything real.
--
-- HOW, WITHOUT load() -- THE GLOBAL TABLE IS SWAPPED
--   Noita's Lua exposes neither `loadstring` nor `load`, so there is no way to
--   compile a game file into a private environment.  What it does offer is
--   `dofile`, which always runs a file with the global table as its environment.
--   So the sandbox is the global table itself, SWAPPED for the duration of a call:
--
--     activate    stash every real global, empty _G, fill it with the sandbox's
--                 own contents (a whitelist of pure functions, the engine
--                 stand-ins, and whatever gun.lua defined)
--     ... run ... the cast code sees only the sandbox through `_G`
--     deactivate  keep what the sandbox now holds, restore every real global
--
--   Everything that executes cast code goes through `game.run(fn, ...)`, which
--   guarantees the real globals come back even when `fn` raises.  Code running
--   inside `run` -- including this mod's own tracer and runner -- sees the
--   sandbox as its globals, so it may only use names the sandbox provides (the
--   whitelist below); anything else must be captured in a local beforehand.
--
-- WHERE THE SOURCE COMES FROM
--   The host's `dofile` loads the files.  In Noita that is the real `dofile`,
--   which reads the game's virtual file system -- so spells other mods append
--   to gun_actions.lua with ModLuaFileAppend are included, provided this runs
--   after those mods have finished initialising.  The offline tools pass a
--   `dofile` that reads files extracted from data.wak (tools/test_support.lua).
--
-- Public API
--   M.new(host_dofile, world) -> game   (or nil, error_message)
--     host_dofile(path)  runs a game file with the CURRENT global table as its
--                        environment, like Noita's `dofile`
--     world              optional game-state overrides (engine_stubs.lua)
--     game.env     the global table; its contents are the sandbox only while
--                  inside game.run
--     game.report  the engine_stubs report (unknown calls, world reads, randomness)
--     game.run(fn, ...) -> fn's results   runs fn with the sandbox active
--   M.game_dofile()    -> the real `dofile`, for use as `host_dofile` in the game

local MOD = "mods/spell_bracket_visualizer/files/engine/"
local compat = dofile_once(MOD .. "lua_compat.lua")
local stubs = dofile_once(MOD .. "engine_stubs.lua")

local M = {}

-- Everything this file does after the first swap must use locals, never globals.
local pairs, ipairs, rawset, rawget = pairs, ipairs, rawset, rawget
local setmetatable, getmetatable = setmetatable, getmetatable
local pcall, error, type, tostring, assert = pcall, error, type, tostring, assert
local real_dofile = dofile
local real_string, real_table, real_math = string, table, math
local real_globals = _G
local unpack = compat.unpack

-- Plain Lua functions the game's cast code is allowed to use.
local PURE_FUNCTIONS = {
	"assert", "error", "ipairs", "next", "pairs", "pcall", "select",
	"tonumber", "tostring", "type", "xpcall", "rawget", "rawset", "rawequal",
	"setmetatable", "getmetatable", "print", "unpack",
}

local function copy_table(source)
	local out = {}
	for k, v in pairs(source) do out[k] = v end
	return out
end

--- The swap itself.  `state` is the sandbox's own contents between calls.
local function new_swap()
	local state, meta = {}, nil
	local saved, saved_meta
	local active = false
	local swap = {}

	local function clear()
		local keys = {}
		for k in pairs(real_globals) do keys[#keys + 1] = k end
		for _, k in ipairs(keys) do rawset(real_globals, k, nil) end
	end

	function swap.set_metatable(m) meta = m end

	function swap.run(fn, ...)
		assert(not active, "the sandbox is already active")
		active = true
		saved, saved_meta = copy_table(real_globals), getmetatable(real_globals)
		clear()
		for k, v in pairs(state) do rawset(real_globals, k, v) end
		setmetatable(real_globals, meta)

		local results = { pcall(fn, ...) }

		state = copy_table(real_globals)   -- what the sandbox holds now
		clear()
		for k, v in pairs(saved) do rawset(real_globals, k, v) end
		setmetatable(real_globals, saved_meta)
		saved = nil
		active = false

		if not results[1] then error(results[2], 0) end
		return unpack(results, 2)
	end
	return swap
end

function M.new(host_dofile, world)
	local pure = {}
	for _, name in ipairs(PURE_FUNCTIONS) do pure[name] = real_globals[name] end
	pure.unpack = pure.unpack or compat.unpack

	local swap = new_swap()
	local game = { env = real_globals, run = swap.run }

	local loaded = {}
	local function sandbox_dofile(path) return host_dofile(path) end
	local function sandbox_dofile_once(path)
		if loaded[path] == nil then loaded[path] = { host_dofile(path) } end
		return loaded[path][1]
	end

	local ok, err = pcall(swap.run, function()
		for name, fn in pairs(pure) do rawset(real_globals, name, fn) end
		rawset(real_globals, "string", real_string)
		rawset(real_globals, "table", copy_table(real_table))
		rawset(real_globals, "math", copy_table(real_math))
		rawset(real_globals, "_G", real_globals)
		rawset(real_globals, "dofile", sandbox_dofile)
		rawset(real_globals, "dofile_once", sandbox_dofile_once)
		game.report = stubs.install(real_globals, world)
		-- Any capitalised name the sandbox does not define is an engine call we do
		-- not model: counted, and answered with a no-op (engine_stubs.lua).
		local handler = { __index = stubs.unknown_call_handler(real_globals, game.report) }
		swap.set_metatable(handler)
		setmetatable(real_globals, handler)

		-- gun.lua pulls in gun_actions.lua itself (its last lines), so one call
		-- loads the whole cast machinery plus every spell, vanilla and modded.
		sandbox_dofile("data/scripts/gun/gun.lua")
		if type(rawget(real_globals, "actions")) ~= "table"
			or #rawget(real_globals, "actions") == 0 then
			error("gun_actions.lua did not define any spells", 0)
		end
	end)
	if not ok then return nil, tostring(err) end
	return game
end

--- The real `dofile`, for use inside Noita.
function M.game_dofile()
	return real_dofile
end

return M
