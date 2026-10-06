-- Reads the game state the "If ..." spells branch on, from the LIVE game.
--
-- WHY THIS EXISTS
--   The cast sandbox (game_env.lua) answers the cast code's world queries from a
--   fake world (engine_stubs.lua).  Left at its defaults that world is a guess,
--   and a wand whose structure depends on a guess is flagged "uncertain".  But
--   most of what the conditional spells check is perfectly knowable: the
--   player's health, wallet, the enemies and projectiles around them, the
--   every-other toggle.  This module reads those for real, so the sandbox can
--   answer truthfully and the wand stays certain.
--
-- WHY IT IS A SEPARATE FILE
--   Everything here calls the REAL engine API, which the sandbox must never
--   touch (it would act on the player's game).  Reads are harmless, so they are
--   allowed -- but only from here, only outside `game.run`, and only through
--   the handful of read-only functions captured below at load time, i.e. before
--   any sandbox overlay can shadow them.
--
-- RADII
--   Vanilla's IF_ENEMY looks for "homing_target" within 240 px and IF_PROJECTILES
--   for "projectile" within 160 px (gun_actions.lua).  The sandbox has no
--   geometry, only a count per tag, so those two radii are measured here.  A
--   mod spell that counts another radius sees these numbers; that is the one
--   approximation, and it only affects spells that look at the same tags.
--
-- Public API
--   M.read() -> table of whatever could be read, using engine_stubs.lua's
--   field names (hp, max_hp, money, n_enemies, n_projectiles,
--   n_omega_black_holes, every_other_state).  A field that cannot be read (no
--   player yet, API missing) is simply absent, so the sandbox keeps treating
--   it as a guess instead of trusting a made-up value.

local M = {}

-- Read-only engine API, captured now (see above).  Each may be nil outside the
-- game; every use is guarded.
local get_with_tag = EntityGetWithTag
local get_in_radius = EntityGetInRadiusWithTag
local first_component = EntityGetFirstComponent
local component_value = ComponentGetValue2
local get_transform = EntityGetTransform
local globals_get = GlobalsGetValue

local ENEMY_RADIUS, ENEMY_TAG = 240, "homing_target"
local PROJECTILE_RADIUS, PROJECTILE_TAG = 160, "projectile"
local EVERY_OTHER_KEY = "GUN_ACTION_IF_HALF_STATUS"

local function first_of(list)
	if type(list) == "table" then return list[1] end
end

local function count_near(x, y, radius, tag)
	local found = get_in_radius(x, y, radius, tag)
	return type(found) == "table" and #found or nil
end

-- One protected read of the player's state into `out`.
local function read_player(out)
	local player = first_of(get_with_tag("player_unit"))
	if not player then return end

	local damage = first_component(player, "DamageModelComponent")
	if damage then
		out.hp = component_value(damage, "hp")
		out.max_hp = component_value(damage, "max_hp")
	end
	local wallet = first_component(player, "WalletComponent")
	if wallet then out.money = component_value(wallet, "money") end

	local x, y = get_transform(player)
	out.n_enemies = count_near(x, y, ENEMY_RADIUS, ENEMY_TAG)
	out.n_projectiles = count_near(x, y, PROJECTILE_RADIUS, PROJECTILE_TAG)
end

function M.read()
	local out = {}
	if not (get_with_tag and get_in_radius and first_component
			and component_value and get_transform) then
		return out
	end
	pcall(read_player, out)

	local black_holes = get_with_tag("black_hole_giga")
	if type(black_holes) == "table" then out.n_omega_black_holes = #black_holes end

	if globals_get then
		local ok, value = pcall(globals_get, EVERY_OTHER_KEY, "0")
		if ok then out.every_other_state = tonumber(value) or 0 end
	end
	return out
end

return M
