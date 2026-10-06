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
--     world  optional table of game-state values (see DEFAULT_WORLD)
--     report { unknown = { name = count }, world_reads = { field = count },
--              random_used = bool,
--              deps = { field = value },
--              events = number,       -- filled in as the cast code runs
--              set_world = function(values),
--              begin_run = function() }
--   `events` counts every GUESS: a read of a world value nobody supplied, a
--   random draw, an unknown engine call -- so a caller can ask "did anything
--   uncertain happen between these two moments?" by comparing the counter
--   (cast_tracer.lua does this per card).
--
-- KNOWN vs GUESSED
--   A world field the caller SUPPLIED (the live game's real HP, the real
--   every-other toggle...) is KNOWN: reading it is not a guess, so a wand that
--   branches on it is still a certain wand -- for that value of the field.  A
--   field left at its DEFAULT_WORLD value is a guess and is counted.  Either way
--   the read is remembered in `report.deps`, so a cached result can be thrown
--   away exactly when a value it depended on changes (see wand_sim_cache.lua).
--   State the sandbox owns itself (what the cast code wrote with GlobalsSetValue
--   earlier in the same run, the fake entity tree) is plain bookkeeping and is
--   never a guess.

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
	every_other_state = nil,   -- 0 or 1: the "every other" toggle; nil = not known
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

-- Component fields the cast code reads, mapped to the world field that backs
-- them.  A field NOT listed here is a constant of the fake tree and therefore a
-- guess (it is reported under "component:<field>").
local DAMAGE_FIELDS = { hp = "hp", max_hp = "max_hp", n_stainless = "n_stainless",
	ambrosia = "ambrosia", damage_multipliers = "damage_multipliers" }
local WALLET_FIELDS = { money = "money", mMoneyPrevFrame = "money" }
local ITEM_FIELDS = { action_id = "zeta_options", mActiveItem = "zeta_options" }

-- Entity tags the cast code counts, mapped to the world field holding the count.
-- (The live reader, live_world.lua, measures the two radii the spells use.)
local COUNT_FIELDS = { homing_target = "n_enemies", projectile = "n_projectiles",
	black_hole_giga = "n_omega_black_holes" }

-- The fake player: just the components the cast code is known to query.  Its
-- values are copied from `world` when a run begins (a damage spell mutates
-- them, and that must not leak into the next run).
local function build_player(world)
	local zeta_wand = { name = "wand", tags = "wand,", components = {}, children = {} }
	for _, action_id in ipairs(world.zeta_options) do
		zeta_wand.children[#zeta_wand.children + 1] = {
			name = "", tags = "", children = {},
			components = { { type_name = "ItemActionComponent", tags = "",
				fields = ITEM_FIELDS, action_id = action_id } },
		}
	end
	return {
		name = "player", tags = "player_unit,",
		components = {
			{ type_name = "DamageModelComponent", tags = "", fields = DAMAGE_FIELDS,
				hp = world.hp, max_hp = world.max_hp,
				damage_multipliers = world.damage_multipliers,
				n_stainless = world.n_stainless, ambrosia = world.ambrosia },
			{ type_name = "WalletComponent", tags = "", fields = WALLET_FIELDS,
				mHasReachedInf = 0, mMoneyPrevFrame = world.money,
				money = world.money, money_spent = 0 },
			{ type_name = "Inventory2Component", tags = "", fields = ITEM_FIELDS,
				mActiveItem = {} },
		},
		children = { {
			name = "inventory_quick", tags = "", components = {},
			children = { zeta_wand },
		} },
	}
end

local EVERY_OTHER_KEY = "GUN_ACTION_IF_HALF_STATUS"

