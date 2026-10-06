-- A sandbox holding the game's own cast code, loaded but not yet driven.
--
-- Credit: evaluating a wand by running the game's own cast code in a sandbox is
-- the approach of kaliuresis' WandDBG (https://github.com/kaliuresis/WandDBG),
-- which runs gun.lua in the mod's global state and swaps the engine functions
-- it needs.  This file does the same, made systematic.
--
-- WHY A SANDBOX
--   gun.lua and gun_actions.lua are written as plain scripts over global state
--   (`deck`, `hand`, `discarded`, `c`, `mana`, ...) and call the live engine API
--   (`EntityLoad`, `GameGetFrameNum`, ...).  Run against the real globals they
--   would overwrite other mods' state and spawn real entities in the player's
--   game.  The cast code runs unmodified; it just must not touch anything real.
--
-- HOW: THE GLOBAL TABLE IS OVERLAID FOR THE DURATION OF A CALL
--   Noita's Lua has no `load` / `loadstring`, and its own `dofile` leans on
--   internal globals, so the cast code cannot be compiled into a private
--   environment.  It has to run in the global table, as WandDBG does.  So for
--   the duration of each call the global table is OVERLAID, then put back:
--
--     activate    remember every real global; replace each CamelCase C function
--                 (the engine API: EntityLoad, GamePrint, ...) with a counting
--                 no-op; apply the sandbox's own contents (the engine stand-ins
--                 and everything gun.lua defined)
--     ... run ... the cast code can call nothing real, and its globals are its own
--     deactivate  keep whatever the sandbox changed or added, then restore the
--                 real globals exactly
--
--   Lowercase names (Lua's own functions, Noita's `dofile` and its internals)
--   are left alone: they are what lets files load.  Everything that executes
--   cast code goes through `game.run(fn, ...)`, which guarantees the real
--   globals come back even when `fn` raises.
--
-- WHERE THE SOURCE COMES FROM
--   gun.lua loads its own files with the game's `dofile`, which reads the game's
--   virtual file system -- so spells other mods append to gun_actions.lua with
--   ModLuaFileAppend are included, provided this runs after those mods have
--   finished initialising.  The offline tools have no such file system, so they
--   pass a `host.dofile` of their own that reads files extracted from data.wak
--   (tools/test_support.lua).
--
-- Public API
--   M.new(host, world) -> game   (or nil, error_message)
--     host   nil in the game; offline: { dofile = function(path) ... end }, which
--            runs a game file with the CURRENT global table as its environment
--     world  optional game-state overrides (engine_stubs.lua)
--     game.env     the global table; the sandbox's contents only inside game.run
--     game.report  the engine_stubs report (unknown calls, world reads, randomness)
--     game.run(fn, ...) -> fn's results   runs fn with the sandbox active

local MOD = "mods/spell_bracket_visualizer/files/engine/"
local compat = dofile_once(MOD .. "lua_compat.lua")
local stubs = dofile_once(MOD .. "engine_stubs.lua")

local M = {}

-- Captured now: the overlay changes what the global names mean while it is on.
local pairs, ipairs, rawset, rawget = pairs, ipairs, rawset, rawget
local setmetatable, getmetatable = setmetatable, getmetatable
local pcall, error, type, tostring, assert = pcall, error, type, tostring, assert
local real_table, real_math = table, math
local real_globals = _G
local unpack = compat.unpack

local function copy_table(source)
	local out = {}
	for k, v in pairs(source) do out[k] = v end
	return out
end

-- Only a C function can touch the engine; a function written in Lua is code (the
-- game's own gunaction_generated.lua helpers, another mod's utilities) that has
-- to keep working -- whatever engine call it makes is neutralised on its own.
-- `debug` may not exist in Noita, in which case the ConfigGun* family (Lua
-- helpers that gun.lua cannot run without) is spared by name instead.
local get_info = type(debug) == "table" and debug.getinfo or nil

