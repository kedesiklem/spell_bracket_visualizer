-- Wand structure: turns what the game's own cast code did into the expression
-- tree the overlay draws.
--
-- WHAT CHANGED, AND WHY THIS FILE IS SMALL NOW
--   This module used to be a hand-written simulator: it kept a table of how many
--   cards each spell draws (structure_meta.lua) and re-implemented the engine's
--   draw rules on top of it.  Every spell that does something the table cannot
--   say -- the Greek letters, Divide By, Add Trigger's scan, RESET -- needed its
--   own special case, and each special case was a guess about the engine.
--
--   Now the engine is simply RUN (files/engine/): the game's gun.lua casts the
--   wand inside a sandbox and the tracer records every call.  This file does
--   not decide what happened -- it only RE-SHAPES the recording: it folds a
--   modifier into the card it modifies, groups a multicast with the cards it
--   gathered, and so on.  If the engine does something odd, this file shows it.
--
-- INPUT   M.simulate(engine, wand)
--           engine  files/engine/engine.lua object
--           wand    { tokens = { action_id... }       the wand's cards, slot order
--                     always = { action_id... }       always-cast cards (optional)
--                     spells_per_cast = N,
--                     uses = { [slot] = uses_left },  sparse (optional)
--                     shuffle = bool }
--
-- OUTPUT  { casts = { cast... }, wrapped = bool,       -- any cast wrapped
--           uncertain = { random, world, unknown },    -- see wand_runner.lua
--           shuffle = true }                           -- nothing to show
--         | { error = "message", casts = {} }
--
--   cast = { nodes = { expression... },     what the cast drew, in order
--            always = { expression... },    always-cast cards that fired
--            wrapped = bool,                the deck wrapped mid-draw
--            mana = N,                      what the cast cost (engine's counter)
--            spent = { slot... },           slots popped but never played
--                                           (depleted or unaffordable); absent if none
--            slots = { slot... },           every slot the cast removed from the deck
--            first, last,                   its forward slot span
--            wfirst, wlast }                its wrapped-in slot span
--
-- An EXPRESSION is one thing the wand casts: leading modifiers, then a head card
-- with whatever it gathered.  Fields:
--   id, atype      the head card (for an Add Trigger: the projectile it carries)
--   kind           "leaf" | "multicast" | "trigger" | "reset"
--   modifiers      ids of the leading cards that attached to the head, outermost
--                  first -- they sit OUTSIDE the group's brackets, Lisp-style
--   head           slot of the head card: where the bracket starts
--   children       expressions gathered by the head (multicast cards, trigger
--                  payload) followed by the cards the head RE-CAST
--   recast         true on a child that is a re-cast copy, not a drawn card
--   count          times an identical re-cast ran (Divide By 2 -> count 2)
--   grouped        the head's brackets enclose more than one card
--   first, last    every slot the expression removed; the span first..last reaches
--                  into the wrapped-in cards when the wand wrapped
--   ffirst, flast  the slots removed BEFORE the wrap (the forward run)
--   wfirst, wlast  the slots removed AFTER the wrap (the wrapped-in run)
--   wrap           the expression wrapped the wand
--   uncertain      some card of it read game state or randomness; uncertain_ids
--                  = { [action_id] = true } names which
--   kind-specific  trigger = "timer"|"hit_world"|"death", payload = N,
--                  scan = true (Add Trigger family: head was swept, not played);
--                  cleared = { slot... } (reset); skipped = { slot... } (cards a
--                  spell threw away without casting, e.g. a failed "If");
--                  dangling = true (a modifier with nothing left to modify)

local M = {}

-- The Add Trigger family.  Their body pulls cards out of the deck by hand and
-- fires the projectile itself when there is nothing to attach a payload to --
-- structurally the same as Divide By or a Greek letter re-running a card, which
-- must stay a visible re-cast.  The recording cannot tell them apart, so these
-- three names are the one thing this file knows about specific spells.
local SCANNERS = { ADD_TRIGGER = true, ADD_TIMER = true, ADD_DEATH_TRIGGER = true }

-- ---- reading the recording ------------------------------------------------

--- Action children of a node: those it DREW off the deck, or those it re-cast.
local function action_children(node, direct)
	local out = {}
	for _, child in ipairs(node.children) do
		if child.kind == "action" and (child.via == "direct") == direct then
			out[#out + 1] = child
		end
	end
	return out
end
local function drawn_children(node) return action_children(node, false) end
local function direct_children(node) return action_children(node, true) end

--- Did the wand wrap anywhere inside this node?
local function wrapped_inside(node)
	if (node.wraps or 0) > 0 then return true end
	for _, child in ipairs(node.children or {}) do
		if wrapped_inside(child) then return true end
	end
	return false
end

local function shot_child(node)
	for _, child in ipairs(node.children) do
		if child.kind == "shot" then return child end
	end
end

--- How many cards the body actually asked the deck for.  A draw another card had
-- switched off, or the always-cast "casts one spell" rule, asked for nothing.
local function requested(node)
	local total = 0
	for _, draw in ipairs(node.draws or {}) do
		if not draw.suppressed and not draw.permanent_rule then total = total + draw.n end
	end
	return total
end

--- A prefix card asks for exactly one more card and is not a trigger: a modifier
-- (but also Alpha-style spells).  It attaches to what it draws.
local function is_prefix(node)
	return node.kind == "action" and requested(node) == 1 and shot_child(node) == nil
		and node.cleared == nil
end

-- ---- slot sets ------------------------------------------------------------

local function set_of(list)
	local set = {}
	for _, v in ipairs(list or {}) do set[v] = true end
	return set
end

local function sorted_keys(set)
	local out = {}
	for k in pairs(set) do out[#out + 1] = k end
	table.sort(out)
	return out
end

--- min and max of a slot list, or nil for an empty one.
local function extent(slots)
	local lo, hi
	for _, slot in ipairs(slots) do
		if lo == nil or slot < lo then lo = slot end
		if hi == nil or slot > hi then hi = slot end
	end
	return lo, hi
end

--- Fill first/last, ffirst/flast, wfirst/wlast on `target` from a slot list and
-- the set of slots removed after the wand wrapped.
local function assign_spans(target, slots, wrapped_set)
	local forward, wrapped = {}, {}
	for _, slot in ipairs(slots) do
		if wrapped_set[slot] then wrapped[#wrapped + 1] = slot else forward[#forward + 1] = slot end
	end
	target.first, target.last = extent(slots)
	target.ffirst, target.flast = extent(forward)
	target.wfirst, target.wlast = extent(wrapped)
end

-- ---- building expressions -------------------------------------------------

local build_expression  -- forward declaration (expressions nest)

local function ids_of(nodes)
	local ids = {}
	for _, node in ipairs(nodes) do ids[#ids + 1] = node.id end
	return ids
end

--- A stable text key for an expression, used to fold identical re-casts.
local function signature(expr)
	local parts = { expr.id, table.concat(expr.modifiers, ","), expr.kind,
		table.concat(expr.slots_, ",") }
	for _, child in ipairs(expr.children or {}) do parts[#parts + 1] = signature(child) end
	return table.concat(parts, "|")
end

--- Merge runs of identical consecutive re-casts: "Divide By 2" casting the same
-- projectile twice becomes one child with count = 2.
local function fold(recasts)
	local out = {}
	for _, expr in ipairs(recasts) do
		local previous = out[#out]
		if previous and signature(previous) == signature(expr) then
			previous.count = previous.count + 1
		else
			expr.count = 1
			out[#out + 1] = expr
		end
	end
	return out
end

--- Build the child expressions of one head: what it drew, then what it re-cast.
local function gather_children(ctx, source_nodes, recast_nodes)
	local children = {}
	for _, node in ipairs(source_nodes) do
		children[#children + 1] = build_expression(ctx, node)
	end
	local recasts = {}
	for _, node in ipairs(recast_nodes) do
		local expr = build_expression(ctx, node)
		expr.recast = true
		recasts[#recasts + 1] = expr
	end
	for _, expr in ipairs(fold(recasts)) do children[#children + 1] = expr end
	return children
end

--- Everything a node's body removed that none of its children accounts for:
-- cards swept up without being cast (Add Trigger's target, a failed "If").
local function swept_slots(node)
	local covered = {}
	for _, child in ipairs(node.children) do
		if child.slot then covered[child.slot] = true end
		for _, slot in ipairs(child.span or {}) do covered[slot] = true end
	end
	local swept = {}
	for _, slot in ipairs(node.span) do
		if not covered[slot] then swept[#swept + 1] = slot end
	end
	return swept
end

--- The slots the outermost card of an expression accounts for.
local function slots_of(outer)
	local slots = {}
	for _, slot in ipairs(outer.span) do slots[#slots + 1] = slot end
	if outer.via == "draw" and outer.slot then
		slots[#slots + 1] = outer.slot
		table.sort(slots)
	end
	return slots
end

local function finish(expr, chain, outer)
	local slots = slots_of(outer)
	local wrapped = set_of(outer.wrapped_in)
	if outer.wrapped_self then wrapped[outer.slot] = true end
	assign_spans(expr, slots, wrapped)
	expr.slots_ = slots

	-- Slots of the head and everything after it: the cards the brackets enclose.
	-- The leading modifiers stand outside them.
	local chain_slots = {}
	for _, node in ipairs(chain) do if node.slot then chain_slots[node.slot] = true end end
	local grouped = 0
	for _, slot in ipairs(slots) do
		if not chain_slots[slot] then grouped = grouped + 1 end
	end
	expr.grouped = grouped > 1
	-- The expression wrapped the wand if a wrap happened inside it, or if the
	-- draw that fetched its first card is the one that wrapped.
	if wrapped_inside(outer) or outer.wrapped_draw then expr.wrap = true end
	return expr
end

-- A modifier chain that ran out of cards: nothing left to modify.
local function dangling_expression(chain)
	local last = chain[#chain]
	local expr = {
		kind = "leaf", id = last.id, atype = "MODIFIER", dangling = true,
		modifiers = ids_of(chain), children = {},
		head = chain[1].slot,
	}
	return finish(expr, chain, chain[1])
end

function build_expression(ctx, node)
	-- 1. Fold leading prefix cards into the card they modify.
	local chain, cur = {}, node
	while is_prefix(cur) do
		chain[#chain + 1] = cur
		local next_card = drawn_children(cur)[1]
		if next_card == nil then return dangling_expression(chain) end
		cur = next_card
	end

	local outer = chain[1] or cur
	local expr = {
		id = cur.id, atype = cur.atype or ctx.engine.action_type(cur.id) or "OTHER",
		modifiers = ids_of(chain), kind = "leaf", children = {},
		head = (cur.via == "draw") and cur.slot or nil,
	}
	local function note_uncertain(node_)
		if node_.uncertain then
			expr.uncertain = true
			expr.uncertain_ids = expr.uncertain_ids or {}
			expr.uncertain_ids[node_.id] = true
		end
	end
	for _, link in ipairs(chain) do note_uncertain(link) end
	note_uncertain(cur)

	-- Re-casts made by any card of the chain (a copy of the next spell, ...).
	local recast_nodes = {}
	for _, link in ipairs(chain) do
		for _, node_ in ipairs(direct_children(link)) do recast_nodes[#recast_nodes + 1] = node_ end
	end

	-- 2. Classify the head by what its body did.
	local shot = shot_child(cur)
	local wanted = requested(cur)
	local own_direct = direct_children(cur)

	-- Cards the body pulled out of the deck itself, without drawing them: Add
	-- Trigger steps over modifiers and carries the projectile it lands on.  A
	-- direct call is only such a card when no drawn child accounts for its slot --
	-- Divide By also re-runs a card, but that card was DRAWN first.
	local drawn_slots = {}
	for _, child in ipairs(drawn_children(cur)) do
		if child.slot then drawn_slots[child.slot] = true end
		for _, slot in ipairs(child.span or {}) do drawn_slots[slot] = true end
	end
	local own_span = set_of(cur.span)
	local carried = {}
	for _, child in ipairs(own_direct) do
		if child.slot and own_span[child.slot] and not drawn_slots[child.slot] then
			carried[#carried + 1] = child
		end
	end

	--- Re-present `cur` as the card it carried: led by itself and the cards it
	-- stepped over, with the bracket starting at `cur` itself.
	local function present_as_carried(target_slot, stepped_set)
		stepped_set[target_slot] = nil
		expr.scan = true
		expr.id = ctx.tokens[target_slot] or expr.id
		expr.atype = ctx.engine.action_type(expr.id) or expr.atype
		expr.modifiers[#expr.modifiers + 1] = cur.id
		for _, slot in ipairs(sorted_keys(stepped_set)) do
			expr.modifiers[#expr.modifiers + 1] = ctx.tokens[slot]
		end
		expr.head = cur.slot
		own_direct = {}
	end

	local stepped = {}
	for _, slot in ipairs(swept_slots(cur)) do stepped[slot] = true end
	for _, child in ipairs(carried) do stepped[child.slot] = true end

	if shot then
		expr.kind = "trigger"
		expr.trigger = shot.trigger
		expr.payload = shot.draws[1] and shot.draws[1].n or nil
		local swept = swept_slots(cur)
		-- The projectile is the last card swept without being cast.
		if #swept > 0 then present_as_carried(swept[#swept], stepped) end
		expr.children = gather_children(ctx, drawn_children(shot), {})
	elseif cur.cleared and wanted == 0 and #cur.children == 0 then
		expr.kind = "reset"
		expr.cleared = cur.cleared
	elseif wanted >= 2 then
		expr.kind = "multicast"
		expr.group = wanted
		expr.children = gather_children(ctx, drawn_children(cur), {})
	elseif #carried > 0 and SCANNERS[cur.id] then
		-- Add Trigger with no card to carry a payload: the projectile fires plainly.
		present_as_carried(carried[#carried].slot, stepped)
	else
		local skipped = swept_slots(cur)
		if #skipped > 0 and #own_direct == 0 then expr.skipped = skipped end
	end

	for _, node_ in ipairs(own_direct) do recast_nodes[#recast_nodes + 1] = node_ end
	local recasts = gather_children(ctx, {}, recast_nodes)
	for _, child in ipairs(recasts) do expr.children[#expr.children + 1] = child end

	-- 3. Spans, from what the engine removed while the outermost card ran.
	return finish(expr, chain, outer)
end

-- ---- casts ----------------------------------------------------------------

local function collect_spent(node, out)
	for _, child in ipairs(node.children or {}) do
		if child.kind == "skip" and child.slot then out[#out + 1] = child.slot end
		collect_spent(child, out)
	end
end

local function build_cast(ctx, traced)
	local root = traced.root
	local cast = { nodes = {}, always = {}, wrapped = traced.wrapped, mana = traced.mana_spent }

	if root then
		for _, node in ipairs(drawn_children(root)) do
			cast.nodes[#cast.nodes + 1] = build_expression(ctx, node)
		end
		local wrapped = set_of(root.wrapped_in)
		assign_spans(cast, root.net, wrapped)
		cast.slots = root.net
		-- `first/last` reach only the forward run; the wrapped-in run has its own.
		cast.first, cast.last = cast.ffirst, cast.flast
		cast.ffirst, cast.flast = nil, nil

		local spent = {}
		collect_spent(root, spent)
		table.sort(spent)
		if #spent > 0 then cast.spent = spent end
	else
		cast.slots = {}
	end

	for _, node in ipairs(traced.always) do
		cast.always[#cast.always + 1] = build_expression(ctx, node)
	end
	return cast
end

--- Action ids, in order of first appearance, whose behaviour in `sim` depended
-- on game state or randomness (the "?" cards).  Used for the panel footnote.
function M.uncertain_ids(sim)
	local ids, seen = {}, {}
	local function walk(expr)
		for id in pairs(expr.uncertain_ids or {}) do
			if not seen[id] then seen[id] = true; ids[#ids + 1] = id end
		end
		for _, child in ipairs(expr.children or {}) do walk(child) end
	end
	for _, cast in ipairs(sim.casts) do
		for _, expr in ipairs(cast.nodes) do walk(expr) end
		for _, expr in ipairs(cast.always) do walk(expr) end
	end
	table.sort(ids)
	return ids
end

function M.simulate(engine, wand)
	local result = engine.run(wand)
	if result.error then return { error = result.error, casts = {} } end
	if result.shuffle then return { shuffle = true, casts = {} } end

	local ctx = { engine = engine, tokens = wand.tokens }
	local sim = { casts = {}, wrapped = false, uncertain = result.uncertain }
	for _, traced in ipairs(result.casts) do
		local cast = build_cast(ctx, traced)
		sim.casts[#sim.casts + 1] = cast
		if cast.wrapped then sim.wrapped = true end
	end
	return sim
end

return M
