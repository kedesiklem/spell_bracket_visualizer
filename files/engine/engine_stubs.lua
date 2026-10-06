-- Stand-ins for the Noita engine API that the game's cast code (gun.lua and
-- the spell bodies in gun_actions.lua) calls while it decides what to draw.
--
-- WHY THIS EXISTS
--   The mod runs the game's OWN cast code inside a sandbox (game_env.lua) so
--   the structure it shows is whatever the engine really does, not a copy of
--   it.  That code, however, is written against the live game: it spawns
--   projectiles, reads the player's health, counts nearby enemies...  None of
--   those side effects matter to *which cards get drawn*, but a handful of
--   READS do (the "If ..." spells branch on game state).  This file supplies:
--
--     * harmless no-ops for the pure side effects,
--     * a small fake world for the reads that steer the draw order, and
--     * bookkeeping that records everything it could NOT answer faithfully, so
--       a wand whose structure depended on a guess is flagged instead of shown
--       as if it were certain.
--
-- WHAT IT DELIBERATELY DOES NOT DO
--   It never forwards to the real engine API.  Calling the real
--   `EntityLoad` from a simulation would spawn real entities in the player's
--   game, so the sandbox has no path to the global table at all.
--
-- The fake-world half (entities, components, the player) follows the approach
-- of kaliuresis' WandDBG (files/debugger.lua): a plain-table entity tree that
-- the real action bodies can query as if it were the game.
--
-- Public API
--   M.install(env, world) -> report
--     env    the sandbox table the cast code runs in
--     world  optional table of game-state overrides (see DEFAULT_WORLD)
--     report { unknown = { name = count }, world_reads = { name = count },
--              random_used = bool,
--              events = number }      -- filled in as the cast code runs
--   `events` counts every world read, random draw and unknown engine call, so
--   a caller can ask "did anything uncertain happen between these two moments?"
--   by comparing the counter (cast_tracer.lua does this per card).

local M = {}

-- Game state the cast code can read, with the values used when the caller
-- supplies none.  `hp` and `max_hp` are in the engine's units (1 HP = 25 UI
-- HP), matching what DamageModelComponent reports.
local DEFAULT_WORLD = {
	hp = 4, max_hp = 4,
	money = 0,
	n_enemies = 0,          -- entities tagged "homing_target" nearby
	n_projectiles = 0,      -- entities tagged "projectile" nearby
	n_omega_black_holes = 0,
	n_stainless = 0,
	ambrosia = false,
	frame = 0,
	every_other_state = nil,   -- nil keeps the game's own toggle value
	zeta_options = {},         -- action ids on the player's other wands
	damage_multipliers = {
		curse = 1, drill = 1, electricity = 1, explosion = 0.35, fire = 1,
		healing = 1, ice = 1, melee = 1, overeating = 1, physics_hit = 1,
		poison = 1, projectile = 1, radioactive = 1, slice = 1,
	},
}

-- Engine calls that are pure side effects on the world.  Nothing the cast
-- code does afterwards depends on their return value.
local NOOP = {
	"Reflection_RegisterProjectile", "BeginProjectile", "EndProjectile",
	"BeginTriggerTimer", "BeginTriggerHitWorld", "BeginTriggerDeath",
	"EndTrigger", "BaabInstruction", "SetProjectileConfigs",
	"OnActionPlayed", "OnNotEnoughManaForAction", "ActionUsesRemainingChanged",
	"ActionUsed", "StartReload", "LogAction", "print_error", "GamePrint",
	"EntityKill", "GameAddFlagRun", "GameRemoveFlagRun", "AddFlagPersistent",
	"RemoveFlagPersistent", "GameScreenshake", "LoadPixelScene",
	"RegisterGunAction", "RegisterGunShotEffects",
	-- hand a finished shot's state to the game: pure plumbing, nothing to learn
	"ConfigGunActionInfo_PassToGame", "ConfigGunShotEffects_PassToGame",
}

-- Calls whose answer decides what an action body does.  Counted in
-- `report.world_reads` so the caller can tell that a wand's structure depended
-- on the (fake) world state.
local WORLD_READS = {
	"EntityGetWithTag", "EntityGetInRadiusWithTag", "GetUpdatedEntityID",
	"EntityGetComponent", "EntityGetFirstComponent",
	"EntityGetFirstComponentIncludingDisabled", "ComponentGetValue2",
	"EntityGetAllChildren", "EntityGetName", "EntityHasTag",
	"GameGetFrameNum", "GlobalsGetValue", "HasFlagPersistent",
}

local function has_tag(entity, tag)
	return entity ~= nil and entity.tags ~= nil
		and string.find("," .. entity.tags, "," .. tag .. ",", 1, true) ~= nil
end

local function component_of(entity, type_name, tag)
	if entity == nil then return nil end
	for _, c in ipairs(entity.components or {}) do
		if c.type_name == type_name and (tag == nil or has_tag(c, tag)) then
			return c
		end
	end
	return nil
end

-- The fake player: just the components the cast code is known to query.
local function build_player(world)
	local zeta_wand = { name = "wand", tags = "wand,", components = {}, children = {} }
	for _, action_id in ipairs(world.zeta_options) do
		zeta_wand.children[#zeta_wand.children + 1] = {
			name = "", tags = "", children = {},
			components = { { type_name = "ItemActionComponent", tags = "",
				action_id = action_id } },
		}
	end
	return {
		name = "player", tags = "player_unit,",
		components = {
			{ type_name = "DamageModelComponent", tags = "",
				hp = world.hp, max_hp = world.max_hp,
				damage_multipliers = world.damage_multipliers,
				n_stainless = world.n_stainless, ambrosia = world.ambrosia },
			{ type_name = "WalletComponent", tags = "",
				mHasReachedInf = 0, mMoneyPrevFrame = world.money,
				money = world.money, money_spent = 0 },
			{ type_name = "Inventory2Component", tags = "", mActiveItem = {} },
		},
		children = { {
			name = "inventory_quick", tags = "", components = {},
			children = { zeta_wand },
		} },
	}