function M.install(env, world_values)
	local world, known = {}, {}
	for k, v in pairs(DEFAULT_WORLD) do world[k] = v end

	local report = { unknown = {}, world_reads = {}, random_used = false,
		events = 0, deps = {} }
	local player
	local globals = {}   -- the sandbox's own GlobalsGetValue/SetValue store

	--- Replace the game state the cast code will see.  Every field present in
	-- `values` is KNOWN from now on; fields absent keep their default and stay
	-- guesses.  Called once at install and again whenever the live game moves.
	function report.set_world(values)
		world, known = {}, {}
		for k, v in pairs(DEFAULT_WORLD) do world[k] = v end
		for k, v in pairs(values or {}) do world[k] = v; known[k] = true end
	end

	--- The value the sandbox currently holds for a world field (nil for the
	-- "globals:" / "component:" pseudo-fields that never have a real value).
	function report.world_value(field) return world[field] end

	--- Note that the cast code consulted world field `field`.  Returns nothing;
	-- a read of an unsupplied field is a guess and bumps the event counter.
	local function consult(field)
		report.deps[field] = world[field]
		if not known[field] then
			report.world_reads[field] = (report.world_reads[field] or 0) + 1
			report.events = report.events + 1
		end
	end

	--- Start of one run: fresh fake player, fresh Globals store (seeded with the
	-- every-other toggle when it is known), no dependencies recorded yet.
	function report.begin_run()
		player = build_player(world)
		globals = {}
		if world.every_other_state ~= nil then
			globals[EVERY_OTHER_KEY] = tostring(world.every_other_state)
		end
		report.deps = {}
	end

	report.set_world(world_values)
	report.begin_run()

	for _, name in ipairs(NOOP) do env[name] = function() end end

	-- Reads of the fake world.  Entity/component plumbing is bookkeeping of the
	-- sandbox's own tree and never a guess; what it HOLDS is consulted by field.
	env.GameGetFrameNum = function() consult("frame"); return world.frame end
	env.GlobalsGetValue = function(key, default)
		local v = globals[key]
		if v ~= nil then return v end            -- written during this run
		if key == EVERY_OTHER_KEY then
			consult("every_other_state")         -- the player's live toggle
		else
			report.world_reads["globals:" .. tostring(key)] = 1
			report.events = report.events + 1    -- some other mod's state: unknown
		end
		return default or "0"
	end
	env.GlobalsSetValue = function(key, value) globals[key] = tostring(value) end
	env.HasFlagPersistent = function() consult("persistent_flags"); return false end

	local function entities_with(tag)
		local found = {}
		if has_tag(player, tag) then found[#found + 1] = player end
		local field = COUNT_FIELDS[tag]
		if field then consult(field) elseif tag ~= "player_unit" then consult("entities:" .. tag) end
		-- Nearby-entity counts are numbers, not entities: pad with inert ones.
		for _ = 1, field and world[field] or 0 do
			found[#found + 1] = { name = "", tags = tag .. ",", components = {}, children = {} }
		end
		return found
	end
	env.EntityGetWithTag = entities_with
	env.EntityGetInRadiusWithTag = function(_, _, _, tag) return entities_with(tag) end
	env.GetUpdatedEntityID = function() return player end
	env.EntityGetComponent = function(entity, type_name, tag)
		local out = {}
		for _, c in ipairs((entity or {}).components or {}) do
			if c.type_name == type_name and (tag == nil or has_tag(c, tag)) then
				out[#out + 1] = c
			end
		end
		return out
	end
	env.EntityGetFirstComponent = function(entity, type_name, tag)
		return component_of(entity, type_name, tag)
	end
	env.EntityGetFirstComponentIncludingDisabled = env.EntityGetFirstComponent
	env.EntityGetAllChildren = function(entity)
		if entity then return entity.children end
	end
	env.EntityGetName = function(entity) if entity then return entity.name end end
	env.EntityHasTag = function(entity, tag) return has_tag(entity, tag) end
	env.ComponentGetValue2 = function(component, field)
		local backing = component.fields and component.fields[field]
		consult(backing or ("component:" .. tostring(field)))
		return component[field]
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
