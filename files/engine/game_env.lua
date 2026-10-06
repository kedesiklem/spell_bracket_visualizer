-- A sandbox holding the game's own cast code, loaded but not yet driven.
--
-- Credit: evaluating a wand by running the game's own cast code in a sandbox is
-- the approach of kaliuresis' WandDBG (https://github.com/kaliuresis/WandDBG).
--
-- WHY A SANDBOX
--   gun.lua and gun_actions.lua are written as plain scripts over global state
--   (`deck`, `hand`, `discarded`, `c`, `mana`, ...).  Running them in the real
--   global table would overwrite the live game's copies of those names -- and
--   clash with other mods, which also load them (Spell Lab, WandDBG, ...).  So
--   every game file is compiled into a private environment table instead.  The
--   cast code runs unmodified; it just cannot see, or touch, anything outside.
--
-- WHAT THE SANDBOX CONTAINS
--   * a whitelist of pure Lua functions (no io, os, debug, require...),
--   * private copies of `table` and `math`, so the tracer can wrap
--     `table.insert`/`table.remove` without touching the game's versions,
--   * the engine stand-ins from engine_stubs.lua, and
--   * `dofile`/`dofile_once` that resolve game files through an injected
--     `read_source(path)` function and compile them INTO the sandbox.
--
-- WHERE THE SOURCE COMES FROM
--   `read_source` is injected, which is what lets one engine serve two hosts:
--   in the game it is `ModTextFileGetContent` (which also sees spells other
--   mods appended to gun_actions.lua); in the offline tools it reads files
--   extracted from data.wak.  See M.game_source_reader below.
--
-- Public API
--   M.new(read_source, world) -> env, report   (or nil, error_message)
--     env     sandbox with gun.lua and gun_actions.lua already loaded
--     report  the engine_stubs report (unknown calls, world reads, randomness)
--   M.game_source_reader()    -> function usable as `read_source` in the game

local MOD = "mods/spell_bracket_visualizer/files/engine/"
local compat = dofile_once(MOD .. "lua_compat.lua")
local stubs = dofile_once(MOD .. "engine_stubs.lua")

local M = {}

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

local function new_sandbox()
	local env = {}
	for _, name in ipairs(PURE_FUNCTIONS) do env[name] = _G[name] end
	env.unpack = env.unpack or compat.unpack
	env.string = string
	env.table = copy_table(table)
	env.math = copy_table(math)
	env._G = env
	return env
end

--- Make `dofile` / `dofile_once` compile game files into `env`.
local function install_loader(env, read_source)
	local loaded = {}

	local function load_file(path)
		local source = read_source(path)
		if source == nil or source == "" then
			error("game file not found: " .. tostring(path), 0)
		end
		local chunk, err = compat.load_in_env(source, "@" .. path, env)
		if not chunk then error(err, 0) end
		return chunk()
	end

	env.dofile = load_file
	env.dofile_once = function(path)
		if loaded[path] == nil then loaded[path] = { load_file(path) } end
		return loaded[path][1]
	end
end

function M.new(read_source, world)
	local env = new_sandbox()
	local report = stubs.install(env, world)
	setmetatable(env, { __index = stubs.unknown_call_handler(env, report) })
	install_loader(env, read_source)

	-- gun.lua pulls in gun_actions.lua itself (its last lines), so one call
	-- loads the whole cast machinery plus every spell, vanilla and modded.
	local ok, err = pcall(env.dofile, "data/scripts/gun/gun.lua")
	if not ok then return nil, tostring(err) end
	if type(env.actions) ~= "table" or #env.actions == 0 then
		return nil, "gun_actions.lua did not define any spells"
	end
	return env, report
end

--- `read_source` for use inside Noita.  `ModTextFileGetContent` reads the
-- game's virtual file system, so spells that other mods add with
-- `ModLuaFileAppend("data/scripts/gun/gun_actions.lua", ...)` are included --
-- provided this runs after those mods have finished initialising.
function M.game_source_reader()
	return function(path) return ModTextFileGetContent(path) end
end

return M
