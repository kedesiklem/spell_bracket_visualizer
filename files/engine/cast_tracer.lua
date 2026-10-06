-- Records what the game's own cast code does, as a tree.
--
-- Credit: evaluating a wand by running the game's own cast code in a sandbox is
-- the approach of kaliuresis' WandDBG (https://github.com/kaliuresis/WandDBG).
--
-- The cast code in gun.lua is a recursive procedure: casting draws a card, the
-- card's body may draw more cards (modifiers, multicasts), or fire a trigger
-- whose payload is a nested draw, or re-run a card it copied (Greek letters,
-- Double Spell, Divide By).  This module wraps that code from the outside --
-- no copy of it, no edit to it -- and writes down each call as a node.
--
-- THE CENTRAL IDEA: a bracket is a set of slots the engine removed from the deck.
--   Every node records `span`: the slots that left the deck while the node was
--   executing, descendants included.  That is exactly what a bracket encloses,
--   and it is measured from the deck itself, so it is right by construction for
--   every card -- including the ones whose bodies remove cards without drawing
--   them (Add Trigger's scan, RESET, Divide By) and for casts that wrap.
--
-- NODE KINDS
--   action  a spell body ran.  Fields:
--             id        action id            slot   1-based wand slot, or nil
--                                                   for an always-cast card
--             via       "draw"      drawn off the deck by draw_action
--                       "direct"    its body was invoked by another card
--                                   (Divide By, Greek letters, Double Spell,
--                                   Add Trigger's scan)
--                       "permanent" an always-cast card
--             atype     action type name ("PROJECTILE", "MODIFIER", ...)
--             rec/iter  the recursion_level / iteration the engine passed
--             draws     { { n, instant, suppressed, permanent_rule } }
--                       every draw_actions() call the body made: how many it
--                       asked for, whether it may wrap, whether another card
--                       had switched drawing off, and whether the "always-cast
--                       modifier casting one spell draws nothing" rule applied
--             wraps     times the deck wrapped inside this very body
--             wrapped_self  the card itself was drawn after the wand wrapped
--             wrapped_draw  the draw that fetched this card is the one that wrapped
--                           the wand (the deck was empty, the discard came back)
--             cleared   slots the body threw away by replacing the deck (RESET)
--             uncertain the body read game state or used randomness, so what
--                       it did is only correct for the simulated world
--             suppressed  the body ran while another card had switched drawing
--                       off (the first run of a Divide By, an Omega's copies):
--                       it did its effect but drew nothing
--             divides   the body returned an iteration count -- the engine's
--                       own signature of a Divide By, which re-runs the card
--                       that follows it.  (The only body that returns anything.)
--             pulled    slots the body itself took out of the deck WITHOUT
--                       drawing them (Add Trigger's scan, a failed "If ...",
--                       Divide By's cleanup).  Exact, unlike inferring it from
--                       what the children cover -- a card that was pulled and
--                       then brought back by a wrap still counts.
--             deck_order  the deck at the moment the body started, as a list of
--                       slots in draw order, and `deck_depleted` the set of
--                       those slots whose card had no charges left.  This is
--                       what lets a reader tell WHY a card that scans the deck
--                       (Add Trigger) stopped where it did.
--   shot    a nested draw: a trigger's payload, or the cast's root draw.
--             trigger   "timer" | "hit_world" | "death" | nil (root)
--   skip    a card was popped but not played.  reason = "depleted" | "mana".
--   blocked a copy was refused by the recursion limit.  id = the card.
--
--   Every action/shot node also has
--     children    nodes created while it ran, in order
--     span        sorted slots removed from the deck while it ran, descendants
--                 and `cleared` cards included -- the bracket's content
--     net         the same, but strictly "in the deck when it began, gone when
--                 it ended": a card RESET threw away and then got back is NOT in
--                 `net`, though it is in `span`
--     wrapped_in  the subset of `span` removed after the wand wrapped
--
-- Public API
--   M.attach(env, report) -> tracer      report: the engine_stubs report
--   tracer.begin_cast()      start recording one cast
--   tracer.end_cast() -> cast
--     cast = { always = { node... },   always-cast cards, before the draw
--              root   = shot node,     the cast's own draw (nil if none ran)
--              wrapped = bool,         the deck wrapped mid-draw
--              reload  = bool }        the wand started a recharge
--   tracer.action_type(id) -> string|nil
--
-- Hooks are installed by REPLACING globals inside the sandbox; gun.lua calls
-- everything through those globals, so every internal call site is covered.

local M = {}

local function slot_of(card)
	if card ~= nil and card.deck_index ~= nil then return card.deck_index + 1 end
	return nil
end

local function sorted(set)
	local out = {}
	for slot in pairs(set) do out[#out + 1] = slot end
	table.sort(out)
	return out
end

function M.attach(env, report)
	local tracer = {}

	local stack = {}          -- open nodes, innermost last
	local cast = nil
	local plays = 0           -- play_action calls so far
	local announced = nil     -- card most recently handed to play_action
	local last_removed = nil  -- card most recently removed from the deck
	local pending_trigger = nil
	local after_wrap = {}     -- slot -> removed after the wand wrapped?
	local wrap_pending = false -- a draw just wrapped; the next played card is the one it fetched
	local popping = false      -- draw_action is fetching a card (not yet playing it)

	-- action type number -> name, and action id -> type name
	local type_name = {}
	for key, value in pairs(env) do
		local name = type(key) == "string" and key:match("^ACTION_TYPE_(.+)$")
		if name and type(value) == "number" then type_name[value] = name end
	end
	local type_of_id = {}
	for _, action in ipairs(env.actions) do
		if action.id then type_of_id[action.id] = type_name[action.type] end
	end
	function tracer.action_type(id) return type_of_id[id] end

	-- ---- node bookkeeping --------------------------------------------------

	local function deck_slots()
		local set = {}
		for _, card in ipairs(env.deck) do
			local slot = slot_of(card)
			if slot then set[slot] = true end
		end
		return set
	end

	-- The deck as drawn: slots in order, plus which of them are out of charges.
	local function deck_snapshot()
		local order, depleted = {}, {}
		for _, card in ipairs(env.deck) do
			local slot = slot_of(card)
			if slot then
				order[#order + 1] = slot
				if card.uses_remaining == 0 then depleted[slot] = true end
			end
		end
		return order, depleted
	end

	-- Every place the sandbox consults the (fake) world or the random generator
	-- bumps report.events; a node whose body moved the counter is uncertain.
	local function events() return report and report.events or 0 end

	local function open(node)
		node.children = {}
		node.entry_ = deck_slots()   -- trailing underscore: private, removed on close
		node.gained_ = {}
		node.deck_ = env.deck
		node.wrapped_open_ = cast.wrapped
		node.events_ = events()
		node.child_events_ = 0
		local parent = stack[#stack]
		if parent then
			parent.children[#parent.children + 1] = node
		elseif node.kind == "shot" and cast.root == nil then
			cast.root = node
		else
			cast.always[#cast.always + 1] = node
		end
		stack[#stack + 1] = node
		return node
	end

	local function close(node)
		stack[#stack] = nil
		local exit_slots = deck_slots()
		local net, span, wrapped_in = {}, {}, {}

		-- Removed = (in the deck when we began, or put back by a wrap) - (still there).
		for slot in pairs(node.entry_) do
			if not exit_slots[slot] then net[slot] = true end
		end
		for slot in pairs(node.gained_) do
			if not exit_slots[slot] then net[slot] = true end
		end
		for slot in pairs(net) do span[slot] = true end

		-- A body that REPLACED the deck table (RESET) threw away everything in it;
		-- the cards come back with the wand's restore, so the diff above nets them
		-- out -- but the bracket must still enclose what the body cleared.  The
		-- clear happens BEFORE the body's own restore wraps the wand, so those
		-- cards count as removed before the wrap unless it had already wrapped.
		if env.deck ~= node.deck_ then
			node.cleared = sorted(node.entry_)
			for slot in pairs(node.entry_) do
				span[slot] = true
				after_wrap[slot] = node.wrapped_open_
			end
		end
		for _, child in ipairs(node.children) do
			for _, slot in ipairs(child.span or {}) do span[slot] = true end
		end

		-- The enclosing nodes saw the same swap, but it was not THEIR body that
		-- replaced the deck: move their baseline to the new table so only the card
		-- that really cleared the deck (RESET) is reported as clearing it.
		local parent_node = stack[#stack]
		if parent_node and parent_node.deck_ == node.deck_ then
			parent_node.deck_ = env.deck
		end

		for slot in pairs(span) do
			if after_wrap[slot] then wrapped_in[slot] = true end
		end
		node.span, node.net = sorted(span), sorted(net)
		node.wrapped_in = sorted(wrapped_in)

		local inclusive = events() - node.events_
		if node.kind == "action" and inclusive - node.child_events_ > 0 then
			node.uncertain = true
		end
		local parent = stack[#stack]
		if parent then parent.child_events_ = parent.child_events_ + inclusive end
		node.entry_, node.gained_, node.deck_, node.wrapped_open_ = nil, nil, nil, nil
		node.events_, node.child_events_ = nil, nil
	end

	local function leaf(node)
		local parent = stack[#stack]
		if parent then parent.children[#parent.children + 1] = node end
		return node
	end

	-- ---- hooks -------------------------------------------------------------

	-- Spell bodies.  clone_action copies `action.action` into every deck card, so
	-- wrapping there binds each wrapper to its own card: a body invoked directly
	-- by another card (Divide By, Greek letters) still knows which slot it is.
	local raw_body = setmetatable({}, { __mode = "k" })   -- wrapper -> original

	local function note_failure(where, err)
		if report and report.failures then
			report.failures[#report.failures + 1] = tostring(where) .. ": " .. tostring(err)
		end
	end

	local function run_action(card, body, ...)
		local via = "direct"
		if announced == card then
			via = env.playing_permanent_card and "permanent" or "draw"
			announced = nil
		end
		local rec, iter = ...
		local slot = slot_of(card)
		local node = open({
			kind = "action", id = card.id, slot = slot, via = via,
			atype = type_name[card.type], rec = rec, iter = iter, draws = {},
			wrapped_self = via == "draw" and slot ~= nil and after_wrap[slot] or nil,
			wrapped_draw = wrap_pending or nil,
			suppressed = env.dont_draw_actions == true or nil,
		})
		node.deck_order, node.deck_depleted = deck_snapshot()
		wrap_pending = false
		popping = false   -- the card is being played now, no longer being fetched
		-- Action bodies return nothing, except Divide By's iteration count.
		local ok, result = pcall(body, ...)
		close(node)
		if not ok then
			-- A spell body that throws (a mod's bug, or an engine call the sandbox
			-- cannot answer) must not take the whole wand down with it.  The card
			-- is marked uncertain, the failure is reported, and the cast goes on
			-- as if the card had done nothing.
			node.uncertain, node.error = true, tostring(result)
			note_failure(card.id, result)
			return nil
		end
		if result ~= nil then node.divides = true end
		return result
	end

	local real_clone = env.clone_action
	env.clone_action = function(source, target)
		real_clone(source, target)
		local body = raw_body[target.action] or target.action
		local wrapper
		wrapper = function(...) return run_action(target, body, ...) end
		raw_body[wrapper] = body
		target.action = wrapper
	end

	local real_play = env.play_action
	env.play_action = function(action)
		plays = plays + 1
		announced = action
		return real_play(action)
	end

	local real_draw_actions = env.draw_actions
	env.draw_actions = function(how_many, instant)
		local node = stack[#stack]
		if node and node.draws then
			node.draws[#node.draws + 1] = {
				n = how_many, instant = instant == true,
				suppressed = env.dont_draw_actions == true,
				permanent_rule = env.playing_permanent_card == true and how_many == 1,
			}
		end
		return real_draw_actions(how_many, instant)
	end

	-- A card popped off the deck that was never played: depleted or unaffordable.
	local real_draw_action = env.draw_action
	env.draw_action = function(instant)
		local plays_before = plays
		last_removed = nil
		popping = true
		local result = real_draw_action(instant)
		popping = false
		if result == false and plays == plays_before and last_removed ~= nil then
			leaf({
				kind = "skip", id = last_removed.id, slot = slot_of(last_removed),
				reason = (last_removed.uses_remaining == 0) and "depleted" or "mana",
			})
		end
		return result
	end

	local real_check_recursion = env.check_recursion
	env.check_recursion = function(data, rec)
		local result = real_check_recursion(data, rec)
		if result == -1 and data ~= nil then
			leaf({ kind = "blocked", id = data.id, slot = slot_of(data) })
		end
		return result
	end

	local real_draw_shot = env.draw_shot
	env.draw_shot = function(shot, instant)
		local node = open({
			kind = "shot", draws = {},
			trigger = pending_trigger and pending_trigger.kind or nil,
			trigger_frames = pending_trigger and pending_trigger.frames or nil,
		})
		pending_trigger = nil
		-- Mods may replace draw_shot (SpellPerformance does) and swap `c` while
		-- it runs; if their version throws half-way, put the state back so the
		-- rest of the cast is not computed with a stranger's modifiers.
		local c_before = env.c
		local ok, err = pcall(real_draw_shot, shot, instant)
		close(node)
		if not ok then
			env.c = c_before
			node.error = tostring(err)
			note_failure("draw_shot", err)
		end
	end
	env.BeginTriggerTimer = function(frames) pending_trigger = { kind = "timer", frames = frames } end
	env.BeginTriggerHitWorld = function() pending_trigger = { kind = "hit_world" } end
	env.BeginTriggerDeath = function() pending_trigger = { kind = "death" } end

	-- A WRAP is a forced draw finding the deck empty and pulling the discard pile
	-- back in.  The same call also happens at the end of a recharge cycle
	-- (_handle_reload), when no draw is in progress -- that is a reload, not a wrap.
	local real_move_discarded = env.move_discarded_to_deck
	env.move_discarded_to_deck = function()
		local moved_something = #env.discarded > 0
		local result = real_move_discarded()
		if moved_something and #stack > 0 then
			cast.wrapped = true
			-- Only a wrap made by the draw itself marks the card it fetches; a body
			-- that restores the deck on its own (RESET) is the wrapper in that case.
			if popping then wrap_pending = true end
			local top = stack[#stack]
			top.wraps = (top.wraps or 0) + 1
		end
		return result
	end

	env.StartReload = function()
		if cast then cast.reload = true end
	end

	-- Deck traffic.  Insertions into the deck are what let a node tell cards that
	-- were put back by a wrap from cards that were there all along; removals say
	-- whether a card left the deck before or after the wand wrapped.
	local real_insert, real_remove = env.table.insert, env.table.remove
	env.table.insert = function(t, a, b)
		if t == env.deck then
			local slot = slot_of(b ~= nil and b or a)
			if slot then
				for _, node in ipairs(stack) do node.gained_[slot] = true end
			end
		end
		if b ~= nil then return real_insert(t, a, b) end
		return real_insert(t, a)
	end
	env.table.remove = function(t, pos)
		local removed = real_remove(t, pos)
		if t == env.deck then
			last_removed = removed
			local slot = slot_of(removed)
			if slot and cast then after_wrap[slot] = cast.wrapped end
			-- Not a draw (draw_action sets `popping`): the running body did it.
			local top = stack[#stack]
			if slot and not popping and top then
				top.pulled = top.pulled or {}
				top.pulled[#top.pulled + 1] = slot
			end
		end
		return removed
	end

	-- ---- recording ---------------------------------------------------------

	function tracer.begin_cast()
		stack = {}
		pending_trigger = nil
		wrap_pending = false
		after_wrap = {}
		cast = { always = {}, root = nil, wrapped = false, reload = false }
	end

	function tracer.end_cast()
		local finished = cast
		cast = nil
		stack = {}
		return finished
	end

	return tracer
end

return M
