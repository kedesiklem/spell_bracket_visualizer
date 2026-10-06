-- The engine layer's single entry point: "run this wand through the real game
-- cast code and tell me what happened".
--
-- Credit: evaluating a wand by running the game's own cast code in a sandbox is
-- the approach of kaliuresis' WandDBG (https://github.com/kaliuresis/WandDBG).
--
-- It only wires the pieces together; each piece owns one job:
--   game_env.lua     a sandbox holding the game's gun.lua + every spell
--   engine_stubs.lua the fake world those scripts read from (used by game_env)
--   cast_tracer.lua  hooks that record every cast as a tree of nodes
--   wand_runner.lua  the protocol for operating gun.lua over one wand
--
-- Everything above this layer (wand_structure.lua, the overlay, the tests)
-- talks to this object and never to the sandbox directly.
--
-- Public API
--   M.new(read_source, world) -> engine | nil, error_message
--     read_source(path) -> string|nil   how to fetch a game file (see game_env.lua)
--     world             optional game-state overrides (see engine_stubs.lua)
--   engine.run(wand)            -> result   (see wand_runner.lua)
--   engine.action_type(id)      -> "PROJECTILE" | "MODIFIER" | ... | nil
--   engine.knows(id)            -> bool    is this a spell the game defines?
--   engine.name_key(id)         -> string|nil   the "$action_..." text key
--   engine.spell_count()        -> number
--   M.new_in_game(world)        -> engine | nil, error_message
--                                  M.new fed from the game's own file system

local MOD = "mods/spell_bracket_visualizer/files/engine/"
local game_env = dofile_once(MOD .. "game_env.lua")
local cast_tracer = dofile_once(MOD .. "cast_tracer.lua")
local wand_runner = dofile_once(MOD .. "wand_runner.lua")

local M = {}

function M.new(read_source, world)
	local env, report_or_err = game_env.new(read_source, world)
	if not env then return nil, report_or_err end
	local report = report_or_err
	local tracer = cast_tracer.attach(env, report)

	local known, name_keys = {}, {}
	for _, action in ipairs(env.actions) do
		if action.id then
			known[action.id] = true
			name_keys[action.id] = action.name
		end
	end

	local engine = {}
	function engine.run(wand) return wand_runner.run(env, tracer, report, wand) end
	function engine.action_type(id) return tracer.action_type(id) end
	function engine.knows(id) return known[id] == true end
	function engine.name_key(id) return name_keys[id] end
	function engine.spell_count() return #env.actions end
	return engine
end

function M.new_in_game(world)
	return M.new(game_env.game_source_reader(), world)
end

return M