local function is_lua_function(key, value)
	if get_info then
		local ok, info = pcall(get_info, value, "S")
		if ok and info then return info.what ~= "C" end
	end
	return key:find("^ConfigGun") ~= nil
end

--- Engine API names are CamelCase: a C function whose name starts with a capital
-- letter is treated as the engine's.
local function is_engine_function(key, value)
	return type(key) == "string" and type(value) == "function"
		and key:find("^%u") ~= nil and not is_lua_function(key, value)
end

--- The overlay itself.  `state` is the sandbox's own contents between calls:
-- every global it changed or added the last time it ran.
local function new_overlay(report_of)
	local state, meta = {}, nil
	local active = false
	local overlay = {}

	local function clear()
		local keys = {}
		for k in pairs(real_globals) do keys[#keys + 1] = k end
		for _, k in ipairs(keys) do rawset(real_globals, k, nil) end
	end

	function overlay.set_metatable(m) meta = m end

	function overlay.run(fn, ...)
		assert(not active, "the sandbox is already active")
		active = true
		local saved, saved_meta = copy_table(real_globals), getmetatable(real_globals)

		local report = report_of()
		if report then
			for k, v in pairs(saved) do
				if is_engine_function(k, v) then
					rawset(real_globals, k, stubs.neutral_call(report, k))
				end
			end
		end
		for k, v in pairs(state) do rawset(real_globals, k, v) end
		setmetatable(real_globals, meta)
		local applied = copy_table(real_globals)

		local results = { pcall(fn, ...) }

		-- Keep what the sandbox changed or added, plus what it already held (its
		-- entries were applied above, so they only differ if the run changed them).
		-- The counting no-ops are not kept: they are rebuilt on every call.
		local after = copy_table(real_globals)
		local kept = {}
		for k, v in pairs(after) do
			if v ~= applied[k] then kept[k] = v end
		end
		for k in pairs(state) do
			if after[k] ~= nil then kept[k] = after[k] end
		end
		state = kept
		clear()
		for k, v in pairs(saved) do rawset(real_globals, k, v) end
		setmetatable(real_globals, saved_meta)
		active = false

		if not results[1] then error(results[2], 0) end
		return unpack(results, 2)
	end
	return overlay
end

function M.new(host, world)
	local game = { env = real_globals }
	local overlay = new_overlay(function() return game.report end)
	game.run = overlay.run

	local ok, err = pcall(overlay.run, function()
		-- the sandbox's own copies of the two libraries the tracer hooks into
		rawset(real_globals, "table", copy_table(real_table))
		rawset(real_globals, "math", copy_table(real_math))
		if rawget(real_globals, "unpack") == nil then rawset(real_globals, "unpack", unpack) end

		game.report = stubs.install(real_globals, world)
		-- Any capitalised name that is not defined at all is an engine call we do
		-- not model: answered with a counting no-op (engine_stubs.lua).
		local handler = { __index = stubs.unknown_call_handler(real_globals, game.report) }
		overlay.set_metatable(handler)
		setmetatable(real_globals, handler)

		if host and host.dofile then
			-- offline: game files come from disk, so route gun.lua's own loading
			local loaded = {}
			rawset(real_globals, "dofile", host.dofile)
			rawset(real_globals, "dofile_once", function(path)
				if loaded[path] == nil then loaded[path] = { host.dofile(path) } end
				return loaded[path][1]
			end)
		end

		-- gun.lua pulls in gun_actions.lua itself (its last line), so one call
		-- loads the whole cast machinery plus every spell, vanilla and modded.
		rawget(real_globals, "dofile")("data/scripts/gun/gun.lua")
		local actions = rawget(real_globals, "actions")
		if type(actions) ~= "table" or #actions == 0 then
			error("gun_actions.lua did not define any spells", 0)
		end
	end)
	if not ok then return nil, tostring(err) end
	return game
end

return M
