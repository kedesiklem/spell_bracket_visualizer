-- Drives the sandboxed game cast code over one wand, for one recharge cycle.
--
-- This is the only place that knows the *protocol* for operating gun.lua from
-- the outside -- the same sequence the engine itself follows when the player
-- fires a wand:
--
--   _clear_deck / _add_card_to_deck   load the wand's cards, in slot order
--   _start_shot(mana)                 begin a cast
--   _play_permanent_card(id)          fire each always-cast card
--   _draw_actions_for_shot(false)     draw the cast
--   _handle_reload()                  finish it (which may start a recharge)
--
-- The last two are separate calls on purpose: the game's C++ side makes them
-- separately, and the order matters.  _draw_actions_for_shot clears `reloading`
-- on its way out, so only a _handle_reload made AFTER it sees an exhausted deck
-- and starts the recharge.  Passing `true` to fold them together skips that and
-- the wand never reloads after a cast that simply ran out of cards.
--
-- It repeats casts until the wand starts a recharge, which is the span the mod
-- visualises: everything the wand does before it cycles back to its first card.
-- A cast that WRAPS also ends the span: the engine sets its recharge flag on
-- every wrap except the one RESET performs, but after RESET the deck is whole
-- again too, so what follows would only repeat the cycle from its first card.
--
-- Public API
--   M.run(env, tracer, report, wand) -> result
--     wand   = { tokens = { action_id... },        the wand's cards, slot order
--                always = { action_id... },        always-cast cards
--                spells_per_cast = N,              gun.actions_per_round
--                uses = { [slot] = uses_left },    sparse; absent = unlimited
--                mana = N, shuffle = bool }
--     result = { casts = { cast... },              see cast_tracer.lua
--                shuffle = true }                  (and no casts) for shuffle wands
--            | { error = "message" }
--     Each cast also carries `mana_spent`, straight from the engine's own counter.
--     `result.uncertain` names what made the answer depend on a guess:
--       { random = bool, world = { name = count }, unknown = { name = count } }

local M = {}

-- Enough that a modest wand never fizzles; the panel cannot know the player's
-- real mana, and a structure that changed with it would not be a structure.
local PLENTY_OF_MANA = 1e9

-- A wand holds at most a few dozen cards and every cast removes at least one,
-- so a recharge cycle always ends well before this.  It exists only so a bug can
-- never turn into an endless loop inside the game's update tick.
local MAX_CASTS = 64

local function count_keys(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

local function reset_report(report)
	for k in pairs(report.unknown) do report.unknown[k] = nil end
	for k in pairs(report.world_reads) do report.world_reads[k] = nil end
	report.random_used = false
end

local function snapshot_report(report)
	local function copy(t)
		local out = {}
		for k, v in pairs(t) do out[k] = v end
		return out
	end
	return { random = report.random_used,
		world = copy(report.world_reads), unknown = copy(report.unknown) }
end

-- gun.lua keeps cast state in globals that _start_shot only partly resets.  A
-- previous run that stopped early (an error, the cast cap) must not leak into
-- this one, so put every flag the draw path reads back to its starting value.
local function reset_cast_state(env)
	env.start_reload = false
	env.reloading = false
	env.dont_draw_actions = false
	env.force_stop_draws = false
	env.playing_permanent_card = false
	env.got_projectiles = false
	env.active_extra_modifiers = {}
	env.shot_structure = {}
end

local function load_deck(env, wand)
	reset_cast_state(env)
	env._clear_deck(false)
	env.gun.actions_per_round = math.max(1, wand.spells_per_cast or 1)
	env.gun.shuffle_deck_when_empty = false
	env.gun.reload_time = 0
	env.state_from_game = {}
	env.ConfigGunActionInfo_Init(env.state_from_game)

	local uses = wand.uses or {}
	for slot, id in ipairs(wand.tokens) do
		env._add_card_to_deck(id, slot, uses[slot] or -1, true)
	end
	-- gun.lua skips ids it does not know, so a short deck means a bad id.
	if #env.deck ~= #wand.tokens then
		return "unknown spell id in the wand (" .. #env.deck .. " of "
			.. #wand.tokens .. " cards loaded)"
	end
end

function M.run(env, tracer, report, wand)
	if wand.shuffle then return { shuffle = true, casts = {} } end
	reset_report(report)

	local problem = load_deck(env, wand)
	if problem then return { error = problem, casts = {} } end

	local casts = {}
	local mana = wand.mana or PLENTY_OF_MANA
	for index = 1, MAX_CASTS do
		tracer.begin_cast()
		local ok, err = pcall(function()
			env._start_shot(mana)
			for _, id in ipairs(wand.always or {}) do env._play_permanent_card(id) end
			env._draw_actions_for_shot(false)
			env._handle_reload()
		end)
		local cast = tracer.end_cast()
		if not ok then return { error = tostring(err), casts = casts } end

		cast.index = index
		cast.mana_spent = mana - env.mana
		casts[#casts + 1] = cast
		if cast.reload or cast.wrapped then break end
	end

	local uncertain = snapshot_report(report)
	local result = { casts = casts }
	if uncertain.random or count_keys(uncertain.world) > 0
		or count_keys(uncertain.unknown) > 0 then
		result.uncertain = uncertain
	end
	return result
end

return M
