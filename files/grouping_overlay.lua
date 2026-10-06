-- Companion "wand structure" panel (Lisp/SLIME-style).
-- When the inventory is open, reads the active wand's cards in slot order plus
-- its gun_config (spells/cast, shuffle), simulates the cast sequence
-- (files/wand_structure.lua), and draws an indented, color-coded tree of each
-- cast's groupings -- including when the wand WRAPS (forced draws past the
-- deck's end pulling cards from the wand's start: the rapid-fire mechanic).
-- The panel docks beside the SELECTED wand's box (below the stack when the
-- boxes leave no room) and is height-clamped to the screen, so it never sits
-- on top of the wand boxes or the slot brackets.
--
-- Loaded once from init.lua; M.update() is called every frame from
-- OnWorldPostUpdate. All drawing uses our own Gui at coordinates we control, so
-- it never depends on the engine's (unexposed) spell-slot positions.

local sprite_wh_meta = dofile_once("mods/spell_bracket_visualizer/files/wand_sprite_meta.lua") or {}
local wand_structure = dofile_once("mods/spell_bracket_visualizer/files/wand_structure.lua")
local wand_sim_cache = dofile_once("mods/spell_bracket_visualizer/files/wand_sim_cache.lua")
local slot_marks = dofile_once("mods/spell_bracket_visualizer/files/slot_marks.lua")
local engine_module = dofile_once("mods/spell_bracket_visualizer/files/engine/engine.lua")
local live_world = dofile_once("mods/spell_bracket_visualizer/files/engine/live_world.lua")

-- The cast engine (files/engine/): the game's own gun.lua, run in a sandbox.
-- Built on the first update() rather than at load time, because it snapshots
-- every spell definition and by then every mod has finished appending its own
-- spells to gun_actions.lua.  If it cannot be built the panel says why instead
-- of guessing -- there is no second, hand-written simulator to fall back on.
local engine, engine_error, sim_cache = nil, nil, nil
local engine_tried = false
local function ensure_engine()
	if engine_tried then return end
	engine_tried = true
	local ok, built, err = pcall(engine_module.new_in_game)
	if ok and built then
		engine = built
		sim_cache = wand_sim_cache.new(function(wand)
			return wand_structure.simulate(engine, wand)
		end, nil, function(sim) return engine.deps_hold(sim.deps) end)
	else
		engine_error = tostring(ok and err or built)
	end
end

local M = {}
local gui = nil

-- Reading a structure too long for the screen: PageUp / PageDown scroll the
-- panel, Home hides / shows it (SDL scancodes, which is what the game's Input API
-- takes).  The panel's gui is non-interactive on purpose, so the mouse wheel is
-- not used; clicks come from the raw pointer.
local KEY_PAGEUP, KEY_PAGEDOWN, KEY_HOME = 75, 78, 74
local SCROLL_STEP = 5
local panel_view = { scroll = 0 }

-- The raw pointer in GUI coordinates (the engine reports it on a 1280x720
-- screen, twice the 640x360 GUI -- the same conversion the measure tool uses),
-- plus whether the left button went down this frame.  nil when unavailable.
local function read_pointer(sw, sh)
	if type(InputGetMousePosOnScreen) ~= "function" then return nil end
	local ok, mx, my = pcall(InputGetMousePosOnScreen)
	if not ok or not mx or not my then return nil end
	local clicked = false
	if type(InputIsMouseButtonJustDown) == "function" then
		local okc, down = pcall(InputIsMouseButtonJustDown, 1)
		clicked = okc and down == true
	end
	return { x = mx * sw / 1280, y = my * sh / 720, click = clicked }
end

local function key_pressed(code)
	if type(InputIsKeyJustDown) ~= "function" then return false end
	local ok, down = pcall(InputIsKeyJustDown, code)
	return ok and down == true
end

-- Shown in the debug info box so a bug-report screenshot self-identifies the
-- build. Bump on each Workshop release.
local VERSION = "v1.4.0"

-- Panel text size, chosen by the panel_text_size mod setting (enum ids).
-- "large" (1.0) exists for non-pixel fonts: fractional scales only render
-- crisply with the vanilla pixel font, and font mods / TTF-font languages
-- (Japanese etc.) turn them into unreadable mush (see docs/FONT_COMPAT.md).
local PANEL_SCALE_MAP = { tiny = 0.5, small = 0.6, medium = 0.75, large = 1.0 }

-- Calibration measuring tool (debug): middle-click drops a point, a second drops
-- the other end and draws the measured span; a third starts a fresh pair. Lets
-- us read a slot corner's exact GUI coords and the pitch/row-height between two
-- corners -- the only way to pin engine-drawn geometry we can't query (see the
-- data.wak scan: the inventory UI is engine C++, no Lua slot positions exist).
local measure_pts = {}

-- type -> RGB (0..1) for panel row labels. Brightened from the retired
-- icon-recolor border palette: those values were tuned for icon frames, and
-- as 1px text on the dark nine-piece panel the dark red/blue rows were
-- barely legible (UX review 2026-06-11).
local COLOR = {
	PROJECTILE        = { 1.00, 0.45, 0.45 },
	STATIC_PROJECTILE = { 0.40, 0.92, 0.45 },
	MODIFIER          = { 0.50, 0.65, 1.00 },
	DRAW_MANY         = { 0.95, 0.90, 0.35 },
	MATERIAL          = { 0.95, 0.50, 0.95 },
	UTILITY           = { 0.40, 0.90, 0.90 },
	PASSIVE           = { 1.00, 0.68, 0.28 },
	OTHER             = { 0.78, 0.78, 0.78 },
}
local HEADER_COLOR = { 0.85, 0.85, 0.85 }
local INFO_COLOR   = { 0.62, 0.65, 0.70 } -- quiet notes under a row (what was swept, why it failed)
local WRAP_COLOR   = { 1.00, 0.45, 0.15 } -- loud: wrapping is the headline info

-- SLIME-style rainbow: nesting color cycles by depth (panel spines and slot
-- delimiters share it; wrap groups override with WRAP_COLOR -- the wrap
-- signal outranks pretty).
local RAINBOW = {
	{ 1.00, 0.85, 0.30 }, -- gold
	{ 0.45, 0.85, 1.00 }, -- sky
	{ 0.55, 1.00, 0.55 }, -- green
	{ 1.00, 0.55, 0.85 }, -- pink
	{ 0.80, 0.65, 1.00 }, -- violet
	{ 1.00, 0.70, 0.40 }, -- amber
}

