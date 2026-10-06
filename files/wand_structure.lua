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
--           deps = { field = value },   -- world values the cast read (engine_stubs.lua)
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
--   marked         { slot... } the cards a modifier chain ties together -- the
--                  modifiers and the card they modify (for an Add Trigger scan:
--                  the trigger, the cards it stepped over and its target).  The
--                  overlay underlines them as one unit.  Absent on a plain card.
--   children       expressions gathered by the head (multicast cards, trigger
--                  payload) followed by the cards the head RE-CAST
--   recast         true on a child that is a re-cast copy, not a drawn card
--   count          times an identical re-cast ran (a Greek letter copying the same card)
--   sources        slots of the cards a re-cast copied (what a Greek letter copied);
--                  the overlay marks them on the wand
--   runs           times the engine ran the head, when a Divide By chain led it: the
--                  EXACT count (Divide 3 over Divide 2 over a bullet -> 6), pooled
--                  from the engine's own runs, not multiplied here
--   silent_runs    of those, how many drew nothing (only for a head that draws)
--   divided        a Divide By chain leads the head; the bracket opens at the first
--                  Divide By and encloses the whole chain
--   link_runs      { [index in modifiers] = N } a modifier a Divide By re-ran
--   grouped        the head's brackets enclose more than one card
--   first, last    every slot the expression removed; the span first..last reaches
--                  into the wrapped-in cards when the wand wrapped
--   ffirst, flast  the slots removed BEFORE the wrap (the forward run)
--   wfirst, wlast  the slots removed AFTER the wrap (the wrapped-in run)
--   wrap           the expression wrapped the wand
--   uncertain      some card of it read game state or randomness; uncertain_ids
--                  = { [action_id] = true } names which
--   kind-specific  trigger = "timer"|"hit_world"|"death", payload = N,
--                  trigger_frames = N (timer),
--                  swept = { {slot, id, effect, consumed}... } the cards an Add Trigger
--                  stepped over; effect "applied" | "depleted" | "ignored" | "scanner",
--                  consumed false when the scan failed (they stay in the wand),
--                  trigger_failed = "no_target"|"not_carrier"|"depleted_target"
--                  (an Add Trigger that consumed nothing), no_payload = true (it
--                  fired its target plainly: nothing left to carry),
--                  scan_mismatch = true (the replay of the scan disagreed with the
--                  recording -- a bug flag, never expected),
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

--- Divide By: the engine's own signature is that its body returns an iteration
-- count (see cast_tracer.lua).  It re-runs the card that follows it.
local function is_divider(node)
	return node.kind == "action" and node.divides == true
end

local function union_into(set, list)
	for _, v in ipairs(list or {}) do set[v] = true end
end