end

function M.install(env, world_overrides)
	local world = {}
	for k, v in pairs(DEFAULT_WORLD) do world[k] = v end
	for k, v in pairs(world_overrides or {}) do world[k] = v end

	local report = { unknown = {}, world_reads = {}, random_used = false, events = 0 }
	local player = build_player(world)
	local globals = {}   -- the sandbox's own GlobalsGetValue/SetValue store
	if world.every_other_state ~= nil then
		globals["GUN_ACTION_IF_HALF_STATUS"] = world.every_other_state and "1" or "0"
	end

	for _, name in ipairs(NOOP) do env[name] = function() end end

	-- Reads that steer the draw order.  Each is wrapped below to be counted.
	local reads = {}

	reads.GameGetFrameNum = function() return world.frame end
	reads.GlobalsGetValue = function(key, default)
		local v = globals[key]
		if v == nil then return default or "0" end
		return v
	end
	env.GlobalsSetValue = function(key, value) globals[key] = tostring(value) end
	reads.HasFlagPersistent = function() return false end

	local counts = {
		homing_target = world.n_enemies,
		projectile = world.n_projectiles,
		black_hole_giga = world.n_omega_black_holes,
	}
	reads.EntityGetWithTag = function(tag)
		local found = {}
		if has_tag(player, tag) then found[#found + 1] = player end
		-- Nearby-entity counts are numbers, not entities: pad with inert ones.
		for _ = 1, counts[tag] or 0 do
			found[#found + 1] = { name = "", tags = tag .. ",", components = {}, children = {} }
		end
		return found
	end
	reads.EntityGetInRadiusWithTag = function(_, _, _, tag)
		return reads.EntityGetWithTag(tag)
	end
	reads.GetUpdatedEntityID = function() return player end
	reads.EntityGetComponent = function(entity, type_name, tag)
		local out = {}
		for _, c in ipairs((entity or {}).components or {}) do
			if c.type_name == type_name and (tag == nil or has_tag(c, tag)) then
				out[#out + 1] = c
			end
		end
		return out
	end
	reads.EntityGetFirstComponent = function(entity, type_name, tag)
		return component_of(entity, type_name, tag)
	end
	reads.EntityGetFirstComponentIncludingDisabled = reads.EntityGetFirstComponent
	reads.EntityGetAllChildren = function(entity)
		if entity then return entity.children end
	end
	reads.EntityGetName = function(entity) if entity then return entity.name end end
	reads.EntityHasTag = function(entity, tag) return has_tag(entity, tag) end
	reads.ComponentGetValue2 = function(component, field) return component[field] end

	for _, name in ipairs(WORLD_READS) do
		local fn = reads[name]
		env[name] = function(...)
			report.world_reads[name] = (report.world_reads[name] or 0) + 1
			report.events = report.events + 1
			return fn(...)
		end
	end

	-- Writes the cast code makes to the fake world.
	env.ComponentSetValue2 = function(component, field, value) component[field] = value end
	env.EntityGetTransform = function() return 0, 0, 0, 1, 1 end
	env.EntityLoad = function() end
	env.EntityInflictDamage = function(entity, amount, damage_type)
		local dmg = component_of(entity, "DamageModelComponent")
		if dmg == nil or dmg.ambrosia then return end
		local kind = string.lower(string.sub(damage_type or "", 8))
		local mult = (dmg.damage_multipliers or {})[kind] or 1
		dmg.hp = dmg.hp - amount * mult * (0.5 ^ dmg.n_stainless)
	end

	-- Randomness: a deterministic LCG so a run is reproducible.  Any use is
	-- recorded -- a wand whose structure depends on it is NOT a fixed structure.
	local seed = 1
	local function lcg()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed
	end
	local function random_family(fn)
		return function(...)
			report.random_used = true
			report.events = report.events + 1
			return fn(...)
		end
	end
	env.SetRandomSeed = function() end
	env.Random = random_family(function(a, b)
		if a == nil then return lcg() / 2147483648 end
		if b == nil then a, b = 1, a end
		return a + lcg() % (b - a + 1)
	end)
	env.ProceduralRandom = env.Random
	env.ProceduralRandomi = env.Random
	env.ProceduralRandomf = random_family(function() return lcg() / 2147483648 end)

	return report
end

--- A stand-in for one engine function the sandbox does not model: it does
-- nothing, but every CALL is counted, so a wand whose structure may depend on it
-- is flagged.  One closure per name, shared by every user of the report.
function M.neutral_call(report, name)
	report.neutral_ = report.neutral_ or {}
	local fn = report.neutral_[name]
	if fn == nil then
		fn = function()
			report.unknown[name] = (report.unknown[name] or 0) + 1
			report.events = report.events + 1
		end
		report.neutral_[name] = fn
	end
	return fn
end

--- Metatable `__index` for the sandbox: any capitalised name the cast code
-- uses that is not defined at all is an engine call we do not understand.  It is
-- answered with a counting no-op.  (A lowercase unknown name is a bug in the
-- sandbox, not an engine call, so it still reads as nil.)
function M.unknown_call_handler(env, report)
	return function(_, key)
		if type(key) == "string" and key:match("^%u") then
			local noop = M.neutral_call(report, key)
			rawset(env, key, noop)
			return noop
		end
		return nil
	end
end

return M