local function nest_color(depth)
	return RAINBOW[(depth % #RAINBOW) + 1]
end

local function pretty(id)
	local s = tostring(id):gsub("_", " "):lower()
	s = s:gsub("(%a)([%w]*)", function(a, b) return a:upper() .. b end)
	return s
end

-- Localized spell name ($action_*) if available, else a prettified id.
local function display_name(id)
	local key = engine and engine.name_key(id)
	if key and type(GameTextGet) == "function" then
		local t = GameTextGet(key)
		if t and t ~= "" then return t end
	end
	return pretty(id)
end

local function type_color(atype)
	return COLOR[atype] or COLOR.OTHER
end

-- ---- read the active wand, its cards and its gun_config ---------------------

local function get_active_wand()
	local players = EntityGetWithTag("player_unit")
	if not players or #players == 0 then return nil end
	local inv = EntityGetFirstComponentIncludingDisabled(players[1], "Inventory2Component")
	if not inv then return nil end
	local active = ComponentGetValue2(inv, "mActiveItem")
	if not active or active == 0 then return nil end
	if not EntityHasTag(active, "wand") then return nil end
	return active
end

-- spells/cast + shuffle from the wand's AbilityComponent.gun_config.
-- Verified in-game 2026-06-09. Still pcall-guarded: an error here would
-- disable the whole panel (init.lua kills it on first error), so a future
-- game update changing these fields degrades to 1/cast, no shuffle.
local function read_config(wand)
	local cfg = { spells_per_cast = 1, shuffle = false, capacity = 0, mana_max = 0 }
	if type(ComponentObjectGetValue2) ~= "function" then return cfg end
	local ab = EntityGetFirstComponentIncludingDisabled(wand, "AbilityComponent")
	if not ab then return cfg end
	local ok, spc = pcall(ComponentObjectGetValue2, ab, "gun_config", "actions_per_round")
	if ok and tonumber(spc) and tonumber(spc) > 0 then cfg.spells_per_cast = tonumber(spc) end
	local ok2, sh = pcall(ComponentObjectGetValue2, ab, "gun_config", "shuffle_deck_when_empty")
	cfg.shuffle = ok2 and sh == true
	local ok3, cap = pcall(ComponentObjectGetValue2, ab, "gun_config", "deck_capacity")
	if ok3 and tonumber(cap) and tonumber(cap) > 0 then cfg.capacity = tonumber(cap) end
	-- mana_max / mana_charge_speed sit on the AbilityComponent directly (NOT
	-- inside gun_config, next to it) -- Track E1. mana_max defaults to 0
	-- (unreadable / no mana system on this wand), which reads as "no warning
	-- threshold" everywhere it's checked (cfg.mana_max > 0).
	local ok4, mm = pcall(ComponentGetValue2, ab, "mana_max")
	if ok4 and tonumber(mm) then cfg.mana_max = tonumber(mm) end
	local ok5, mcs = pcall(ComponentGetValue2, ab, "mana_charge_speed")
	if ok5 and tonumber(mcs) then cfg.mana_charge_speed = tonumber(mcs) end
	return cfg
end

-- Returns the deck tokens (slot order) and the always-cast ids separately:
-- always-cast cards never sit in the deck -- the engine plays them at the
-- start of every cast -- so they must not take part in the deck simulation.
--
-- T1.7: depleted cards are modelled by the engine itself (a retried-past pop
-- that lands in cast.spent, per files/wand_structure.lua's header), so this
-- no longer pre-filters anything. ALL non-permanent cards go into `tokens` in
-- slot order, depleted or not, and `uses` carries every reading of
-- uses_remaining this pass could take, keyed by the card's position in
-- `tokens` (the same index simulate() calls `card.i`) -- ignore_depleted just
-- decides, at the call site (collect_wand_boxes), whether that table is
-- handed to simulate() at all. `xs` used to remap surviving cards past the
-- ones the old filter dropped; with nothing dropped that remap is the
-- identity, but the return shape stays so callers (collect_wand_boxes,
-- draw_box_brackets) don't have to change.
local function read_deck(wand, ignore_depleted)
	local raw = {}
	local children = EntityGetAllChildren(wand) or {}
	for _, child in ipairs(children) do
		local iac = EntityGetFirstComponentIncludingDisabled(child, "ItemActionComponent")
		if iac then
			local aid = ComponentGetValue2(iac, "action_id")
			if aid and aid ~= "" then
				local sx, sy, perm, uses, oku = 0, 0, false, nil, false
				local ic = EntityGetFirstComponentIncludingDisabled(child, "ItemComponent")
				if ic then
					local vx, vy = ComponentGetValue2(ic, "inventory_slot")
					sx, sy = vx or 0, vy or 0
					-- verified in-game 2026-06-11 ("always: Bounce" wand); pcall
					-- kept so a future API change degrades to "not always-cast"
					local ok, p = pcall(ComponentGetValue2, ic, "permanently_attached")
					perm = ok and p == true
					oku, uses = pcall(ComponentGetValue2, ic, "uses_remaining")
				end
				raw[#raw + 1] = { id = aid, x = sx, y = sy, perm = perm, uses = uses, oku = oku }
			end
		end
	end

	local cards, always = {}, {}
	for _, r in ipairs(raw) do
		if r.perm then
			always[#always + 1] = r.id
		else
			cards[#cards + 1] = r
		end
	end
	table.sort(cards, function(a, b)
		if a.y ~= b.y then return a.y < b.y end
		return a.x < b.x
	end)
	-- tokens = deck order; xs[i] = that card's real slot column (identity now
	-- that nothing is dropped, but see the comment above); uses[i] = the live
	-- charge count for every card whose read succeeded.
	local tokens, xs, uses = {}, {}, {}
	for i, c in ipairs(cards) do
		tokens[i] = c.id
		xs[i] = c.x
		if c.oku then uses[i] = c.uses end
	end
	return tokens, always, xs, uses
end

-- ---- flatten the simulation into colored, indented display lines -------------

local function copy_list(t)
	local r = {}
	for i = 1, #t do r[i] = t[i] end
	return r
end

-- Flatten one node into display rows. Each row carries `bars`: one color per
-- enclosing group -- SLIME rainbow by nesting depth (wrap groups in
-- WRAP_COLOR) -- plus its own label + type color.
-- Nodes parsed across a wand wrap get a "~" prefix (the card came around).
-- Spells whose real effect depended on the game state at cast time get a "?"
-- after their name: the IF_* requirement spells skip part of the deck when
-- their condition is false, and the random-draw spells cast extra cards no
-- static view can show. The structure drawn is what the engine did in the
-- sandbox's fake world; the "?" says so instead of pretending.
-- A card whose behaviour depended on a guess -- it read game state the sandbox
-- can only fake (an "If ..." spell, a nearby-enemy count), drew a random number,
-- or called an engine function the sandbox does not model -- gets the same "?".
-- `uncertain` is the set of such ids the engine reported for this expression
-- (wand_structure.lua: uncertain_ids); nil means nothing was uncertain.
local function dyn_name(id, rows, uncertain)
	local name = display_name(id)
	if uncertain and uncertain[id] then
		rows.any_dynamic = true
		return name .. "?"
	end
	return name
end

-- Print a mana amount without a trailing ".0" (mana is normally integral, but
-- a modded spell could carry a fractional cost). Shared by sim_rows' cast
-- headers/footnote, the panel title (M.update) and the debug box.
local function fmt(n)
	n = tonumber(n) or 0
	if n == math.floor(n) then return tostring(math.floor(n)) end
	return tostring(n)
end

-- ---- wording for the cards that need more than a name -----------------------

-- Leading cards, as names.  Identical neighbours are folded ("Damage x3"): a
-- Divide By runs the card after it several times, and chained Divide By cards
-- of the same size read better as a count than as a stutter.  `link_runs`
-- (wand_structure.lua) says how often a modifier was re-run.
local function modifier_names(node, rows)
	local mods, names = node.modifiers or {}, {}
	local i = 1
	while i <= #mods do
		local count = (node.link_runs and node.link_runs[i]) or 1
		local j = i + 1
		while j <= #mods and mods[j] == mods[i] do
			count = count + ((node.link_runs and node.link_runs[j]) or 1)
			j = j + 1
		end
		local name = dyn_name(mods[i], rows, node.uncertain_ids)
		names[#names + 1] = count > 1 and (name .. " x" .. count) or name
		i = j
	end
	return names
end

-- Why an Add Trigger / Add Timer / Add Expiration Trigger did nothing.
local TRIGGER_FAILURE = {
	no_target       = "no spell after it to attach to",
	not_carrier     = "the next spell can't carry a trigger",
	depleted_target = "the spell it would carry has no charges left",
}

-- What happened to a card an Add Trigger stepped over.
local SWEPT_EFFECT = {
	applied  = "applied",
	depleted = "no charges, no effect",
	ignored  = "no effect",
	scanner  = "no effect",
}

-- One note listing the cards a scan stepped over, with what each did.  When the
-- scan succeeded they were discarded with the target (charges untouched); when
-- it failed they are all still in the wand.
local function swept_note(node)
	local parts = {}
	for _, card in ipairs(node.swept) do
		parts[#parts + 1] = display_name(card.id) .. " (" .. SWEPT_EFFECT[card.effect] .. ")"
	end
	local lead = node.trigger_failed and "stepped over, kept in the wand: "
		or "stepped over, discarded: "
	return lead .. table.concat(parts, ", ")
end

-- "on hit" / "after 0.33s" / "on expiration": when a trigger's payload fires.
local function trigger_note(node)
	if node.trigger == "timer" then
		if node.trigger_frames then
			return string.format("after %.2gs:", node.trigger_frames / 60)
		end
		return "after a delay:"
	elseif node.trigger == "death" then
		return "on expiration:"
	end
	return "on hit:"
end

-- Where a re-cast copy came from: the slots of the cards a Greek letter (or
-- Double Spell...) copied.
local function copy_note(node)
	if not node.sources or #node.sources == 0 then return "" end
	return "  (copies slot" .. (#node.sources > 1 and "s " or " ")
		.. table.concat(node.sources, ", ") .. ")"
end

local function walk(rows, node, ancestor_colors, depth)
	local mods = ""
	local names = modifier_names(node, rows)
	if #names > 0 then mods = "[" .. table.concat(names, ", ") .. "] " end

	local name = dyn_name(node.id, rows, node.uncertain_ids)
	-- no "xN" / "(trig N)" suffixes (user calls, 2026-06-11): the spell name
	-- already says it and the indented children below show what was gathered
	-- or carried as payload.  The one count that IS shown is how often the engine
	-- ran a card: a re-cast copy, or the target of a Divide By chain.
	local label = mods .. name
	if node.dangling then
		label = label .. (node.divides_nothing and "  (nothing to repeat)" or "  (no projectile)")
	end
	if node.runs then
		label = label .. "  x" .. node.runs
		if node.silent_runs then label = label .. " (" .. node.silent_runs .. " draw nothing)" end
	end
	-- A card the engine re-ran (a Greek letter's copy, Alpha's self-copy, ...) is
	-- not in the deck a second time: say it was re-cast, how often, and from where.
	if node.recast then
		label = "again: " .. label
		if node.count and node.count > 1 then label = label .. "  x" .. node.count end
		label = label .. copy_note(node)
	end
	-- Add Trigger family: failed (nothing consumed) or fired its target plainly.
	if node.trigger_failed then
		label = label .. "  (fails: " .. TRIGGER_FAILURE[node.trigger_failed] .. ")"
	elseif node.no_payload then
		label = label .. "  (no spell left to carry: fires plain)"
	end
	-- Cards a spell threw away without casting them (a failed "If ...").
	if node.skipped and #node.skipped > 0 then
		label = label .. "  (skips " .. #node.skipped
			.. (#node.skipped == 1 and " spell)" or " spells)")
	end
	if node.kind == "reset" then
		local n = node.cleared and #node.cleared or 0
		if n > 0 then
			label = label .. "  (clears " .. n .. " spells)"
		else
			label = label .. "  (nothing left to clear)"
		end
	end
	if node.wrap then label = "~ " .. label end

	rows[#rows + 1] = { bars = copy_list(ancestor_colors), label = label, color = type_color(node.atype) }

	local child_colors = copy_list(ancestor_colors)
	child_colors[#child_colors + 1] = nest_color(depth) -- rainbow even when wrapped
	local function note(text)
		rows[#rows + 1] = { bars = copy_list(child_colors), label = text, color = INFO_COLOR }
	end
	if node.swept and #node.swept > 0 then note(swept_note(node)) end
	if node.kind == "trigger" and node.trigger then note(trigger_note(node)) end

	if node.children and #node.children > 0 then
		for _, ch in ipairs(node.children) do walk(rows, ch, child_colors, depth + 1) end
	end
end

-- True when `nodes` contains a RESET node, at top level or nested inside a
-- multicast/trigger's children (a RESET can sit anywhere a leaf can). Used by
-- the cast header to explain WHY a wrapped cast wraps: RESET always wraps
-- (files/wand_structure.lua's header -- the engine restores the discard pile
-- to the deck immediately), and that is a different reason than running off
-- the end of a normal deck, so the header says so instead of the generic
-- "WRAPS!" line.
local function has_reset(nodes)
	for _, node in ipairs(nodes) do
		if node.kind == "reset" then return true end
		if node.children and #node.children > 0 and has_reset(node.children) then
			return true
		end
	end
	return false
end

-- Rows for the whole simulation: per-cast headers (when there is more than one
-- cast, a wrap, or a cast that can never afford itself), the trees, a loud
-- wrap/recharge banner, and the sticky footnotes ("?" tiers, mana overflow,
-- the bracket-definition legend). `uncertain_ids` are the cards whose
-- behaviour the engine had to guess (wand_structure.uncertain_ids); nil is fine.
local function sim_rows(sim, cfg, always, uncertain_ids)
	local rows = {}
	if sim.error then
		rows[1] = { bars = {}, label = "cannot simulate: " .. tostring(sim.error),
			color = WRAP_COLOR }
		return rows
	end
	local always_uncertain = {}
	for _, id in ipairs(uncertain_ids or {}) do always_uncertain[id] = true end
	if #always > 0 then
		local names = {}
		-- through dyn_name: an always-cast Random Spell / If is just as
		-- unpredictable as one in the deck, and must carry the same "?".
		for _, id in ipairs(always) do names[#names + 1] = dyn_name(id, rows, always_uncertain) end
		rows[#rows + 1] = { bars = {}, label = "always: " .. table.concat(names, ", "),
			color = COLOR.PASSIVE }
	end
	-- Track E1: a cast costing more than the wand can ever hold has to be
	-- visible even when it's the only cast (mana_max > 0 and it's readable).
	local any_over = false
	if cfg.mana_max and cfg.mana_max > 0 then
		for _, cast in ipairs(sim.casts) do
			if cast.mana and cast.mana > cfg.mana_max then any_over = true end
		end
	end
	-- T1.7: a cast whose every draw hit a depleted card has nodes = {} and a
	-- non-empty `spent` (files/wand_structure.lua) -- a real cast that emptied
	-- part of the deck without firing anything. That needs a header even on a
	-- wand with exactly one cast, or the panel would say nothing happened at
	-- all.
	local any_empty_spent = false
	for _, cast in ipairs(sim.casts) do
		if #cast.nodes == 0 and cast.spent and #cast.spent > 0 then any_empty_spent = true end
	end
	local show_headers = (#sim.casts > 1) or sim.wrapped or any_over or any_empty_spent
	for ci, cast in ipairs(sim.casts) do
		local over = cfg.mana_max and cfg.mana_max > 0
			and cast.mana and cast.mana > cfg.mana_max
		local empty_spent = #cast.nodes == 0 and cast.spent and #cast.spent > 0
		if show_headers then
			local h = "cast " .. ci
			if empty_spent then
				h = h .. "  -- no spells left (depleted)"
			end
			h = h .. "  mana " .. fmt(cast.mana or 0)
			if over then h = h .. "  > max " .. fmt(cfg.mana_max) end
			if cast.wrapped then
				if has_reset(cast.nodes) then
					h = h .. "  -- RESET restores the wand -> recharge"
				else
					h = h .. "  -- WRAPS! -> recharge"
				end
			end
			rows[#rows + 1] = { bars = {}, label = h,
				color = (cast.wrapped or over) and WRAP_COLOR or HEADER_COLOR, header = true }
		end
		local spine = show_headers and { HEADER_COLOR } or {}
		for _, node in ipairs(cast.nodes) do walk(rows, node, spine, 0) end
	end
	-- sticky: these explain marks/warnings that survive the row clamp, so they
	-- must outlive the "... +N more" cut rather than being the first lines
	-- dropped. draw_panel holds back every trailing sticky row, in order.
	if rows.any_dynamic or (uncertain_ids and #uncertain_ids > 0) then
		if uncertain_ids and #uncertain_ids > 0 then
			local names = {}
			for _, id in ipairs(uncertain_ids) do names[#names + 1] = display_name(id) end
			rows[#rows + 1] = { bars = {},
				label = "? = " .. table.concat(names, ", ") .. ": structure uncertain",
				color = COLOR.OTHER, sticky = true }
		else
			rows[#rows + 1] = { bars = {}, label = "? = depends on game state when cast",
				color = COLOR.OTHER, sticky = true }
		end
	end
	if any_over then
		rows[#rows + 1] = { bars = {},
			label = "mana = cost of this cast; > max means part of it is discarded",
			color = COLOR.OTHER, sticky = true }
	end
	-- the bracket-definition legend (Track B, docs/ADVANCED_SCENARIOS_PLAN.md
	-- 1): always present whenever there's at least one cast to explain.
	if #sim.casts > 0 then
		rows[#rows + 1] = { bars = {}, label = "[ ] = spells this card pulls from the wand",
			color = COLOR.OTHER, sticky = true }
	end
	return rows
end

-- ---- phase 2: paren-style delimiters on each WAND BOX's spell row -----------
--
-- The engine doesn't expose where it draws the
-- wand boxes, so the layout below is a hand-calibrated stacking model in
-- GUI-screen fractions (re-measured 2026-06-09 from a 2000x1125 screenshot,
-- GUI 640x360). Instead of long underlines spanning the whole group (ugly
-- across empty slots), each group gets Lisp-style [ ] delimiters hugging its
-- first and last card, in the group's color, label above the opening one.
-- The selected box renders taller and shifts everything below it; the selected
-- box IS the held wand (Inventory2Component.mActiveItem), so we correct for it.
local PIXEL = "mods/spell_bracket_visualizer/files/ui/pixel.png"
-- The wand boxes are laid out in engine-UI units (5 screen px each at
-- 2000x1125 = 0.0025 of GUI width; slots are 13u pitch / 12u frames). Box
-- HEIGHT is per-wand with a FLOOR: max(37u, 14u + 2u per wand-sprite pixel).
-- Small wands (art <= 11 px) all get the 37u minimum -- which both explains
-- why most boxes look uniform and absorbs sprite-read error for them; only
-- tall art (13/15/17 px) grows the box. Selection contributes NOTHING (the
-- old "selected box is taller" theory was a tall wand sprite in disguise).
-- Calibrated against the circled 4-wand screenshot, all rows within 1u.
-- If rows drift again: flip the "Calibration Overlay" mod setting, take one
-- screenshot -- it shows computed rows + raw sprite reads to recalibrate.
-- CAL_W: the GUI WIDTH the layout was calibrated against (slot0_x/pitch/halfw and
-- U are all fractions of THIS). Noita draws the spell inventory in FIXED GUI-unit
-- positions, but it varies the GUI *resolution* with the window/monitor while
-- always keeping it 16:9 (it letterboxes other window aspects -- verified
-- 2026-06-18: 640x480 & 1080x1024 windows -> GUI 640x360; 720x480 & 1152x864 ->
-- GUI 720x405; all report aspect 1.778). The engine's inventory positions DON'T
-- scale with that resolution, so geometry must scale by this CONSTANT, not the
-- live GUI width sw -- otherwise everything drifts (down the box stack, right
-- across columns) whenever the GUI resolution isn't 640x360. See update().
local CAL_W = 640
local U = 0.0025 -- one engine-UI unit, as a fraction of GUI width (of CAL_W)
local BOX = {
	top0    = 30,   -- units: top of wand box 1 (anchor; measure-confirmed dead-on)
	gap     = 2.5,  -- units: inter-box gap (box bottom -> next box top). A plain
	                -- constant -- ALL sprite-driven height now lives in box_h
	                -- (= row_offset + below_c, below), so there is no min_h floor
	                -- and no STEP to keep in sync; the per-box step just varies
	                -- with the sprite. tools/test_box_geometry.py guards box_h.
	-- 2026-06-17 THICKNESS MODEL (supersedes every diagonal-D law before it).
	-- Box height is driven by sprite THICKNESS (art height h in px), NOT the
	-- diagonal 0.7071*(w+h). The D-laws failed because a long-thin wand and a
	-- short-fat wand share a w+h yet render different boxes; thickness separates
	-- them. The slot-row offset is LINEAR in h, and the box bottom is a constant
	-- below_c beneath the row top, so:  row_offset = row_a + row_b*h  and
	-- box_h = row_offset + below_c, i.e. box_h = 26.9 + 1.25*h.
	-- Ground truth (sprite thickness h -> measured box_h, via box-bottom reads +
	-- "Shuffle"-row stacking checks): h7 -> 35.0/36.2u, h9 -> 38.2u, h15 ->
	-- 45.6u. Fit nails all within ~0.65u INCLUDING big wands (h15: 26.9+1.25*15
	-- = 45.6). below_c 15.6u, gap 2.5u (both re-confirmed at h15). h comes from
	-- wand_art_wh (sprite_wh_meta now stores height; GuiGetImageDimensions gives
	-- the live w/h split as fallback, so this is version-proof). Secondary: wand
	-- LENGTH adds ~0.17u/px (the two h7 wands differ ~1u) -- left out for now,
	-- add a length term + index if a wand visibly annoys (SPRITE_OVERRIDES is the
	-- escape hatch). Calibrated on h 7-15.
	row_a   = 11.3,  -- units: slot-row offset (box top -> row top) at h=0 (intercept)
	row_b   = 1.25,  -- units: row-offset growth per px of sprite thickness h
	below_c = 15.6,  -- units: box bottom sits this far below the row top (measured)
	-- Frames were thought SQUARE at 17.5 GUI, but the 2026-06-15 measure-tool
	-- probe read the slot row at 15.0 GUI tall. slot_h dropped to match; row_off
	-- raised in step so the row TOP holds at the measured box-top offset
	-- (~34 GUI = 21.1u; floor wands probed 33-35 GUI offset, slot 15 GUI tall).
	row_off = 4.0,    -- units: slot-row bottom sits this far above the box bottom;
	                  -- = base offset 35.6 GUI (box top -> slot-row top). Raised
	                  -- with the min_h drop so the row absolute position holds.
	slot_h  = 9.375,  -- units: card frame height (15.0 GUI tall)
	-- Horizontal: nailed by 8 plumb-line probes spanning columns 0..25
	-- (2026-06-09): the layout is in GUI units -- pitch exactly 20.0 GUI
	-- (62.5px), visible frame width 17.5 GUI, col-0 left edge at 26.0 GUI.
	-- All 8 probes fit within 0.15 GUI (the earlier 65px/64px estimates
	-- drifted ~1px+ per column; the "wide boxes compress" theory was false).
	slot0_x = 0.05430, -- first slot frame CENTER: (26.0 + 8.75)/640
	pitch   = 0.03125, -- slot-to-slot spacing: 20.0 GUI / 640
	halfw   = 0.01367, -- half VISIBLE frame width: 8.75 GUI / 640
	-- A box is never narrower than its header (wand sprite + the Shuffle /
	-- Spells per Cast columns): right edge >= 164.5 GUI even for a 1-slot
	-- wand (measured from a screenshot 2026-06-11 -- the panel used to dock
	-- INSIDE the starting wands' boxes). Box width = max(this, slot row).
	min_right = 0.25703, -- 164.5 GUI / 640
	-- Multi-row: the machinery below supports wands whose slot row wraps. The
	-- wrap column is now computed per-frame from the screen aspect by
	-- wrap_columns() (a capacity-26 wand is ONE row at 16:9 but wraps on
	-- narrower aspects). This per_row is only the FALLBACK passed when the
	-- aspect is >= 16:9 (99 = no wrap); row_step is still unverified -- if a
	-- real second row appears, calibrate it from the debug box / a screenshot.
	per_row  = 99,    -- fallback wrap column for >= 16:9 (99 = off; see wrap_columns)
	row_step = 13,    -- units: vertical step between slot rows (unverified)
}
local BAR_W   = 1   -- GUI width of a bracket's vertical bar
local TICK_W  = 3   -- GUI length of the top/bottom hooks at stack level 0
local STACK_X = 2   -- horizontal step between brackets stacked on one card edge
local STACK_Y = 2   -- vertical growth per stack level: outer brackets are taller,
                    -- so their hooks clear the inner bracket's
-- Stacked brackets used to fuse into one unreadable blob (reported 2026-08-07,
-- "the brackets aren't brackets"). Two causes, both fixed here:
--   * STACK_X (1.5) was SHORTER than TICK_W (3), so an outer bracket's hooks
--     were drawn straight across the bar of the bracket nested inside it --
--     and since the inner is drawn last, it painted over them. The outer then
--     rendered as a bare vertical line. Hooks now grow with the stack level
--     (TICK_W + stack*STACK_X) so every level's hooks reach the card edge and
--     stay visible as a nested staircase.
--   * STACK_Y (1) left one pixel between neighbouring levels' hooks, which
--     read as a single thick hook. 2 gives a clear gap.
-- The old values were tuned when only CLOSING brackets stacked and co-location
-- was rare; opens stack now too, and a wrapping group puts up to four glyphs on
-- one card edge, so the pile-up became the common case.
-- With the corrected 64px pitch the cell edges (center +- halfw) already sit
-- ~2px outside the visible frame, so no extra nudges are needed.
local CLOSE_NUDGE = 0 -- extra left shift of closing brackets
local OPEN_NUDGE  = 0 -- extra left shift of opening brackets
local BRACKET_RAISE = 0 -- GUI: extra lift of all bracket glyphs above the
                        -- slot row. Was 2 (tuned 2026-06-11) -- but that
                        -- tuning compensated the then-broken box geometry;
                        -- with the diagonal-bbox model placing rows
                        -- engine-exact, the user chose FLUSH (2026-06-12).
-- Fine vertical placement of the bracket glyphs relative to the calibrated slot
-- row (rows_geo top..bot, what the debug probe draws in magenta). bracket() puts
-- the top hook at `top` and the bottom hook at `bot - 1`. User-tuned in-game
-- against the engine's teal card frame (2026-06-22): EXTEND_TOP = -1 drops the
-- top hook 1px below the row top onto the frame's top edge; EXTEND_BOT = 2 sits
-- the bottom hook 1px below the row bottom for the look the user wanted. These
-- are the two tuning knobs; adjust from a screenshot.
local BRACKET_EXTEND_TOP = -1 -- GUI: bracket top relative to the row top (- = lower)
local BRACKET_EXTEND_BOT = 2  -- GUI: bracket bottom relative to the row bottom (+ = lower)
-- GUI drop of the "wraps to front" tag below the wand box's TOP border. The tag
-- lives INSIDE the box, right-aligned in the empty band beside the wand's
-- "Shuffle / Spells per cast" header -- never below the box, where it collided
-- with the border and crowded the next wand down. It is anchored to the box,
-- never to the bracket it tags -- see the note in draw_delims. Nudge this one
-- number to move it within the header band.
local WRAP_TAG_INSET = 4

local function line(gui, id, x, y, w, h, c, a)
	a = a or 1
	GuiColorSetForNextWidget(gui, c[1], c[2], c[3], a)
	GuiImage(gui, id, x, y, PIXEL, a, w, h)
end

-- One [ or ] glyph: vertical bar from top..bot plus two hooks pointing into
-- the group (dir = 1 for an opening [, -1 for a closing ]). `tw` is the hook
-- length -- it grows with the stack level so an outer bracket's hooks reach
-- past the brackets nested inside it instead of stopping short and being
-- overpainted by them (see the STACK_X note).
local function bracket(gui, idc, x, top, bot, dir, c, stack)
	local tw = TICK_W + (stack or 0) * STACK_X
	idc.n = idc.n + 1; line(gui, 70000 + idc.n, x, top, BAR_W, bot - top, c)
	local tx = (dir > 0) and x or (x - tw + BAR_W)
	idc.n = idc.n + 1; line(gui, 70000 + idc.n, tx, top, tw, 1, c)
	idc.n = idc.n + 1; line(gui, 70000 + idc.n, tx, bot - 1, tw, 1, c)
end

-- A CUT END: where a group that straddles the wand wrap is sliced, on both
-- halves. The bar plus ONE tick at mid height pointing outward (dir = the way
-- the group carries on). Deliberately not bracket-shaped: two end hooks
-- pointing outward just read as a [ or ] facing the wrong way, which is the
-- ambiguity this glyph exists to avoid. The orange carriage return leaves from
-- the bar's bottom.
-- EVERY delimiter is a real bracket -- there is no special seam glyph
-- (2026-08-07, third iteration). A straddling group's two halves each get a
-- proper [ ] pair in the group's own colour, and the orange carriage return is
-- what says they are one group. The seam was tried as a distinct glyph twice
-- and rejected both times: hooks pointing outward just read as a [ or ] facing
-- the wrong way, and a bar with a single outward tick "doesn't look like
-- brackets" -- two of them side by side read as an H, not a delimiter. The
-- brief was Lisp-style rainbow brackets; colour carries nesting, the return
-- line carries the wrap, and every glyph on the row is a bracket.

-- Collect one wand's group delimiters (all casts) for two-pass rendering.
-- Two passes because co-located brackets need the per-column TOTAL before any
-- can be placed: the INNERMOST sits on the card's edge and outer ones step
-- outward into the slot gap (inner -> outer still reads left -> right, like
-- nested parens on paper). Parents are collected before their children, so per
-- column the collection order is outer -> inner.
-- The span starts at the group's OWN card (node.head): leading modifiers sit
-- outside the parens, Lisp-style, matching the panel's "[mods] name" layout.
-- `xs` maps deck index -> real slot column (handles empty slots in the wand).
-- cols/rows map deck index -> displayed column / slot-row (multi-row wands
-- wrap their slot row every BOX.per_row slots).
--
-- Every group is ONE plain bracket pair over the run it occupies going forward
-- (head .. flast). A group that continues past the deck's end does NOT get a
-- second pair at the wand's start: the WRAP is drawn once, as a single bracket
-- enclosing the whole looping structure -- see wrap_delims.
local function collect_delims(nodes, depth, cols, rows, out)
	for _, node in ipairs(nodes) do
		-- `grouped` (wand_structure.lua) is true when the head's brackets enclose
		-- more than one card.  A RESET has no children -- nothing it cleared ran --
		-- but its bracket must still enclose exactly what it removed (node.cleared).
		local worthy = node.grouped
			or (node.kind == "reset" and node.cleared and #node.cleared > 0)
		if worthy and node.last then
			local head = node.head or node.first
			-- flast, not last: on a group that wrapped, last reaches back into
			-- the wrapped-in segment at the wand's start, and a wrap can pull in
			-- MORE cards than precede the head -- so last is not even an upper
			-- bound on the forward run. flast is the last card drawn before the
			-- wrap; it equals last on every group that didn't wrap. Same rule
			-- for a RESET node: its own wrap (the one-shot restore) always
			-- happens AFTER it finishes clearing, so a RESET that causes the
			-- wrap still has flast == last (nothing it cleared was wrapped-in);
			-- a RESET that clears cards already in a wrapped-in segment (a
			-- second RESET in an already-wrapped cast) instead gets flast <
			-- last, and those wrapped-in cleared cards are left to the wrap's
			-- own enclosure (wrap_delims) rather than double-bracketed here.
			local tail = node.flast or node.last
			-- Brackets carry NO text labels (user calls, 2026-06-11): the
			-- card art already says x2/x3, a trigger's payload shows as the
			-- nested bracket, and the labels collided ("trig 1x3"). Only
			-- the orange "wraps to front" tag remains.
			out[#out + 1] = {
				ca = cols[head] or (head - 1), -- 0-based slot columns
				cb = cols[tail] or (tail - 1),
				ra = rows[head] or 0,          -- 0-based slot rows
				rb = rows[tail] or 0,
				c = nest_color(depth),
			}
			if node.children and #node.children > 0 then
				collect_delims(node.children, depth + 1, cols, rows, out)
			end
		end
	end
end

-- The WRAP, as one enclosing bracket (user call 2026-08-07):
--
--     [ chainsaw, chainsaw, [Double, Spitter [Double, Spitter]] ]
--     ^ the wrap                                                ^ closing wrap
--
-- A wrap always pulls from the wand's START and the wrapping cast always runs
-- to the deck's END, so everything involved lies in one contiguous run from the
-- first wrapped-in card to the cast's last forward card -- one bracket around
-- the lot, outside every group it contains. That replaces the two-halves-plus-
-- carriage-return drawing: three attempts at splitting a group across the seam
-- were all rejected in play (see bracket), and the loop reads as an enclosure
-- rather than as a cut. Drawn in WRAP_COLOR, the one non-rainbow delimiter:
-- it is not a nesting level, it is the wrap itself.
local function wrap_delims(cast, cols, rows, out)
	if not (cast.wfirst and cast.last) then return nil end
	local rec = {
		ca = cols[cast.wfirst] or (cast.wfirst - 1),
		cb = cols[cast.last] or (cast.last - 1),
		ra = rows[cast.wfirst] or 0,
		rb = rows[cast.last] or 0,
		c = WRAP_COLOR,
		wrap = true, -- carries the "wraps to front" label on its closing bracket
	}
	out[#out + 1] = rec
	return rec
end

-- The CAST's own delimiter: the cards that fire simultaneously, delimited one
-- level OUTSIDE the spell groups they contain. The rainbow is one continuous
-- progression across both axes (user call 2026-08-07) -- each cast advances it
-- by one and so does each nesting level inside a group -- so cast `ci` (1-based)
-- sits at depth ci-1 and its groups start at depth ci. Like a group, a cast is
-- bracketed over its FORWARD run only; the wrap gets its own enclosure.
local function collect_cast_delims(cast, ci, cols, rows, out)
	if not (cast.first and cast.last) then return nil end
	local rec = {
		ca = cols[cast.first] or (cast.first - 1),
		cb = cols[cast.last] or (cast.last - 1),
		ra = rows[cast.first] or 0,
		rb = rows[cast.last] or 0,
		c = nest_color(ci - 1),
	}
	out[#out + 1] = rec
	return rec
end

-- Every delimiter for one wand, all casts together (their glyphs stack per
-- row+column+side, so they must be planned as one list). cols/rows map deck
-- index -> displayed slot column / slot row.
local function collect_wand_delims(sim, cols, rows)
	-- Delimit the casts themselves only when there is more than one, or when
	-- the wand wraps -- the same rule the panel uses for its cast headers
	-- (sim_rows). A wand that empties in a single cast would learn nothing from
	-- a bracket around its whole slot row, and this keeps those wands rendering
	-- exactly as they did before casts were delimited: groups stay at depth 0.
	local show_casts = (#sim.casts > 1) or sim.wrapped
	-- The wrap encloses the WHOLE looping structure -- including casts that ran
	-- before the one that wrapped -- so its record has to come before every
	-- other record, not just before its own cast's. Collection order IS nesting
	-- order for the stacking pass, and the wrapping cast is always the last one.
	local wraps, out = {}, {}
	for ci, cast in ipairs(sim.casts) do
		wrap_delims(cast, cols, rows, wraps)
		local cast_rec = #out + 1
		local rec = show_casts
			and collect_cast_delims(cast, ci, cols, rows, out) or nil
		-- the cast sits at depth ci-1, so its groups continue the rainbow at ci
		collect_delims(cast.nodes, show_casts and ci or 0, cols, rows, out)
		-- A cast that fires ONE spell expression has no simultaneity to show,
		-- so its bracket is pure ink -- drop it (user call 2026-08-07). This is
		-- also what kills the redundant pair on a cast whose single spell IS a
		-- group: the two spans were identical, drawn twice in two colors.
		-- `#cast.nodes <= 1` also catches `#cast.nodes == 0`: a cast whose every
		-- draw hit a depleted card (T1.6/T1.7's `spent`-only cast) still has a
		-- real cast.first/last span -- it popped cards -- but no node built from
		-- it, so there is nothing to bracket either. Intentional, not an
		-- accident of the `<= 1`: an empty cast draws no cast bracket.
		if rec and #cast.nodes <= 1 then
			table.remove(out, cast_rec)
		end
	end
	for _, r in ipairs(out) do wraps[#wraps + 1] = r end
	return wraps
end

-- rows_geo[r+1] = { top, bot } for displayed slot-row r (0-based): brackets
-- anchor to the row their card actually sits on.
-- refw is the GEOMETRY reference width = the CONSTANT CAL_W (640), NOT the live
-- GUI width sw. The engine draws the inventory in fixed GUI-unit positions
-- calibrated at CAL_W; Noita varies the GUI RESOLUTION (640x360, 720x405, ...,
-- always 16:9) but those positions don't scale with it, so scaling by live sw
-- drifts the brackets off the cards whenever GUI res != 640x360. refw == sw at
-- GUI 640x360. See update(); tools/test_gui_scale_geometry.py.
--
-- ---- glyph planning (pure: no Gui, no pixels) -------------------------------
--
-- Turn the collected groups into a flat list of bracket GLYPHS plus the wrap
-- connectors that join a straddling group's two halves. Each glyph is
--   { col, row, side = "left"|"right", seam = true?, c = color, stack = N }
-- and each connector is { from = <glyph i>, to = <glyph i> }.
-- `seam` marks the two glyphs a wrap's carriage return attaches to. It no
-- longer changes how the glyph is DRAWN (every delimiter is a plain bracket);
-- it stays because it is what the connector and the tests identify.
--
-- ONE GROUP IS ONE BRACKET PAIR, always in that group's rainbow color. A group
-- gets exactly TWO -- there is no split, no seam and no carriage return:
--
--     [ chainsaw, chainsaw, [Double, Spitter [Double, Spitter]] ]
--                                                               ^ wraps to front
--
-- The outer bracket is the WRAP (WRAP_COLOR, from wrap_delims); everything
-- inside is an ordinary rainbow group over its forward run. Orange marks the
-- wrap, the rainbow marks nesting.
--
-- Stacking runs per (row, column, side) so co-located glyphs never overprint:
-- the outermost steps furthest from the card and grows tallest, its hooks
-- wrapping around the inner ones. Both sides stack -- opens used not to, which
-- let the wrap enclosure's [ land exactly on top of a group opening on the same
-- column. Records arrive outer -> inner (wrap, then cast, then groups
-- parents-before-children), which is the order the stacking keys off.
local function plan_delims(groups)
	local glyphs = {}
	local function add(col, row, side, c, wrap, label)
		glyphs[#glyphs + 1] = { col = col, row = row, side = side,
			c = c, wrap = wrap, label = label, stack = 0 }
		return #glyphs
	end
	for _, g in ipairs(groups) do
		add(g.ca, g.ra, "left", g.c, g.wrap)
		-- the wrap's CLOSING bracket carries the tag: it is the point the
		-- structure loops back from
		add(g.cb, g.rb, "right", g.c, g.wrap, g.wrap and "wraps to front" or nil)
	end
	local counts, seen = {}, {}
	local function key(gl) return gl.row .. ":" .. gl.col .. ":" .. gl.side end
	for _, gl in ipairs(glyphs) do counts[key(gl)] = (counts[key(gl)] or 0) + 1 end
	for _, gl in ipairs(glyphs) do
		local k = key(gl)
		local s = seen[k] or 0
		seen[k] = s + 1
		gl.stack = counts[k] - 1 - s -- 0 = innermost (collected last)
	end
	return glyphs
end

-- ---- slot marks: underlines and strike-throughs (planned by slot_marks.lua) ---

local MARK_UNDERLINE_DROP = 2  -- GUI below the bracket hooks' bottom edge; keeps the line
                               -- clear of the level-0 hooks it would otherwise touch
local MARK_INSET = 1           -- GUI trimmed off each end, so neighbouring chains stay apart
local STRIKE_COLOR = { 1.00, 0.30, 0.30 }
-- "copied" dots: small, one per KIND of copier, each kind in its own colour so
-- a card copied by Alpha and Gamma shows two distinguishable dots.  The Greek
-- letters and Double Spell have fixed colours; a modded copier gets the next
-- free one from COPY_SPARE, by its id, so the colour is stable between frames.
local COPY_COLORS = {
	ALPHA     = { 0.40, 0.90, 0.90 },
	GAMMA     = { 1.00, 0.80, 0.30 },
	TAU       = { 0.95, 0.50, 0.95 },
	OMEGA     = { 1.00, 0.45, 0.45 },
	PHI       = { 0.50, 0.65, 1.00 },
	MU        = { 0.55, 0.95, 0.45 },
	SIGMA     = { 1.00, 0.68, 0.28 },
	DUPLICATE = { 0.90, 0.90, 0.90 },
}
local COPY_SPARE = { { 0.70, 0.55, 1.00 }, { 0.30, 0.80, 0.60 }, { 0.95, 0.60, 0.60 } }
local COPY_DOT      = 2    -- GUI px, square
local COPY_DOT_GAP  = 2

local function copy_color(id)
	if COPY_COLORS[id] then return COPY_COLORS[id] end
	local sum = 0
	for i = 1, #id do sum = sum + id:byte(i) end
	return COPY_SPARE[sum % #COPY_SPARE + 1]
end

-- Draw what slot_marks.collect planned.  Only geometry lives here: which cards
-- get a mark, and why, is decided in slot_marks.lua.
local function draw_marks(gui, marks, refw, rows_geo, idc)
	local function left_of(col) return refw * (BOX.slot0_x + col * BOX.pitch - BOX.halfw) end
	local function right_of(col) return refw * (BOX.slot0_x + col * BOX.pitch + BOX.halfw) end
	for _, mark in ipairs(marks) do
		local yr = rows_geo[mark.row + 1] or rows_geo[1]
		idc.n = idc.n + 1
		if mark.kind == "underline" then
			local x1, x2 = left_of(mark.ca) + MARK_INSET, right_of(mark.cb) - MARK_INSET
			local y = yr.bot + BRACKET_EXTEND_BOT + MARK_UNDERLINE_DROP
			line(gui, 72000 + idc.n, x1, y, x2 - x1, 1, COLOR.MODIFIER, 0.9)
		elseif mark.kind == "strike" then
			local x1, x2 = left_of(mark.col) + MARK_INSET + 2, right_of(mark.col) - MARK_INSET - 2
			line(gui, 72000 + idc.n, x1, (yr.top + yr.bot) / 2, x2 - x1, 1, STRIKE_COLOR, 0.9)
		elseif mark.kind == "copied" then
			-- a centred row of dots just above the card's top edge, one per copier kind
			local dots = #mark.by
			local width = dots * COPY_DOT + (dots - 1) * COPY_DOT_GAP
			local centre = (left_of(mark.col) + right_of(mark.col)) / 2
			for d, id in ipairs(mark.by) do
				idc.n = idc.n + 1
				line(gui, 72000 + idc.n, centre - width / 2 + (d - 1) * (COPY_DOT + COPY_DOT_GAP),
					yr.top - COPY_DOT - 1, COPY_DOT, COPY_DOT, copy_color(id), 0.95)
			end
		end
	end
end

-- box_right / box_top = the wand box's right and top edges (GUI). They place
-- the "wraps to front" tag, which is anchored to the BOX rather than to the
-- bracket it tags -- see the note at the tag below.
local function draw_delims(gui, groups, refw, rows_geo, idc, box_right, box_top)
	local glyphs = plan_delims(groups)

	for _, gl in ipairs(glyphs) do
		local yr = rows_geo[gl.row + 1] or rows_geo[1]
		local grow = gl.stack * STACK_Y
		if gl.side == "left" then
			-- opens sit just left of the card and step LEFT into the slot gap
			gl.x = refw * (BOX.slot0_x + gl.col * BOX.pitch - BOX.halfw)
				- OPEN_NUDGE - gl.stack * STACK_X
		else
			-- closes sit ON the card's right edge and step RIGHT into the slot
			-- gap -- they never push into the card art (user call 2026-06-11)
			gl.x = refw * (BOX.slot0_x + gl.col * BOX.pitch + BOX.halfw)
				- BAR_W - CLOSE_NUDGE + gl.stack * STACK_X
		end
		gl.top = yr.top - grow - BRACKET_RAISE - BRACKET_EXTEND_TOP
		gl.bot = yr.bot + grow - BRACKET_RAISE + BRACKET_EXTEND_BOT
		-- hooks always point INTO the span the bracket delimits
		local into = (gl.side == "left") and 1 or -1
		bracket(gui, idc, gl.x, gl.top, gl.bot, into, gl.c, gl.stack)

		-- "wraps to front" tags the wrap enclosure -- the point the structure
		-- loops back from. (Not "~wrap": Noita's font renders ~ as a double
		-- quote.) It is anchored to the BOX, NOT to the bracket it tags, and so
		-- holds still no matter what the brackets do.
		--
		-- Hanging it off the glyph (gl.x / gl.bot) is what it used to do, and
		-- that drifts: a wrap enclosure is the OUTERMOST delimiter on its
		-- column, so it always carries the deepest stack on the wand, and stack
		-- pushes a glyph both right (STACK_X) and down (STACK_Y). The more
		-- nesting a wand had, the further the tag slid -- down onto the box's
		-- bottom border where it was unreadable, and right until the box_right
		-- clamp caught it. Two variables the reader cannot see moved the one
		-- piece of text on the row that has to be legible.
		--
		-- It now sits INSIDE the box, right-aligned in the empty band beside
		-- the wand's "Shuffle / Spells per cast" header. Nothing about the
		-- bracket enters the placement. Below the box -- where it used to end
		-- up -- is not the wand's space at all: it is the gap before the next
		-- wand box, so the tag read as belonging to the wrong wand and landed
		-- on a border. There is no room under the slot row either (the box
		-- bottom is only ~3 units below it, less than the text is tall), so
		-- the header band is the one place inside the box that fits it.
		-- This costs nothing in meaning: the wrapping cast always runs to the
		-- deck's END (see wrap_delims), so the closing bracket is at the row's
		-- right end and the tag sits directly above it.
		if gl.label then
			-- raw engine call, not text_dims: that lives further down the file
			-- with the panel's font-safety helpers. A font that measures
			-- degenerately (docs/FONT_COMPAT.md) falls back to an estimate
			-- rather than collapsing the tag onto the left edge.
			local ok, tw = pcall(GuiGetTextDimensions, gui, gl.label, 1)
			tw = (ok and tonumber(tw)) or 0
			if tw <= 0 then tw = 5 * #gl.label end
			local lx2 = box_right and (box_right - tw - 2) or (gl.x + TICK_W + 2)
			if lx2 < 2 then lx2 = 2 end
			-- inside the box's header band when we know where the box starts;
			-- otherwise the old row-relative drop, but pinned at stack 0 so it
			-- still cannot drift.
			local ly = box_top and (box_top + WRAP_TAG_INSET)
				or (yr.bot + BRACKET_EXTEND_BOT - BRACKET_RAISE - 3)
			GuiColorSetForNextWidget(gui, gl.c[1], gl.c[2], gl.c[3], 1)
			GuiText(gui, lx2, ly, gl.label)
		end
	end
end

-- Read this wand's art WIDTH+HEIGHT in px (drives the diagonal-bbox box
-- model; vanilla art is 3..29 px a side). Vanilla paths resolve through the
-- PREGENERATED table (wand_sprite_meta.lua); the live GuiGetImageDimensions
-- read is the fallback for modded wands. The starting wands' image_file is
-- a sprite XML (handgun.xml) -- the table carries those too
-- (frame_width+frame_height). A failed read returns 18 (handgun-sized:
-- comfortably below the floor threshold, like most wands).
-- Per-sprite geometry overrides (reactive escape hatch). A few wands don't fit
-- the diagonal box-height law: the custom sprites (bomb_wand, scepter, skull,
-- ...) and the occasional big procedural wand. When a wand's brackets sit wrong,
-- enable Debug Info and measure two things with the middle-click tool, reading
-- the "(N.NNu)" UNIT value (not the GUI px):
--   box_h   = box outline height  (panel top border -> bottom border)
--   row_top = header offset       (panel top border -> slot-row top)
-- then add an entry keyed by the sprite's image_file path. Overrides win over
-- the computed model; box height stays position-independent, so one entry fixes
-- that wand in every slot. (For reference: a floor wand is box_h ~35.6,
-- row_top ~22.2.) Leave empty until a specific wand actually misbehaves.
local SPRITE_OVERRIDES = {
	-- Starter wands (seen every run) draw an XML sprite with offset_y=3, so the
	-- slot row sits ~0.6u lower than the thickness model predicts. gen_wand_sprite_meta
	-- now keys these on png height (h=8) which nails box_h; these measured values
	-- (middle-click, 2026-06-19: box top->bottom = 36.9u, box top->row top = 21.9u)
	-- also pin the row exactly. Same sprite on both starters -> identical numbers.
	["data/items_gfx/handgun.xml"]   = { box_h = 36.9, row_top = 21.9 },
	["data/items_gfx/bomb_wand.xml"] = { box_h = 36.9, row_top = 21.9 },
}

-- Returns the wand art's w+h (drives the box-height model) AND its sprite path
-- (used to look up SPRITE_OVERRIDES). Path is nil when unreadable.
-- Returns the wand sprite's art HEIGHT (thickness, px) and its image path.
-- Box height is driven by thickness, not the diagonal -- sprite_wh_meta now
-- stores h (see gen_wand_sprite_meta.py). GuiGetImageDimensions returns w AND h
-- separately, so the live fallback stays correct even if a sprite changed.
local function wand_art_wh(gui, wand)
	local sc = EntityGetFirstComponentIncludingDisabled(wand, "SpriteComponent")
	if sc then
		local ok, f = pcall(ComponentGetValue2, sc, "image_file")
		if ok and type(f) == "string" and f ~= "" then
			if sprite_wh_meta[f] then return sprite_wh_meta[f], f end
			local ok2, w, h = pcall(GuiGetImageDimensions, gui, f, 1)
			if ok2 and tonumber(w) and tonumber(h)
				and w > 0 and w < 30 and h > 0 and h < 30 then
				return h, f
			end
		end
	end
	-- image_file unreadable or unknown: vanilla wands carry the same art
	-- path on their AbilityComponent (SetWandSprite sets both)
	local ab = EntityGetFirstComponentIncludingDisabled(wand, "AbilityComponent")
	if ab then
		local ok, f = pcall(ComponentGetValue2, ab, "sprite_file")
		if ok and type(f) == "string" and sprite_wh_meta[f] then
			return sprite_wh_meta[f], f
		end
	end
	return 9, nil  -- fallback: typical wand thickness (px)
end

-- Measure every carried wand's box (quick-slot order): the stacking model plus
-- each wand's deck, config, sprite and slot-row geometry. One shared pass --
-- the slot brackets render from it, and the panel docks against it (the
-- selected wand's box top + the stack's bottom/right extents).
-- Returns wands, stack bottom (GUI y) and stack right edge (GUI x).
-- Self-calibrating wrap column (2026-06-15). Noita keeps the GUI HEIGHT fixed
-- and grows WIDTH with the screen aspect, laying out spell slots in absolute GUI
-- units -- so an aspect NARROWER than 16:9 fits fewer slots per row before the
-- engine wraps the row. Our slot geometry (slot0_x/pitch/halfw) is a fraction of
-- width measured at 16:9; converting "columns that fit" to the live aspect needs
-- only the RATIO aspect/CAL_ASPECT -- not the absolute GUI width (which the
-- debug box reports, but we never have to assume).
--   16:9 and WIDER  -> keep the shipped no-wrap behavior (return 99): the
--                      released 16:9 build is validated and wider only adds room.
--   NARROWER        -> compute the wrap column so the brackets follow the row.
-- WRAP_EDGE is the fraction of the live width the engine wraps at (~1 = right
-- screen edge). If a narrow-aspect screenshot shows the wrap one column off,
-- nudge WRAP_EDGE (aspect + observed wrap column are both in the debug box).
local CAL_ASPECT = 16 / 9
local WRAP_EDGE  = 1.0
local function wrap_columns(sw, sh)
	local aspect = (sh > 0) and (sw / sh) or CAL_ASPECT
	if aspect >= CAL_ASPECT - 0.01 then return 99 end
	local c_max = math.floor(
		(WRAP_EDGE * aspect / CAL_ASPECT - BOX.slot0_x - BOX.halfw) / BOX.pitch)
	return math.max(1, c_max + 1)
end

-- sw param is the GEOMETRY reference width (refw = sh*CAL_ASPECT), not live
-- screen width -- everything here is layout. See draw_delims / update().
local function collect_wand_boxes(gui, refw, per_row, ignore_depleted)
	local players = EntityGetWithTag("player_unit")
	if not players or #players == 0 then return {}, BOX.top0 * U * refw, 0 end
	local items = GameGetAllInventoryItems(players[1]) or {}

	local wands = {}
	for _, it in ipairs(items) do
		if EntityHasTag(it, "wand") then
			local sx = 0
			local ic = EntityGetFirstComponentIncludingDisabled(it, "ItemComponent")
			if ic then sx = ComponentGetValue2(ic, "inventory_slot") or 0 end
			wands[#wands + 1] = { e = it, slot = sx }
		end
	end
	table.sort(wands, function(p, q) return p.slot < q.slot end)

	local box_top = BOX.top0 -- units; boxes stack, each as tall as its wand needs
	for _, wd in ipairs(wands) do
		wd.tokens, wd.always, wd.xs, wd.uses = read_deck(wd.e, ignore_depleted)
		wd.cfg = read_config(wd.e)
		wd.h, wd.sprite = wand_art_wh(gui, wd.e)
		-- ignore_depleted (default on) is the "model the engine" setting: ON
		-- hands the live charge counts to the engine, which retries past a
		-- depleted card exactly as gun.lua does; OFF omits `uses` entirely and
		-- every card is simulated as though it fires.
		if sim_cache then
			wd.sim = sim_cache.get({ tokens = wd.tokens, always = wd.always,
				spells_per_cast = wd.cfg.spells_per_cast, shuffle = wd.cfg.shuffle,
				uses = ignore_depleted and wd.uses or nil })
		else
			wd.sim = { casts = {}, error = engine_error or "engine not ready" }
		end
		wd.uncertain_ids = wand_structure.uncertain_ids(wd.sim)
		-- A wand is "uncertain" when a CARD on it depended on a guess.  A guess made
		-- by the cast machinery outside any card (sim.uncertain, shown in the debug
		-- box) says nothing about this wand's structure, so it does not count.
		wd.uncertain = #wd.uncertain_ids > 0

		-- displayed slot rows: capacity wraps every per_row slots (fall back
		-- to the highest occupied slot if the capacity read failed). per_row is
		-- the aspect-calibrated wrap column (wrap_columns); stamped on the box so
		-- the brackets and the debug readout use the same value.
		wd.per_row = per_row
		local max_slot = wd.cfg.capacity - 1
		for _, x in ipairs(wd.xs) do if x > max_slot then max_slot = x end end
		wd.nrows = math.max(1, math.floor(max_slot / per_row) + 1)

		-- Both the slot-row offset AND the box height grow LINEARLY with the
		-- sprite THICKNESS (art height h): row_offset = row_a + row_b*h, and the
		-- box bottom is a constant below_c beneath the row top, so box_h =
		-- row_offset + below_c (no floor; see the BOX comments). Getting box_h
		-- right is what stops the downward stacking cascade.
		-- Extra rows of a multi-row wand (per_row, frozen feature) stack DOWN.
		-- A per-sprite override wins over the model (SPRITE_OVERRIDES).
		local ov = wd.sprite and SPRITE_OVERRIDES[wd.sprite]
		local row_offset = (ov and ov.row_top) or (BOX.row_a + BOX.row_b * wd.h)
		wd.box_h = ((ov and ov.box_h) or (row_offset + BOX.below_c))
			+ (wd.nrows - 1) * BOX.row_step
		wd.top = box_top
		local row_top_u = box_top + row_offset
		wd.rows_geo = {}
		for r = 0, wd.nrows - 1 do
			local top = (row_top_u + r * BOX.row_step) * U * refw
			wd.rows_geo[r + 1] = { top = top, bot = top + BOX.slot_h * U * refw }
		end

		-- box right edge (GUI): the wider of the box's minimum (header-
		-- driven, BOX.min_right) and the slot row (last slot's frame edge
		-- + ~5 GUI of border; col-0 frame left sits at 26 GUI, box at ~21)
		wd.right = refw * BOX.min_right
		if max_slot >= 0 then
			local last_col = math.min(max_slot, per_row - 1)
			wd.right = math.max(wd.right,
				refw * (BOX.slot0_x + last_col * BOX.pitch + BOX.halfw) + 5)
		end

		box_top = box_top + wd.box_h + BOX.gap
	end
	return wands, box_top * U * refw
end

-- Delimit each measured wand box's spell row.
-- (The "Calibration Overlay" debug HUD that used to live here -- rulers,
-- plumb lines, click probes, per-box readouts -- was removed for the
-- Workshop release. It lives in git history; re-add it together with its
-- settings.lua entry if the box geometry ever drifts after a game update.)
-- Row-calibration probe, now gated behind the show_debug setting (was a
-- hardcoded constant that shipped =true by accident). Draws the MODEL's
-- computed slot-row top/bottom as 1-GUI magenta lines across every wand box +
-- the wand's art wh / diagonal D. A screenshot of N varied wands gives N exact
-- (D, row-error) samples to refit the box-height law -- which is exactly what's
-- needed when a long/tall wand throws off the stack below it.
local function draw_row_probe(gui, refw, wands)
	for _, wd in ipairs(wands) do
		local r = wd.rows_geo[1]
		-- MAGENTA: the model's estimated slot-ROW top/bottom (bracket position).
		GuiColorSetForNextWidget(gui, 1, 0.2, 1, 0.9)
		GuiImage(gui, 90001 + wd.slot * 10, 21, r.top, PIXEL, 0.9, wd.right - 21, 1)
		GuiColorSetForNextWidget(gui, 1, 0.2, 1, 0.9)
		GuiImage(gui, 90002 + wd.slot * 10, 21, r.bot, PIXEL, 0.9, wd.right - 21, 1)
		-- CYAN: the model's estimated BOX top/bottom edges. Compare each to the
		-- engine's actual box outline -- the vertical gap is this box's stacking
		-- error (what drives the cascade). Read it (or Measure it) and report
		-- per box; the label prints the model's box top + height in UNITS.
		local box_top = wd.top * U * refw
		local box_bot = (wd.top + wd.box_h) * U * refw
		GuiColorSetForNextWidget(gui, 0.2, 1, 1, 0.9)
		GuiImage(gui, 90003 + wd.slot * 10, 21, box_top, PIXEL, 0.9, wd.right - 21, 1)
		GuiColorSetForNextWidget(gui, 0.2, 1, 1, 0.9)
		GuiImage(gui, 90004 + wd.slot * 10, 21, box_bot, PIXEL, 0.9, wd.right - 21, 1)
		GuiColorSetForNextWidget(gui, 0.2, 1, 1, 1)
		-- th = sprite THICKNESS (art height px) -- the box-height driver; box_h =
		-- 26.9 + 1.25*th. The sprite basename lets one screenshot tie each box to
		-- its exact art for calibration.
		local spr = wd.sprite and wd.sprite:match("([^/]+)%.[^.]+$") or "?"
		GuiText(gui, wd.right + 4, box_top - 4,
			string.format("th=%d  box top=%.1fu  h=%.1fu  row+%.1fu  [%s]",
				wd.h, wd.top, wd.box_h, r.top / (U * refw) - wd.top, spr))
	end
end

-- Track C's "no brackets" policy, drawn: a single dim "?" at the right end of
-- the slot row, in place of the (withheld) brackets, so a blank row reads as
-- "uncertain", not "broken". Same raw GuiText primitive draw_delims already
-- uses for its "wraps to front" tag text -- no new drawing path -- dimmed
-- with COLOR.OTHER, the same grey the panel's tier footnote uses.
-- Placed like the "wraps to front" tag: right-aligned in the box's header band
-- beside "Shuffle / Spells per cast", NOT on the slot row -- at the row's
-- right end it sat on top of the last card (first in-game run of 1.4.0).
local UNCERTAIN_TAG = "? uncertain"
local function draw_uncertain_glyph(gui, wd, refw)
	if not wd.rows_geo[1] then return end
	local ok, tw = pcall(GuiGetTextDimensions, gui, UNCERTAIN_TAG, 1)
	tw = (ok and tonumber(tw)) or 0
	if tw <= 0 then tw = 5 * #UNCERTAIN_TAG end
	local lx = wd.right - tw - 2
	if lx < 2 then lx = 2 end
	local ly = wd.top * U * refw + WRAP_TAG_INSET
	GuiColorSetForNextWidget(gui, COLOR.OTHER[1], COLOR.OTHER[2], COLOR.OTHER[3], 1)
	GuiText(gui, lx, ly, UNCERTAIN_TAG)
end

-- `uncertain` is the uncertain_brackets setting ("hide"/"show"). Brackets are
-- withheld from a wand whose structure depended on a guess unless the setting
-- is "show" -- Track C, docs/ADVANCED_SCENARIOS_PLAN.md 2.
local function draw_box_brackets(gui, refw, wands, show_probe, uncertain, show_marks)
	local idc = { n = 0 }
	if show_probe then draw_row_probe(gui, refw, wands) end
	for _, wd in ipairs(wands) do
		-- Shuffle wands get NO brackets (user call 2026-06-11): the deck
		-- order randomizes at cast time, so slot-order grouping painted on
		-- the cards would assert a structure the wand won't honor. The
		-- panel still shows the slot-order tree WITH its "order varies!"
		-- warning -- text can hedge, brackets can't.
		if #wd.tokens > 0 and not wd.cfg.shuffle then
			if not wd.uncertain or uncertain == "show" then
				-- displayed position of each card: wraps every per_row slots
				local cols, rows = {}, {}
				for k, x in ipairs(wd.xs) do
					cols[k] = x % wd.per_row
					rows[k] = math.floor(x / wd.per_row)
				end
				draw_delims(gui, collect_wand_delims(wd.sim, cols, rows),
					refw, wd.rows_geo, idc, wd.right, wd.top * U * refw)
				if show_marks ~= false then
					draw_marks(gui, slot_marks.collect(wd.sim, cols, rows),
						refw, wd.rows_geo, idc)
				end
			else
				draw_uncertain_glyph(gui, wd, refw)
			end
		end
	end
end

-- ---- companion structure panel (docked to the selected wand) ----------------

-- The panel describes the HELD wand (= the selected box), so it stays put
-- while the user rearranges that wand's spells and live-updates as the cast
-- order changes -- no popping like a hover tooltip would.
--
-- SIZE.  A fixed, comfortable width that does not depend on the wand: a big wand
-- has a wide box, and sizing the panel from what is left of the screen made it
-- shrink exactly when a long structure needed room.  It may now overlap the
-- wand box; hiding it (click its title, or Home) is how the slots are
-- uncovered.  HEIGHT: a short structure pins at the selected wand's height, a
-- long one takes the full column under the HP/mana bars, and a structure
-- taller than that SCROLLS (PageUp / PageDown, or click the scroll bar) instead
-- of being folded into a "+N more" line.
--
-- It never needs the mouse to be readable, and its gui is NonInteractive so
-- hovering it can never block firing or inventory clicks (see the fire-block
-- fix); clicks are read from the raw pointer instead.
local RIGHT_MARGIN    = 3    -- GUI kept clear at the right screen edge
local TOP_BAR_KEEPOUT = 58   -- panel top stays below the HP/mana/gold bars
local BOTTOM_MARGIN   = 12   -- GUI kept clear at the screen bottom
local PANEL_W_BASE    = 260  -- GUI: the panel's width at the default 0.6 text scale
local PANEL_W_MIN     = 180  -- never narrower than this, whatever the screen
local PANEL_W_MAX_FRAC = 0.45 -- ...nor wider than this share of the screen
local SCROLLBAR_W     = 2    -- GUI, the scroll bar's width
local SCROLLBAR_GAP   = 3    -- GUI between the text column and the bar
local PANEL_BG_Z      = -20  -- lower z = front; beats the slot brackets (z -10)
local PANEL_TEXT_Z    = -21  -- one layer in front of the panel background
-- Debug overlays (readout box, measure tool) must sit in FRONT of the cast panel
-- (z -20/-21) -- lower z = front, so these go lower still. They used to draw at
-- z -7/-8, BEHIND the panel, so the readout hid behind it (user 2026-06-22).
local DEBUG_BG_Z      = -22  -- debug readout background, in front of the panel
local DEBUG_TEXT_Z    = -23  -- debug text + measure overlay, frontmost

-- ---- font-metric safety -----------------------------------------------------
--
-- Workshop reports (2026-07-24..26): the panel renders "compressed and smaller
-- than it should", pushed against the right screen edge, barely readable --
-- with the "Better Font (English)" font mod (Workshop id 2098567286) and
-- equally with the default fonts of the non-pixelated languages (Japanese and
-- so on). The common factor is a NON-PIXEL UI font.
--
-- ROOT CAUSE, measured in-game against Better Font (docs/FONT_COMPAT.md has the
-- screenshots and the arithmetic): under a non-pixel font, FRACTIONAL `scale`
-- IS BROKEN IN BOTH DIRECTIONS, and the two directions disagree --
--
--   * GuiText(gui, x, y, t, scale) IGNORES scale and draws at ~1.0.
--   * GuiGetTextDimensions(gui, t, scale) shrinks SUB-LINEARLY. The mod's own
--     font probe reports "MWli0 |[]" as 31.5 x 12.5 at scale 1.0 but only
--     11.1 x 5.0 at scale 0.6 -- ratios of 0.352 and 0.400, not 0.6.
--
-- So a panel measured at 0.6 gets text painted ~2.8x too big for it. The panel
-- is right-anchored and grows LEFTWARD from sw - RIGHT_MARGIN, so the overflow
-- runs off the right screen edge instead of moving the panel, and line_h taken
-- from the shrunken measured height stacks the rows together. Measured at GUI
-- 640x360: Tiny gave a 63.7-GUI panel with labels running off-screen; Large
-- gave 142.1 GUI with every label inside the box.
--
-- At scale 1.0 measurement and rendering agree exactly (the debug box is drawn
-- at 1.0 and fits its own text to within 4 GUI), so 1.0 is the ONLY safe scale
-- under such a font. faithful_scale() below detects the breakage from the
-- engine's own numbers -- no font sniffing -- and clamps to 1.0.
--
-- The floors below are NOT the fix for that bug; they are a much narrower guard
-- against a font that measures degenerately (0/nil), which would otherwise
-- divide the layout by zero. They sit BELOW everything the vanilla pixel font
-- returns (mean letter advance 4.94 GUI at scale 1; only "i l . : ; '" are as
-- narrow as 2), so they stay inert in the shipped configuration.
local CHAR_W_FLOOR = 3 -- GUI advance per character at scale 1, lower bound
local CHAR_H_FLOOR = 6 -- GUI text height at scale 1, lower bound

-- Mixed-width probe (wide + narrow + digit + punctuation) used to ask the
-- engine whether it honours fractional scale. Also printed raw in the debug box.
local SCALE_PROBE = "MWli0 |[]"

-- How far the measured shrink may drift from the requested scale before we
-- stop trusting fractional scale at all. The vanilla pixel font is a pure
-- multiply (ratio == scale to within float noise); Better Font came in at
-- 0.352 against a requested 0.6, i.e. 41% low. 15% relative separates them
-- with room to spare in both directions.
local SCALE_TOLERANCE = 0.15

-- Spell names come from GameTextGet and can be UTF-8 (Japanese etc.), so #s
-- counts bytes, not characters. Count characters = non-continuation bytes.
local function utf8_chars(s)
	local n = 0
	for i = 1, #s do
		local b = s:byte(i)
		if b < 0x80 or b >= 0xC0 then n = n + 1 end
	end
	return n
end

-- Drop the last CHARACTER (not byte: byte-trimming split multi-byte glyphs
-- and fed GuiText invalid UTF-8 on localized names).
local function trim_last_char(s)
	local i = #s
	while i > 1 and s:byte(i) >= 0x80 and s:byte(i) < 0xC0 do i = i - 1 end
	return s:sub(1, i - 1)
end

-- GuiGetTextDimensions with the collapse floors applied. All panel sizing
-- goes through here; the raw engine reading is still surfaced verbatim in the
-- debug info box so bug reports show what the active font really measures.
local function text_dims(gui, text, scale)
	scale = scale or 1
	local w, h = GuiGetTextDimensions(gui, text, scale)
	w, h = tonumber(w) or 0, tonumber(h) or 0
	local wf = CHAR_W_FLOOR * utf8_chars(text) * scale
	if w < wf then w = wf end
	local hf = CHAR_H_FLOOR * scale
	if h < hf then h = hf end
	return w, h
end

-- The scale we can actually lay out at. Asks the engine to measure one probe
-- string at 1.0 and at `scale`: if the reported width does not shrink by
-- roughly `scale`, the active font cannot do fractional scale (GuiText will
-- draw it at ~1.0 regardless), and every panel dimension derived at `scale`
-- would be too small for the text that lands on screen -- so fall back to 1.0,
-- the one scale where measuring and drawing agree. Costs two measurements per
-- panel draw and is a no-op on the vanilla pixel font, which scales linearly.
--
-- Deliberately reads the RAW engine call, not text_dims: the floors would mask
-- the very degeneracy this is testing for.
local function faithful_scale(gui, scale)
	scale = tonumber(scale) or 1
	if scale >= 1 then return 1 end -- nothing to verify; 1.0 is always honoured
	local w1 = tonumber((GuiGetTextDimensions(gui, SCALE_PROBE, 1))) or 0
	local ws = tonumber((GuiGetTextDimensions(gui, SCALE_PROBE, scale))) or 0
	if w1 <= 0 then return 1 end -- font measures degenerately: don't gamble
	local ratio = ws / w1
	if math.abs(ratio - scale) > SCALE_TOLERANCE * scale then return 1 end
	return scale
end

-- Trim a label with a trailing "..." until it measures within max_px at `scale`.
local function fit_label(gui, text, scale, max_px)
	if max_px <= 0 then return "..." end
	if (text_dims(gui, text, scale)) <= max_px then return text end
	local s = text
	while utf8_chars(s) > 1 and (text_dims(gui, s .. "...", scale)) > max_px do
		s = trim_last_char(s)
	end
	return s .. "..."
end

-- Break a label into lines that each measure within max_px, at word boundaries,
-- so a long row can be READ in full instead of being cut to "...".  Continuation
-- lines are indented two spaces.  A single word wider than a line is trimmed
-- (fit_label) -- there is nowhere else to put it.
local CONTINUATION = "  "
local function wrap_label(gui, text, scale, max_px)
	if (text_dims(gui, text, scale)) <= max_px then return { text } end
	local lines, line = {}, ""
	for word in text:gmatch("%S+") do
		local candidate = (line == "") and word or (line .. " " .. word)
		local prefixed = (#lines > 0 and CONTINUATION or "") .. candidate
		if line ~= "" and (text_dims(gui, prefixed, scale)) > max_px then
			lines[#lines + 1] = (#lines > 0 and CONTINUATION or "") .. line
			line = word
		else
			line = candidate
		end
	end
	if line ~= "" then lines[#lines + 1] = (#lines > 0 and CONTINUATION or "") .. line end
	return lines
end

-- Companion cast-structure panel for the held wand, drawn RIGHT-ANCHORED.
-- Overlap with wand boxes is acceptable (the panel is opaque and topmost, and
-- can be hidden), so placement is simple: pin the right edge near the screen
-- edge at a fixed width.  Vertically it is HYBRID -- a short structure pins at
-- the selected wand's height (clamped below the HP bars); a long one that won't
-- fit there takes over the full-height right column under the bars (may cover
-- the Wet/Tinker status text, by design) and scrolls.  Rows wider than the
-- panel are cut with "..." (hover for the full text, click to wrap them).
-- `opts` (optional) is the panel's view state, owned by the caller so it survives
-- from frame to frame:
--   opts.hidden    true = draw only a small "show" tab.  Toggled here by a click
--                on the title (or the tab); the caller toggles it for the Home key.
--   opts.scroll    first visible content row, 0-based; clamped here and written
--                back.  Only used when the structure does not fit.
--   opts.expanded  { [label] = true } rows the reader opened by clicking them;
--                wrapped in full.  Written by this function.
--   opts.mouse     { x, y, click } in GUI coordinates (nil = no pointer): a row cut
--                short with "..." shows its full text in a tooltip while hovered,
--                and a click opens / closes it; a click on the title hides the
--                panel; a click on the scroll bar jumps there.  The panel's gui
--                stays non-interactive, so this reads the raw pointer instead.
local function draw_panel(gui, rows, title, sw, sh, anchor, scale, opts)
	if #rows == 0 then return end
	opts = opts or {}

	-- Under a font that ignores fractional scale this snaps to 1.0; the whole
	-- rest of the function then measures and draws at the same size. Must come
	-- before ANY measurement below.
	scale = faithful_scale(gui, scale)

	local pad = 4
	-- GuiText()/GuiGetTextDimensions() both take a scale arg (verified against
	-- tools_modding/lua_api_documentation.html); measure at the same scale so the
	-- panel width/row height stay exact. text_dims (not the raw engine call):
	-- a non-pixel font measuring degenerately must not collapse the layout.
	local _, th = text_dims(gui, title, scale)
	local line_h = th + 2
	local bar_w = (text_dims(gui, "| ", scale)) -- advance per nesting spine
	local mouse = opts.mouse
	local function over(x, y, w, h)
		return mouse and mouse.x >= x and mouse.x <= x + w and mouse.y >= y and mouse.y < y + h
	end

	-- ---- where the panel sits ------------------------------------------------
	local screen_bot = sh - BOTTOM_MARGIN
	local stack_top = anchor.boxes[1].top
	for _, b in ipairs(anchor.boxes) do
		if b.top < stack_top then stack_top = b.top end
	end
	local sel_top = (anchor.sel and anchor.boxes[anchor.sel])
		and anchor.boxes[anchor.sel].top or stack_top
	-- candidate top: the selected wand's box top, never above the stack top and
	-- never over the HP/mana/gold bars.
	local cand_top = math.floor(math.max(TOP_BAR_KEEPOUT, stack_top, sel_top))

	-- Width: fixed, in proportion to the text size, so it neither hugs the
	-- longest row (jumping as you scroll) nor shrinks next to a wide wand.
	local panel_w = PANEL_W_BASE * scale / 0.6
	panel_w = math.min(panel_w, sw * PANEL_W_MAX_FRAC)
	panel_w = math.max(panel_w, PANEL_W_MIN)
	panel_w = math.min(panel_w, sw - RIGHT_MARGIN - 8)
	-- the box starts one pad left of the text column; right-aligned to the screen
	local px = math.floor(sw - RIGHT_MARGIN - panel_w + pad)
	local box_x = px - pad

	-- ---- hidden: just a tab to bring it back ---------------------------------
	if opts.hidden then
		local tab = "[+] " .. title
		local tab_w = (text_dims(gui, tab, scale)) + pad * 2
		local tx = math.floor(sw - RIGHT_MARGIN - tab_w + pad)
		if mouse and mouse.click and over(tx - pad, cand_top - pad, tab_w, line_h + pad * 2) then
			opts.hidden = false
			mouse.click = false
		end
		GuiZSet(gui, PANEL_BG_Z)
		GuiImageNinePiece(gui, 90210, tx - pad, cand_top - pad, tab_w, line_h + pad * 2, 1.0)
		GuiZSet(gui, PANEL_TEXT_Z)
		GuiColorSetForNextWidget(gui, HEADER_COLOR[1], HEADER_COLOR[2], HEADER_COLOR[3], 1)
		GuiText(gui, tx, cand_top, tab, scale)
		GuiZSet(gui, 1)
		return
	end

	-- ---- rows: wrap the ones the reader opened, cut the rest -----------------
	-- The text column leaves room for the scroll bar, always, so toggling the bar
	-- never reflows anything.
	local label_budget = panel_w - pad * 2 - SCROLLBAR_W - SCROLLBAR_GAP
	opts.expanded = opts.expanded or {}
	do
		local expanded = {}
		for _, r in ipairs(rows) do
			local open = opts.expanded[r.label]
			local bars_w = (r.header and 0 or #r.bars) * bar_w
			local lines = open and wrap_label(gui, r.label, scale, label_budget - bars_w)
				or { r.label }
			for _, text in ipairs(lines) do
				local copy = {}
				for k, v in pairs(r) do copy[k] = v end
				copy.key, copy.full = r.label, r.label
				copy.opened = #lines > 1 and opts.expanded[r.label] or nil
				copy.label = text
				expanded[#expanded + 1] = copy
			end
		end
		rows = expanded
	end
	for _, r in ipairs(rows) do
		local bars_w = (r.header and 0 or #r.bars) * bar_w
		r.label = fit_label(gui, r.label, scale, label_budget - bars_w)
		r.cut = (r.label ~= r.full) and not r.opened
	end

	-- ---- vertical placement and the scroll window ---------------------------
	local function rows_at(y)
		return math.floor((screen_bot - y - pad - 2 - line_h) / line_h)
	end
	local y0
	if rows_at(cand_top) >= #rows then
		y0 = cand_top                    -- short: pin at the wand's height
	else
		y0 = math.floor(TOP_BAR_KEEPOUT) -- long: take over the full-height column
	end
	local max_rows = math.max(2, rows_at(y0))

	-- Trailing sticky rows (the "?" footnotes, the bracket legend) stay put under
	-- the scrolling part: they explain marks that are on screen above them.
	local n_sticky = 0
	while rows[#rows - n_sticky] and rows[#rows - n_sticky].sticky do n_sticky = n_sticky + 1 end
	local content = #rows - n_sticky

	local scrolls = #rows > max_rows
	local visible, scroll = content, 0
	if scrolls then
		-- one line is kept for the key hint
		visible = math.max(1, max_rows - n_sticky - 1)
		local max_scroll = math.max(0, content - visible)
		scroll = math.max(0, math.min(math.floor(opts.scroll or 0), max_scroll))
	end
	opts.scroll = scroll

	local shown = {}
	for i = scroll + 1, scroll + visible do shown[#shown + 1] = rows[i] end
	for i = content + 1, #rows do shown[#shown + 1] = rows[i] end
	if scrolls then
		shown[#shown + 1] = { bars = {}, label = "PgUp/PgDn: scroll   Home: hide",
			color = COLOR.OTHER, hint = true }
	end
	local panel_h = (#shown + 1) * line_h + pad * 2

	-- ---- clicks on the title (hide) and the scroll bar (jump) ---------------
	local title_hit = over(box_x, y0 - pad, panel_w, line_h + pad)
	if mouse and mouse.click and title_hit then
		opts.hidden = true
		mouse.click = false   -- consumed: the tab drawn next must not take the same click
	end

	local bar_x = box_x + panel_w - pad - SCROLLBAR_W
	local bar_y = y0 + line_h + 2
	local bar_h = visible * line_h
	if scrolls and mouse and mouse.click and over(bar_x - 2, bar_y, SCROLLBAR_W + 4, bar_h) then
		local target = (mouse.y - bar_y) / bar_h * content - visible / 2
		scroll = math.max(0, math.min(math.floor(target + 0.5), content - visible))
		opts.scroll = scroll
		shown = {}
		for i = scroll + 1, scroll + visible do shown[#shown + 1] = rows[i] end
		for i = content + 1, #rows do shown[#shown + 1] = rows[i] end
		shown[#shown + 1] = { bars = {}, label = "PgUp/PgDn: scroll   Home: hide",
			color = COLOR.OTHER, hint = true }
	end
	if opts.hidden then return draw_panel(gui, rows, title, sw, sh, anchor, scale, opts) end

	-- ---- draw ----------------------------------------------------------------
	-- opaque + topmost: lower z draws in front, so the panel sits over any wand
	-- boxes/brackets it overlaps and stays readable.
	GuiZSet(gui, PANEL_BG_Z)
	GuiImageNinePiece(gui, 90210, box_x, y0 - pad, panel_w, panel_h, 1.0)

	GuiZSet(gui, PANEL_TEXT_Z)
	GuiText(gui, px, y0, title, scale)
	local close = "[-]"
	local close_w = (text_dims(gui, close, scale))
	GuiColorSetForNextWidget(gui, HEADER_COLOR[1], HEADER_COLOR[2], HEADER_COLOR[3], 1)
	GuiText(gui, box_x + panel_w - pad - SCROLLBAR_W - close_w, y0, close, scale)

	local y = y0 + line_h + 2
	local tooltip
	for _, r in ipairs(shown) do
		local x = px
		-- a row that was cut short (or that the reader opened) answers the pointer
		if mouse and (r.cut or r.opened) and r.key
			and over(box_x, y, panel_w, line_h) and not over(bar_x - 2, y, SCROLLBAR_W + 4, line_h) then
			if mouse.click then
				opts.expanded[r.key] = (not opts.expanded[r.key]) or nil
			elseif r.cut then
				tooltip = r.full
			end
		end
		local bars = r.bars
		if r.header then bars = {} end -- headers sit flush left
		for _, bc in ipairs(bars) do   -- rainbow nesting spines
			GuiColorSetForNextWidget(gui, bc[1], bc[2], bc[3], 1)
			GuiText(gui, x, y, "|", scale)
			x = x + bar_w
		end
		GuiColorSetForNextWidget(gui, r.color[1], r.color[2], r.color[3], 1)
		GuiText(gui, x, y, r.label, scale)
		y = y + line_h
	end

	-- the scroll bar: a thin track and a thumb showing where the window is
	if scrolls then
		local thumb_h = math.max(4, bar_h * visible / content)
		local thumb_y = bar_y + (bar_h - thumb_h) * scroll / math.max(1, content - visible)
		line(gui, 90301, bar_x, bar_y, SCROLLBAR_W, bar_h, COLOR.OTHER, 0.25)
		line(gui, 90302, bar_x, thumb_y, SCROLLBAR_W, thumb_h, HEADER_COLOR, 0.9)
	end

	-- the full text of the hovered row, next to the pointer, in front of everything
	if tooltip then
		local tip_w = math.min(sw * 0.6, 280)
		local lines = wrap_label(gui, tooltip, scale, tip_w - pad * 2)
		local widest = 0
		for _, l in ipairs(lines) do
			widest = math.max(widest, (text_dims(gui, l, scale)))
		end
		local box_w, box_h = widest + pad * 2, #lines * line_h + pad * 2
		local tx = math.max(4, math.min(mouse.x + 8, sw - box_w - 4))
		local ty = math.max(4, math.min(mouse.y + 12, sh - box_h - 4))
		GuiZSet(gui, PANEL_BG_Z - 2)
		GuiImageNinePiece(gui, 90211, tx - pad, ty - pad, box_w, box_h, 1.0)
		GuiZSet(gui, PANEL_TEXT_Z - 2)
		for i, l in ipairs(lines) do
			GuiText(gui, tx, ty + (i - 1) * line_h, l, scale)
		end
	end
	GuiZSet(gui, 1)
end

-- ---- debug info box (lightweight, user-facing) -----------------------------

-- A small top-left panel a player can flip on in settings and screenshot when
-- reporting a layout bug. It carries the exact facts we need to reproduce:
-- the virtual GUI dimensions + aspect (resolution/aspect is what actually
-- moves the wand-slot layout -- see the BOX.per_row note) and the held wand's
-- size. NOT the heavy calibration HUD (rulers/probes) -- that lives in git
-- history for dev recalibration; this is the one ordinary users turn on.
local function draw_debug_info(gui, sw, sh, wd, per_row)
	local lines = { "Spell Bracket Visualizer " .. VERSION .. "  (debug)" }

	local aspect = (sh > 0) and (sw / sh) or 0
	local off_169 = math.abs(aspect - 16 / 9) > 0.02
	lines[#lines + 1] = string.format("GUI  %d x %d   aspect %.3f  %s",
		math.floor(sw + 0.5), math.floor(sh + 0.5), aspect,
		off_169 and "(NOT 16:9 -- layout calibrated for 16:9)" or "(16:9)")
	lines[#lines + 1] = "slot-row wraps at col: " ..
		((per_row and per_row < 99) and tostring(per_row) or "off (>= 16:9)")

	if wd then
		lines[#lines + 1] = string.format(
			"wand:  cap=%d  spells=%d  per-cast=%d  shuffle=%s",
			wd.cfg.capacity, #wd.tokens, wd.cfg.spells_per_cast,
			wd.cfg.shuffle and "yes" or "no")
		lines[#lines + 1] = string.format(
			"rows modeled=%d   cast-wraps=%s",
			wd.nrows, (wd.sim and wd.sim.wrapped) and "yes" or "no")
		-- Depleted cards the engine retried past this cast, per cast.
		do
			local spents = {}
			if wd.sim then
				for _, cast in ipairs(wd.sim.casts) do
					spents[#spents + 1] = (cast.spent and #cast.spent > 0)
						and table.concat(cast.spent, ", ") or "none"
				end
			end
			lines[#lines + 1] = "spent slots: " .. table.concat(spents, " | ")
		end
		-- Which cards made the engine guess (empty when the answer is certain).
		lines[#lines + 1] = string.format(
			"uncertain=%s (%s)", wd.uncertain and "yes" or "no",
			table.concat(wd.uncertain_ids or {}, ", "))
		if wd.sim and wd.sim.error then lines[#lines + 1] = "engine: " .. wd.sim.error end
		-- What exactly the engine had to guess (the usual reason brackets are hidden).
		local guesses = wd.sim and wd.sim.uncertain
		if guesses then
			local function counted(set)
				local names = {}
				for name, n in pairs(set or {}) do names[#names + 1] = name .. " x" .. n end
				table.sort(names)
				return table.concat(names, ", ")
			end
			lines[#lines + 1] = "guess: random=" .. (guesses.random and "yes" or "no")
				.. "  world: " .. counted(guesses.world)
			lines[#lines + 1] = "guess: unknown engine calls: " .. counted(guesses.unknown)
		end
		-- Track E1: the wand's mana ceiling/regen and what each cast costs.
		lines[#lines + 1] = string.format(
			"mana_max=%s charge=%s",
			tostring(wd.cfg.mana_max or 0), tostring(wd.cfg.mana_charge_speed or "?"))
		local manas = {}
		if wd.sim then
			for _, cast in ipairs(wd.sim.casts) do manas[#manas + 1] = fmt(cast.mana or 0) end
		end
		lines[#lines + 1] = "cast mana: " .. table.concat(manas, ", ")
		-- exact SPRITE_OVERRIDES key for the held wand (copy if it sits wrong)
		lines[#lines + 1] = "sprite: " .. (wd.sprite or "(unknown)")
	else
		lines[#lines + 1] = "wand:  (none held -- select/hold a wand)"
	end
	lines[#lines + 1] = engine
		and ("engine: ok, " .. engine.spell_count() .. " spells")
		or ("engine: UNAVAILABLE (" .. tostring(engine_error) .. ")")
	-- Font probe: RAW engine readings, no floors. The width ratio is the whole
	-- diagnosis (docs/FONT_COMPAT.md) -- with the vanilla pixel font it equals
	-- the requested 0.6, so "x0.60 ok" prints; under a font that ignores
	-- fractional scale it comes in far lower (Better Font: 0.35) and the panel
	-- auto-clamps to 1.0, which the line reports so a screenshot shows both the
	-- symptom and the mod's response to it.
	local probe = SCALE_PROBE
	local okp, pw1, ph1 = pcall(GuiGetTextDimensions, gui, probe, 1)
	local okq, pw6, ph6 = pcall(GuiGetTextDimensions, gui, probe, 0.6)
	local w1, w6 = okp and tonumber(pw1) or -1, okq and tonumber(pw6) or -1
	local ratio = (w1 > 0 and w6 >= 0) and (w6 / w1) or -1
	lines[#lines + 1] = string.format(
		"font probe \"%s\"  @1.0: %.1f x %.1f   @0.6: %.1f x %.1f",
		probe, w1, okp and tonumber(ph1) or -1, w6, okq and tonumber(ph6) or -1)
	lines[#lines + 1] = string.format(
		"  scale fidelity x%.2f (want 0.60) -- %s",
		ratio,
		(ratio > 0 and math.abs(ratio - 0.6) <= SCALE_TOLERANCE * 0.6)
			and "ok, fractional sizes honoured"
			or "BROKEN, panel forced to Large")
	lines[#lines + 1] = "Reporting a bug? Screenshot this with the wand open."
	lines[#lines + 1] = "Measure: middle-click two points (e.g. slot corners)."

	-- line height from the measured font (floored via text_dims), not a
	-- hardcoded 11: a tall TTF must not overlap the very readout used to
	-- diagnose font problems
	local _, mh = text_dims(gui, lines[1], 1)
	local line_h, pad = math.max(11, mh + 2), 4
	local max_w = 0
	for _, t in ipairs(lines) do
		local w = (text_dims(gui, t, 1))
		if w > max_w then max_w = w end
	end
	local panel_w = max_w + pad * 2
	local panel_h = #lines * line_h + pad * 2
	-- top-RIGHT corner: the wand panels you measure sit top-LEFT, so anchor here
	-- to keep the whole left column clear (the HUD it may graze isn't a target)
	local x, y = sw - panel_w - 8, 8

	-- lower z = front, so this sits above the cast panel (z -20/-21), the boxes,
	-- and the brackets (z -10) -- the debug readout must never be hidden
	GuiZSet(gui, DEBUG_BG_Z)
	GuiImageNinePiece(gui, 90220, x - pad, y - pad, panel_w, panel_h, 0.9)
	GuiZSet(gui, DEBUG_TEXT_Z)
	for i, t in ipairs(lines) do
		local c = (i == 1) and HEADER_COLOR
			or (i == 2 and off_169 and WRAP_COLOR)
			or { 1, 1, 1 }
		GuiColorSetForNextWidget(gui, c[1], c[2], c[3], 1)
		GuiText(gui, x, y, t)
		y = y + line_h
	end
	GuiZSet(gui, 1)
end

-- Click-to-measure overlay (only while show_debug). Reads the raw mouse (the
-- engine reports it in a 1280x720 virtual screen = 2x the 640x360 GUI, verified
-- against known slot corners), converts to GUI coords, and lets you drop two
-- points to read the span. Axis split (dx/dy) is reported because slot geometry
-- is axis-aligned: dx as a fraction of width == pitch/slot0 units; dy in U ==
-- row-height units -- i.e. the exact numbers the BOX table is calibrated in.
local function draw_measure(gui, sw, sh)
	if type(InputGetMousePosOnScreen) ~= "function" then return end
	local ok, mx, my = pcall(InputGetMousePosOnScreen)
	if not ok or not mx then return end
	local cx, cy = mx * sw / 1280, my * sh / 720

	local okd, mid = pcall(InputIsMouseButtonJustDown, 3) -- middle: drop a point
	if okd and mid then
		if #measure_pts >= 2 then measure_pts = {} end
		measure_pts[#measure_pts + 1] = { cx, cy }
	end

	local id = 91000
	local function cross(x, y, c, len)
		id = id + 1; line(gui, id, x - len, y, len * 2 + 1, 1, c, 0.9)
		id = id + 1; line(gui, id, x, y - len, 1, len * 2 + 1, c, 0.9)
	end

	GuiZSet(gui, DEBUG_TEXT_Z) -- in front of the panel too, so you can measure over it
	cross(cx, cy, { 0.4, 1, 1 }, 6) -- live cursor crosshair
	GuiColorSetForNextWidget(gui, 0.4, 1, 1, 1)
	GuiText(gui, cx + 7, cy + 2, string.format("(%.1f, %.1f)", cx, cy))

	for i, p in ipairs(measure_pts) do
		cross(p[1], p[2], { 1, 1, 0.2 }, 5)
		GuiColorSetForNextWidget(gui, 1, 1, 0.2, 1)
		GuiText(gui, p[1] + 6, p[2] - 12, string.format("P%d (%.1f, %.1f)", i, p[1], p[2]))
	end

	if #measure_pts == 2 then
		local a, b = measure_pts[1], measure_pts[2]
		-- L-guide: horizontal leg at a.y, vertical leg at b.x (slot edges are
		-- axis-aligned, so dx and dy are the meaningful quantities, not a slant)
		id = id + 1; line(gui, id, math.min(a[1], b[1]), a[2],
			math.abs(b[1] - a[1]) + 1, 1, { 1, 0.5, 0.2 }, 0.9)
		id = id + 1; line(gui, id, b[1], math.min(a[2], b[2]),
			1, math.abs(b[2] - a[2]) + 1, { 1, 0.5, 0.2 }, 0.9)
		local dx, dy = b[1] - a[1], b[2] - a[2]
		local dist = math.sqrt(dx * dx + dy * dy)
		GuiColorSetForNextWidget(gui, 1, 0.7, 0.3, 1)
		GuiText(gui, (a[1] + b[1]) / 2 + 4, (a[2] + b[2]) / 2 + 2, string.format(
			"dx=%.1f (%.5fw)  dy=%.1f (%.2fu)  d=%.1f",
			dx, dx / sw, dy, dy / (U * sw), dist))
	end
	GuiZSet(gui, 1)
end

-- ---- per-frame entry point -------------------------------------------------

function M.update()
	if not wand_structure then return end

	-- Once the gui exists it must start a frame EVERY update, even with the
	-- inventory closed: the engine keeps the previous frame's widgets live
	-- (mouse-capturing) until the next GuiStartFrame, so skipping frames left
	-- our widgets blocking wand fire after the inventory was closed.
	if gui == nil then gui = GuiCreate() end
	GuiStartFrame(gui)
	-- Never capture the mouse: hovering the panel/brackets must not block
	-- firing or inventory clicks. 2 = GUI_OPTION.NonInteractive
	-- (data/scripts/lib/utilities.lua); options reset on each GuiStartFrame,
	-- so re-add every frame.
	GuiOptionsAdd(gui, 2)

	if type(GameIsInventoryOpen) ~= "function" or not GameIsInventoryOpen() then return end

	local get = (type(ModSettingGet) == "function") and ModSettingGet or function() return nil end
	local show_panel = get("spell_bracket_visualizer.show_grouping") ~= false
	local show_slots = get("spell_bracket_visualizer.show_slot_brackets") ~= false
	local show_marks = get("spell_bracket_visualizer.show_slot_marks") ~= false
	local show_debug = get("spell_bracket_visualizer.show_debug") == true
	if not show_panel and not show_slots and not show_debug then return end
	-- Model depleted (0-use) spells the way gun.lua does: ON (default) hands the
	-- engine the live charge counts, so a depleted card is retried past (no
	-- bracket on it); OFF pretends every card fires.
	local ignore_depleted = get("spell_bracket_visualizer.ignore_depleted_spells") ~= false
	local panel_scale = PANEL_SCALE_MAP[get("spell_bracket_visualizer.panel_text_size") or "small"] or 0.6
	-- Track C: "hide" (default) withholds slot brackets on a wand whose tier
	-- is worse than exact; "show" draws them anyway. See draw_box_brackets.
	local uncertain_brackets = get("spell_bracket_visualizer.uncertain_brackets") or "hide"

	local sw, sh = GuiGetScreenDimensions(gui)
	-- refw: the GEOMETRY reference width. The engine draws the inventory in fixed
	-- GUI-unit positions calibrated at CAL_W (640), but Noita varies the GUI
	-- RESOLUTION with the window/monitor (always 16:9; it letterboxes other
	-- aspects). So all bracket/box layout must scale by the CONSTANT CAL_W, NOT
	-- the live GUI width sw -- else it drifts whenever the GUI res isn't 640x360
	-- (e.g. a window that yields GUI 720x405). At GUI 640x360, refw == sw, so the
	-- common case stays byte-identical. Real sw/sh still drive the screen-edge
	-- consumers below (wrap column, panel docking, debug box, measure tool).
	local refw = CAL_W

	-- one measure/read pass shared by the brackets and the panel's dock anchor.
	-- per_row is the aspect-calibrated wrap column (99 = no wrap at >= 16:9)
	local per_row = wrap_columns(sw, sh)
	-- First frame only: build the cast engine now that every mod's spells exist.
	ensure_engine()
	-- What the "If ..." spells check (HP, enemies nearby, every-other toggle...)
	-- is read from the live game once per frame, so those wands stay certain.
	if engine then engine.set_world(live_world.read()) end
	local boxes = collect_wand_boxes(gui, refw, per_row, ignore_depleted)

	if show_slots then -- brackets on every wand box (independent of active wand)
		-- strongly negative z = "bring to front": lower z draws on top, and
		-- this must beat the engine's spell-frame layer, not just our own gui
		GuiZSet(gui, -10)
		draw_box_brackets(gui, refw, boxes, show_debug, uncertain_brackets, show_marks)
		GuiZSet(gui, 1)
	end

	if show_panel then -- companion cast-structure tree for the active/held wand
		local wand = get_active_wand()
		local wd, sel = nil, nil
		for i, b in ipairs(boxes) do
			if b.e == wand then wd, sel = b, i; break end
		end
		-- Shuffle wands get nothing at all (user call 2026-06-11): the deck
		-- order randomizes at cast time, so even the panel's slot-order tree
		-- is just one arrangement of many -- not worth showing.
		if wd and not wd.cfg.shuffle and (#wd.tokens > 0 or #wd.always > 0) then
			-- When there's only one cast and it doesn't overflow mana_max, the
			-- cast header is never shown (sim_rows), so the mana number has
			-- nowhere to appear -- put it in the title instead, so it's always
			-- visible somewhere (Track E1).
			local mana_suffix = ""
			if wd.sim and #wd.sim.casts == 1 and not wd.sim.wrapped then
				local c1 = wd.sim.casts[1]
				local over1 = wd.cfg.mana_max and wd.cfg.mana_max > 0
					and c1.mana and c1.mana > wd.cfg.mana_max
				if not over1 and c1.mana ~= nil then
					mana_suffix = ", mana " .. fmt(c1.mana)
				end
			end
			local title = "Wand structure  (" .. wd.cfg.spells_per_cast .. "/cast" .. mana_suffix .. ")"
			local geo = {} -- per-box GUI geometry: top edge (vertical anchor) + right edge (width clamp)
			for i, b in ipairs(boxes) do
				geo[i] = { top = b.top * U * refw, right = b.right }
			end
			local anchor = {
				boxes = geo,
				sel   = sel,
			}
			if key_pressed(KEY_PAGEDOWN) then panel_view.scroll = panel_view.scroll + SCROLL_STEP end
			if key_pressed(KEY_PAGEUP) then panel_view.scroll = panel_view.scroll - SCROLL_STEP end
			if key_pressed(KEY_HOME) then panel_view.hidden = not panel_view.hidden end
			panel_view.mouse = read_pointer(sw, sh)
			draw_panel(gui, sim_rows(wd.sim, wd.cfg, wd.always, wd.uncertain_ids),
				title, sw, sh, anchor, panel_scale, panel_view)
		end
	end

	if show_debug then -- diagnostic readout for bug reports (top-left corner)
		local wand = get_active_wand()
		local dbg_wd = nil
		for _, b in ipairs(boxes) do
			if b.e == wand then dbg_wd = b; break end
		end
		draw_debug_info(gui, sw, sh, dbg_wd, per_row)
		draw_measure(gui, sw, sh)
	end
end

-- Test-only exports for tools/test_font_compat.lua, which drives the REAL
-- font-safety helpers and the REAL draw_panel with a stubbed Gui (the
-- non-pixel-font collapse can't be reproduced in-game on a dev machine
-- without the font mod), and tools/test_slot_delims.lua, which drives the REAL
-- collect_delims/plan_delims (pure -- no Gui needed at all).
-- Nothing in the mod reads _test at runtime.
M._test = {
	utf8_chars      = utf8_chars,
	trim_last_char  = trim_last_char,
	text_dims       = text_dims,
	faithful_scale  = faithful_scale,
	fit_label       = fit_label,
	wrap_label      = wrap_label,
	draw_panel      = draw_panel,
	PANEL_SCALE_MAP = PANEL_SCALE_MAP,
	collect_delims  = collect_delims,
	collect_cast_delims  = collect_cast_delims,
	wrap_delims          = wrap_delims,
	collect_wand_delims  = collect_wand_delims,
	plan_delims     = plan_delims,
	draw_delims     = draw_delims, -- pixel-level check with a recording Gui stub
	draw_box_brackets = draw_box_brackets, -- uncertainty suppression, at the draw level
	draw_marks      = draw_marks,

	nest_color      = nest_color,
	WRAP_COLOR      = WRAP_COLOR,

	sim_rows        = sim_rows,
	read_deck       = read_deck,
	read_config     = read_config,

	ensure_engine = ensure_engine,
	set_engine    = function(e) engine = e end, -- tests inject a stand-in engine
}

return M
