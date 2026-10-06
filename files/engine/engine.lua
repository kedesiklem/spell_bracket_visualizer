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
--   M.new(host_dofile, world) -> engine | nil, error_message
--     host_dofile(path)   runs a game file with the global table as environment
--                         (see game_env.lua)
--     world               optional game-state overrides (see engine_stubs.lua)
--   engine.run(wand)            -> result   (see wand_runner.lua)
--   engine.action_type(id)      -> "PROJECTILE" | "MODIFIER" | ... | nil
--   engine.knows(id)            -> bool    is this a spell the game defines?
--   engine.name_key(id)         -> string|nil   the "$action_..." text key
--   engine.spell_count()        -> number
--   M.new_in_game(world)        -> engine | nil, error_message
--                                  M.new fed from the game's own `dofile`

local MOD = "mods/spell_bracket_visualizer/files/engine/"
local game_env = dofile_once(MOD .. "game_env.lua")
local cast_tracer = dofile_once(MOD .. "cast_tracer.lua")
local wand_runner = dofile_once(MOD .. "wand_runner.lua")

local M = {}

function M.new(host_dofile, world)
	local game, err = game_env.new(host_dofile, world)
	if not game then return nil, err end

	-- The tracer hooks the sandbox's functions, so it is attached -- and the
	-- spell table read -- with the sandbox active.
	local tracer
	local known, name_keys, count = {}, {}, 0
	local ok, attach_err = pcall(game.run, function()
		tracer = cast_tracer.attach(game.env, game.report)
		for _, action in ipairs(game.env.actions) do
			if action.id then
				known[action.id] = true
				name_keys[action.id] = action.name
				count = count + 1
			end
		end
	end)
	if not ok then return nil, tostring(attach_err) end

	local engine = {}
	function engine.run(wand)
		return game.run(wand_runner.run, game.env, tracer, game.report, wand)
	end
	function engine.action_type(id) return tracer.action_type(id) end
	function engine.knows(id) return known[id] == true end
	function engine.name_key(id) return name_keys[id] end
	function engine.spell_count() return count end
	return engine
end

function M.new_in_game(world)
	return M.new(game_env.game_dofile(), world)
end

return M