--- Several runs of the SAME card (Divide By ran its target N times, and the
-- target's own Divide By ran ITS target N times for each of those...) as one
-- node: the children of every run pooled, so whatever the engine did N times
-- is simply counted -- 3 runs of a Divide By 2 that each ran a bullet twice are
-- 6 runs of the bullet, with no arithmetic done here.
local function merge_runs(runs)
	local merged = {}
	for k, v in pairs(runs[1]) do merged[k] = v end
	merged.runs = #runs
	merged.silent_runs = 0
	merged.children, merged.draws = {}, {}
	local span, net, wrapped_in = {}, {}, {}
	merged.wraps = 0
	for _, run in ipairs(runs) do
		for _, child in ipairs(run.children or {}) do merged.children[#merged.children + 1] = child end
		for _, draw in ipairs(run.draws or {}) do merged.draws[#merged.draws + 1] = draw end
		union_into(span, run.span); union_into(net, run.net); union_into(wrapped_in, run.wrapped_in)
		merged.wraps = merged.wraps + (run.wraps or 0)
		if run.uncertain then merged.uncertain = true end
		if run.cleared and not merged.cleared then merged.cleared = run.cleared end
		if run.suppressed then merged.silent_runs = merged.silent_runs + 1 end
	end
	merged.span, merged.net, merged.wrapped_in = sorted_keys(span), sorted_keys(net), sorted_keys(wrapped_in)
	return merged
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
			for _, slot in ipairs(expr.sources or {}) do
				previous.sources = previous.sources or {}
				local known = false
				for _, have in ipairs(previous.sources) do if have == slot then known = true end end
				if not known then previous.sources[#previous.sources + 1] = slot end
			end
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
		-- The slot of the card whose body was re-run: what a Greek letter (or
		-- Double Spell...) copied.  Lets the overlay mark it on the wand.
		if node.slot then expr.sources = { node.slot } end
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

-- A modifier chain that ran out of cards: nothing left to modify.  A Divide By
-- with nothing after it is the same story: it is shown alone, as itself.
local function dangling_expression(chain)
	local last = chain[#chain]
	local mods = ids_of(chain)
	local divides_nothing = last.divides == true
	if divides_nothing then mods[#mods] = nil end
	local expr = {
		kind = "leaf", id = last.id, atype = divides_nothing and "OTHER" or "MODIFIER",
		dangling = true, divides_nothing = divides_nothing or nil,
		modifiers = mods, children = {},
		head = chain[1].slot,
	}
	return finish(expr, chain, chain[1])
end

-- ---- Add Trigger's scan ---------------------------------------------------

local STEPPABLE = { MODIFIER = true, PASSIVE = true, OTHER = true, DRAW_MANY = true }
local PAYLOAD_TYPES = { PROJECTILE = true, STATIC_PROJECTILE = true, MATERIAL = true, UTILITY = true }

--- Why an Add Trigger / Add Timer / Add Expiration Trigger did what it did.
--
-- The recording says WHAT left the deck; it cannot say why a scan that left
-- nothing behind stopped, and that is the interesting part ("why did my
-- trigger do nothing?").  So the body's decision is replayed over the deck as
-- it stood when the body started (`deck_order`), following the same rules the
-- body does:
--
--   1. step over cards while they are MODIFIER / PASSIVE / OTHER / DRAW_MANY.
--      A modifier that still has charges and is not itself an Add Trigger is
--      APPLIED to the projectile (without drawing); a depleted one, and every
--      non-modifier, is stepped over with no effect.  Stepped cards are DISCARDED
--      with the target when the scan succeeds -- their charges are not spent.
--   2. the card it stops on is the target.  It fails when
--        no_target        the scan ran off the end of the deck
--        not_carrier      the target has no trigger version (no related projectile)
--        depleted_target  the target is out of charges
--      and then NOTHING is consumed: the cards stay in the deck, and the
--      modifiers it applied along the way stay applied to the shot.
--   3. on success the target becomes the trigger's projectile.  If no
--      projectile-like card is left in the deck to be the payload, the target
--      is cast plainly (`payload = false`) and no trigger is made.
--
-- The result is checked against the recording by the caller; if they disagree
-- the analysis is dropped rather than shown.
--
--   -> { swept = { {slot, id, effect = "applied"|"depleted"|"ignored"|"scanner"} },
--        failed = "no_target"|"not_carrier"|"depleted_target" | nil,
--        target = slot,        success only
--        payload = bool }      success only: is there a card to carry
local function analyse_scan(ctx, node)
	local order, depleted = node.deck_order, node.deck_depleted or {}
	if order == nil then return nil end
	local function id_at(k) return ctx.tokens[order[k]] end
	local function type_at(k) return ctx.engine.action_type(id_at(k)) end

	local swept, i = {}, 1
	while i <= #order and STEPPABLE[type_at(i)] do
		local effect
		if SCANNERS[id_at(i)] then effect = "scanner"
		elseif depleted[order[i]] then effect = "depleted"
		elseif type_at(i) == "MODIFIER" then effect = "applied"
		else effect = "ignored" end
		swept[#swept + 1] = { slot = order[i], id = id_at(i), effect = effect }
		i = i + 1
	end

	local result = { swept = swept }
	if order[i] == nil then
		result.failed = "no_target"
	elseif ctx.engine.carries(id_at(i)) == nil then
		result.failed = "not_carrier"
	elseif depleted[order[i]] then
		result.failed = "depleted_target"
	else
		result.target = order[i]
		result.payload = false
		for k = i + 1, #order do
			if PAYLOAD_TYPES[type_at(k)] then result.payload = true; break end
		end
	end
	return result
end

function build_expression(ctx, node)
	-- 1. Fold leading cards into the card they modify: modifiers (a prefix draws
	-- the card it modifies) and Divide By (which re-runs the card after it).  A
	-- Divide By's target runs several times; those runs are pooled into one
	-- node (merge_runs), so a chain of Divide By cards ends on ONE target whose
	-- `runs` is the exact number of times the engine ran it.
	local chain, cur = {}, node
	local divider, runs = {}, {}     -- node -> true / times it ran (via a Divide By)
	while true do
		if is_divider(cur) then
			chain[#chain + 1] = cur
			divider[cur] = true
			local targets = direct_children(cur)
			if #targets == 0 then return dangling_expression(chain) end
			cur = merge_runs(targets)
			runs[cur] = #targets
		elseif is_prefix(cur) then
			chain[#chain + 1] = cur
			local next_card = drawn_children(cur)[1]
			if next_card == nil then return dangling_expression(chain) end
			cur = next_card
		else
			break
		end
	end
	local has_divider = next(divider) ~= nil

	local outer = chain[1] or cur
	local marked = {}
	for _, link in ipairs(chain) do
		if link.slot then marked[#marked + 1] = link.slot end
	end
	if (cur.via == "draw" or runs[cur]) and cur.slot then marked[#marked + 1] = cur.slot end
	local expr = {
		id = cur.id, atype = cur.atype or ctx.engine.action_type(cur.id) or "OTHER",
		modifiers = ids_of(chain), kind = "leaf", children = {},
		head = (cur.via == "draw") and cur.slot or nil,
	}
	-- Divide By cards open the bracket: it encloses them and the card they
	-- re-run.  (Modifiers before the first Divide By stay outside it.)
	if has_divider then
		for _, link in ipairs(chain) do
			if divider[link] then expr.head = link.slot; break end
		end
		expr.divided = true
	end
	-- How many times each link of the chain ran (a Damage run twice by a
	-- Divide By is applied twice).  A Divide By itself is not counted: its
	-- number is in its name.
	for index, link in ipairs(chain) do
		if runs[link] and runs[link] > 1 and not divider[link] then
			expr.link_runs = expr.link_runs or {}
			expr.link_runs[index] = runs[link]
		end
	end
	if runs[cur] and runs[cur] > 1 then
		expr.runs = runs[cur]
		if cur.silent_runs > 0 then expr.silent_runs = cur.silent_runs end
	end
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
		if not divider[link] then   -- a Divide By's runs ARE the target, not re-casts
			for _, node_ in ipairs(direct_children(link)) do recast_nodes[#recast_nodes + 1] = node_ end
		end
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
		marked = { cur.slot, target_slot }
		for slot in pairs(stepped_set) do marked[#marked + 1] = slot end
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
	-- What a scanner removed is recorded exactly (`pulled`); prefer it to the
	-- inference above, which a wrap can fool (a pulled card brought back by the
	-- wrap is covered by a later child and would look as if nothing was pulled).
	local scanner_pulled = SCANNERS[cur.id] and cur.pulled ~= nil
	if scanner_pulled then stepped = set_of(cur.pulled) end

	-- Add Trigger family: replay the body's decision so the panel can say what
	-- it swept and why it failed.  The replay must agree with the recording about
	-- whether anything was consumed; if it does not, trust the recording and
	-- flag the expression (the tests treat that flag as a failure).
	local scan
	if SCANNERS[cur.id] then
		scan = analyse_scan(ctx, cur)
		local consumed = next(stepped) ~= nil
		if scan and (scan.failed == nil) ~= consumed then
			expr.scan_mismatch = true
			scan = nil
		end
	end
	if scan and #scan.swept > 0 then
		expr.swept = scan.swept
		for _, card in ipairs(expr.swept) do card.consumed = scan.failed == nil end
	end

	if scan and scan.failed then
		-- Nothing consumed.  The silent applications of the modifiers it stepped
		-- over are not casts, so they are not shown as re-casts either.
		expr.trigger_failed = scan.failed
		own_direct = {}
	elseif shot then
		expr.kind = "trigger"
		expr.trigger = shot.trigger
		expr.trigger_frames = shot.trigger_frames
		expr.payload = shot.draws[1] and shot.draws[1].n or nil
		local swept = swept_slots(cur)
		-- The projectile is the last card swept without being cast.
		local target = scan and scan.target or swept[#swept]
		if target then present_as_carried(target, stepped) end
		expr.children = gather_children(ctx, drawn_children(shot), {})
	elseif cur.cleared and wanted == 0 and #cur.children == 0 then
		expr.kind = "reset"
		expr.cleared = cur.cleared
	elseif wanted >= 2 then
		expr.kind = "multicast"
		expr.group = wanted
		expr.children = gather_children(ctx, drawn_children(cur), {})
	elseif scan and scan.target then
		-- Add Trigger with no card to carry a payload: the projectile fires plainly.
		present_as_carried(scan.target, stepped)
		expr.no_payload = true
	elseif #carried > 0 and SCANNERS[cur.id] then
		present_as_carried(carried[#carried].slot, stepped)
		expr.no_payload = true
	else
		local skipped = swept_slots(cur)
		if #skipped > 0 and #own_direct == 0 then expr.skipped = skipped end
	end

	for _, node_ in ipairs(own_direct) do recast_nodes[#recast_nodes + 1] = node_ end
	local recasts = gather_children(ctx, {}, recast_nodes)
	for _, child in ipairs(recasts) do expr.children[#expr.children + 1] = child end

	if #marked >= 2 then
		-- a card can be listed twice (a Divide By's target pulls itself back off the deck)
		local unique, seen = {}, {}
		for _, slot in ipairs(marked) do
			if not seen[slot] then seen[slot] = true; unique[#unique + 1] = slot end
		end
		table.sort(unique)
		if #unique >= 2 then expr.marked = unique end
	end

	-- 3. Spans, from what the engine removed while the outermost card ran.
	-- a bullet fired N times says it all; "N-1 of them silent" only matters for a
	-- card that draws (the silent runs drew nothing)
	if expr.kind == "leaf" then expr.silent_runs = nil end
	local finished = finish(expr, chain, outer)
	if has_divider then finished.grouped = true end
	return finished
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
	local sim = { casts = {}, wrapped = false, uncertain = result.uncertain,
		deps = result.deps }
	for _, traced in ipairs(result.casts) do
		local cast = build_cast(ctx, traced)
		sim.casts[#sim.casts + 1] = cast
		if cast.wrapped then sim.wrapped = true end
	end
	return sim
end

return M
