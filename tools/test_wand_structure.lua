#!/usr/bin/env texlua
-- Unit tests for files/wand_structure.lua: the adapter that re-shapes what the
-- game's own cast code did into the expression tree the overlay draws.
--
--     texlua tools/test_wand_structure.lua       (any Lua 5.1+ / LuaJIT works)
--
-- These run the REAL engine (files/engine/) over the game's gun.lua from
-- .gun_ref/, so every expectation below is something the game itself does --
-- not a statement about a model of it.  Build .gun_ref/ with
-- tools/extract_gun.py (reads your data.wak).
--
-- Notation of the compact printer, per cast:  { expressions } | { ... }
--   (head child child)   a card with the cards it gathered / re-cast
--   [A,B]head            leading modifiers, outside the group
--   :xN  :trigN          multicast / trigger payload size
--   :clears[..]          RESET and the slots it removed
--   :dangling            a modifier with nothing left to modify
--   ~WRAP                the expression wrapped the wand
--   *N                   a re-cast copy, N times     (e.g. a Greek letter's copy)
--                        or, on a head, a card a Divide By ran N times
--   [Divide..]X          a Divide By chain: the Divide cards lead the head, which
--                        is the card they re-ran (exact run count after the *)
--   !reason              an Add Trigger that did nothing: no_target, not_carrier,
--                        depleted_target;  !plain = it fired its target with no payload
--   @slots               slots a re-cast copied  (what a Greek letter marks)
--   W after a cast       the cast wrapped the deck

local here = arg[0]:match("^(.*)[/\\]") or "."
local support = dofile(here .. "/test_support.lua")
support.install_mod_loader()
local engine = support.new_engine()
local S = dofile_once("mods/spell_bracket_visualizer/files/wand_structure.lua")

local function simulate(tokens, spc, uses, always)
	return S.simulate(engine, { tokens = tokens, spells_per_cast = spc or 1,
		uses = uses, always = always })
end

-- ---- compact tree printer ---------------------------------------------------

local function show_node(node)
	local mods = ""
	if #node.modifiers > 0 then mods = "[" .. table.concat(node.modifiers, ",") .. "]" end
	local tag = ""
	if node.kind == "multicast" then
		tag = "x" .. tostring(node.group or (node.children and #node.children) or "?")
	elseif node.kind == "trigger" then
		tag = "trig" .. tostring(node.payload)
	elseif node.kind == "reset" then
		-- WHICH slots RESET clears is the whole claim, so list them (an empty
		-- list says "nothing left to clear" out loud).
		tag = "clears[" .. table.concat(node.cleared, ",") .. "]"
	end
	if node.dangling then tag = "dangling" end
	if node.wrap then tag = tag .. "~WRAP" end
	if node.recast then tag = tag .. "*" .. tostring(node.count or 1) end
	if node.runs then tag = tag .. "*" .. tostring(node.runs) end
	if node.trigger_failed then tag = tag .. "!" .. node.trigger_failed end
	if node.no_payload then tag = tag .. "!plain" end
	if node.recast and node.sources then tag = tag .. "@" .. table.concat(node.sources, ",") end
	local head = mods .. node.id .. (tag ~= "" and (":" .. tag) or "")
	if node.children and #node.children > 0 then
		local kids = {}
		for _, c in ipairs(node.children) do kids[#kids + 1] = show_node(c) end
		return "(" .. head .. " " .. table.concat(kids, " ") .. ")"
	end
	return head
end

local function show(sim)
	assert(not sim.error, sim.error)
	local parts = {}
	for _, c in ipairs(sim.casts) do
		local body = {}
		for _, node in ipairs(c.nodes) do body[#body + 1] = show_node(node) end
		parts[#parts + 1] = "{" .. table.concat(body, " ") .. "}" .. (c.wrapped and "W" or "")
	end
	return table.concat(parts, " | ")
end

-- ---- harness ----------------------------------------------------------------

local failures = 0

local function check(name, tokens, spc, expect, uses)
	local got = show(simulate(tokens, spc, uses))
	local ok = got == expect
	if not ok then failures = failures + 1 end
	print(string.format("%s %s\n    expect %s\n    got    %s",
		ok and "PASS" or "FAIL", name, expect, got))
end

local function passck(name, ok, detail)
	if not ok then failures = failures + 1 end
	print(string.format("%s %s%s", ok and "PASS" or "FAIL", name, detail or ""))
end

-- ---- expression shape -------------------------------------------------------


check("doc example, one cast",
	{ "DAMAGE", "BURST_2", "LIGHT_BULLET", "LIGHT_BULLET_TRIGGER", "SPITTER" },
	nil,
	"{([DAMAGE]BURST_2:x2 LIGHT_BULLET (LIGHT_BULLET_TRIGGER:trig1 SPITTER))}")


check("root draws don't wrap",
	{ "LIGHT_BULLET", "LIGHT_BULLET", "LIGHT_BULLET" }, 2,
	"{LIGHT_BULLET LIGHT_BULLET} | {LIGHT_BULLET}")


check("trailing modifier wraps",
	{ "LIGHT_BULLET", "DAMAGE" }, 1,
	"{LIGHT_BULLET} | {[DAMAGE]LIGHT_BULLET:~WRAP}W")


check("multicast wraps for missing child",
	{ "LIGHT_BULLET", "BURST_2", "SPITTER" }, 1,
	"{LIGHT_BULLET} | {(BURST_2:x2~WRAP SPITTER LIGHT_BULLET:~WRAP)}W")


-- random MODIFIER and invokes its action directly), but nearly every
-- MODIFIER body ends in draw_actions(1, true), so in play it chains onto the
-- next card almost always -- confirmed by tools/test_gun_differential.lua
-- running this against the real gun.lua with three different random picks,
-- all of which chained. structure_meta.lua models this as draws=1,
-- tier="approximate" (which modifier gets picked, and so the exact chained
-- spell, is not statically knowable, but "chains" is right far more often
-- than "terminates").
check("RANDOM_MODIFIER chains (random pick, nearly all draw 1)",
	{ "RANDOM_MODIFIER", "LIGHT_BULLET" }, 1,
	"{[RANDOM_MODIFIER]LIGHT_BULLET}")


-- re-casts a card it already has (discarded[1], else hand[1], else deck[1])
-- and force-draws NOTHING, so it consumes only its own slot and does not
-- chain onto the next card. (GAMMA and TAU carry the same dead line.)
check("ALPHA as the first card copies itself (the engine's own recursion)",
	{ "ALPHA", "LIGHT_BULLET" }, 1,
	"{(ALPHA (ALPHA:*1@1 ALPHA:*1@1))} | {LIGHT_BULLET}")


-- DIVIDE_* invoke deck[1] directly (no draw_actions call) -> they chain like
-- a modifier prefix, firing WITH the next card in the same cast.
do
	local sim = simulate({ "DIVIDE_10", "DIVIDE_4", "DIVIDE_2", "LIGHT_BULLET" })
	local node = sim.casts[1] and sim.casts[1].nodes[1]
	passck("a Divide By chain reports its product as the divisor",
		node and node.divisor == 80 and node.runs == 80, " (" .. tostring(node and node.divisor) .. ")")
	local lone = simulate({ "DIVIDE_2", "DIVIDE_2", "DAMAGE", "LIGHT_BULLET" }).casts[1].nodes[1]
	passck("a chain whose target ran only once keeps listing its cards", lone.divisor == nil)
	passck("...and which modifiers are the Divide By cards",
		node and node.divider_at[1] and node.divider_at[2] and node.divider_at[3] and not node.divider_at[4])
end
check("DIVIDE re-runs the next card: a prefix on it, with the exact run count",
	{ "DIVIDE_2", "LIGHT_BULLET" }, 1,
	"{[DIVIDE_2]LIGHT_BULLET:*2}")


check("DIVIDE inside a multicast",
	{ "BURST_2", "DIVIDE_2", "LIGHT_BULLET", "SPITTER" }, 1,
	"{(BURST_2:x2 [DIVIDE_2]LIGHT_BULLET:*2 SPITTER)}")


-- the deck directly instead of force-drawing, so it never pulls the discard
-- back in. Trailing DAMAGE wraps (see above); trailing DIVIDE must not.
check("trailing DIVIDE does not wrap and has nothing to re-cast",
	{ "LIGHT_BULLET", "DIVIDE_2" }, 1,
	"{LIGHT_BULLET} | {DIVIDE_2:dangling}")


-- End-to-end: a depleted MODIFIER is RETRIED PAST, not filtered out of the deck.
-- draw_action pops it, discards it unplayed and returns false; draw_actions then
-- re-draws on the next card. So it does not chain onto the trailing projectile --
-- but it IS gone from the deck, and cast 2 therefore consumes slots 2 AND 3.
-- (Confirmed against the real gun.lua: tools/test_gun_differential.lua.)
check("depleted modifier is retried past, not filtered out",
	{ "LIGHT_BULLET", "DAMAGE", "LIGHT_BULLET" }, 1,
	"{LIGHT_BULLET} | {LIGHT_BULLET}", { [2] = 0 })


-- gathers two FIRING cards, stepping over the depleted one on the way.
check("multicast retries past a depleted card and still gathers 2",
	{ "BURST_2", "LIGHT_BULLET", "SPITTER", "SPITTER" }, 1,
	"{(BURST_2:x2 SPITTER SPITTER)}", { [2] = 0 })


-- draw_action's instant_reload_if_empty path). Cast 3's root draw pops the
-- depleted DAMAGE, retries, finds the deck empty, and the draw is LOST: no wrap,
-- no recharge-ending W. The cast still happened and still emptied slot 3, so it
-- is a real cast with nodes = {} and cast.spent = {3}.
check("depleted last card: draw is lost, wand does NOT wrap",
	{ "LIGHT_BULLET", "LIGHT_BULLET", "DAMAGE" }, 1,
	"{LIGHT_BULLET} | {LIGHT_BULLET} | {}", { [3] = 0 })


-- "trailing modifier wraps" above, DAMAGE's forced draw finds an EMPTY deck on
-- its FIRST attempt and wraps. Here the deck is not empty -- it holds a depleted
-- card -- so the first attempt spends it and the RETRY hits the empty deck.
-- Same wand shape, opposite outcome: the modifier dangles and nothing wraps.
check("forced draw onto a depleted last card dangles, does NOT wrap",
	{ "LIGHT_BULLET", "DAMAGE", "LIGHT_BULLET" }, 1,
	"{LIGHT_BULLET} | {[DAMAGE]DAMAGE:dangling}", { [3] = 0 })


check("add trigger: target is the scanned projectile, next card is the payload",
	{ "ADD_TRIGGER", "LIGHT_BULLET", "BOMB" }, nil,
	"{([ADD_TRIGGER]LIGHT_BULLET:trig1 BOMB)}")


-- one against the trigger projectile), so they join the prefix, not a later cast.
check("add trigger: scan swallows an intervening modifier",
	{ "ADD_TRIGGER", "DAMAGE", "LIGHT_BULLET", "BOMB" }, nil,
	"{([ADD_TRIGGER,DAMAGE]LIGHT_BULLET:trig1 BOMB)}")


-- A stepped-over Add Trigger is counted and consumed but never executed
-- (the body excludes its own family from the inline modifier call).
check("add trigger: a second add trigger is consumed by the scan",
	{ "ADD_TRIGGER", "ADD_TRIGGER", "LIGHT_BULLET", "BOMB" }, nil,
	"{([ADD_TRIGGER,ADD_TRIGGER]LIGHT_BULLET:trig1 BOMB)}")


-- Ball Lightning declares 3, so the trigger draws three 1-card payloads.
-- Found in-game: the payload draw pops a 0-charge Bomb, the retry finds the
-- deck empty, the payload is lost and the wand does NOT wrap. The trigger still
-- fires (with nothing under it); the spent slot is consumed, not bracketed.
check("add trigger: payload onto a depleted card is lost, no wrap",
	{ "ADD_TRIGGER", "DAMAGE", "LIGHT_BULLET", "BOMB" }, 1,
	"{[ADD_TRIGGER,DAMAGE]LIGHT_BULLET:trig1}", { [4] = 0 })


-- With nothing projectile-ish left in the deck the body's `valid` check fails:
-- it casts the consumed card plainly and spawns NO trigger (and draws no payload).
check("add trigger: no card left to trigger, so it fires plainly",
	{ "ADD_TRIGGER", "LIGHT_BULLET" }, nil,
	"{[ADD_TRIGGER]LIGHT_BULLET:!plain}")


-- the modifier it stepped over is still in the deck to be drawn normally.
-- (The engine applies that modifier's body twice -- once in the scan, once when
-- drawn -- but that is shot state, not deck consumption, so no bracket says it.)
check("add trigger: a modifier it steps over is run but stays in the deck",
	{ "ADD_TRIGGER", "DAMAGE" }, nil,
	"{ADD_TRIGGER:!no_target} | {[DAMAGE]ADD_TRIGGER:~WRAP!no_target}W")


-- Add Timer / Add Death Trigger share the body; only the trigger kind differs.
check("add timer: same scan, timer kind",
	{ "ADD_TIMER", "LIGHT_BULLET", "BOMB" }, nil,
	"{([ADD_TIMER]LIGHT_BULLET:trig1 BOMB)}")


-- A modifier BEFORE the add trigger prefixes it as usual, and stays in front
-- of the scanned cards in the prefix list.
check("add trigger: modifier before it keeps its place in the prefix",
	{ "DAMAGE", "ADD_TRIGGER", "LIGHT_BULLET", "BOMB" }, nil,
	"{([DAMAGE,ADD_TRIGGER]LIGHT_BULLET:trig1 BOMB)}")


-- when a Greek is present" override -- the card is kept in the deck for EVERY
-- wand now, and retried past when it is drawn -- so the depleted DAMAGE does not
-- chain onto the trailing LIGHT_BULLET here either. (Tau itself does not chain:
-- its body's draw_actions(1, true) is commented out in the game, so it is a leaf.
-- What Tau's copy does to the deck is the one KNOWN engine divergence in
-- tools/test_gun_differential.lua, and it is unaffected by this.)
check("greek wand: re-casts the cards after it, skipping the depleted one",
	{ "TAU", "LIGHT_BULLET", "DAMAGE", "LIGHT_BULLET" }, 1,
	"{(TAU LIGHT_BULLET:*1@2 [DAMAGE]LIGHT_BULLET:*1@3)} | {LIGHT_BULLET}", { [3] = 0 })


check("reset clears the rest of the wand and ends the cycle",
	{ "LIGHT_BULLET", "RESET", "SPITTER", "BOMB" }, 1,
	"{LIGHT_BULLET} | {RESET:clears[3,4]~WRAP}W")


-- Alone on the wand there is nothing left to clear -- but RESET still PLAYS
-- (it is drawn and its body runs), so it is a real node with an empty bracket,
-- not a no-op and not a leaf.
check("reset with an empty deck clears nothing and is still a node",
	{ "RESET" }, 1,
	"{RESET:clears[]~WRAP}W")


check("reset takes a modifier prefix",
	{ "DAMAGE", "RESET", "SPITTER" }, 1,
	"{[DAMAGE]RESET:clears[3]~WRAP}W")


-- docs/ADVANCED_SCENARIOS_PLAN.md Sec.4 D6. D6 says the cast ends at RESET
-- because the deck is empty. It does not: the tail of RESET's body hands the
-- whole discard pile back as a full deck, so the multicast's SECOND child is
-- drawn from the wand's start and finds BURST_2 again. That second BURST_2
-- draws RESET again -- and this time force_stop_draws is already set, so the
-- restore is skipped, the deck really does stay empty, and its own second
-- child cannot be drawn (nor can it wrap: force_stop_draws also disables
-- draw_action's reload path). Confirmed against gun.lua, which plays exactly
-- "BURST_2 >RESET ~>BURST_2 ~>>RESET" and reports slots {1,2,3,4}.
check("reset inside a multicast: the restore feeds the next child from slot 1",
	{ "BURST_2", "RESET", "SPITTER", "BOMB" }, 1,
	"{(BURST_2:x2~WRAP RESET:clears[3,4]~WRAP (BURST_2:x2 RESET:clears[3,4]))}W")

-- ---- spans: which slots each bracket encloses ------------------------------

local sim = simulate({ "LIGHT_BULLET", "LIGHT_BULLET", "LIGHT_BULLET_TRIGGER" })
local node = sim.casts[3].nodes[1]
passck("wrap span reaches slot 1", node.first == 1 and node.last == 3,
	string.format(" (first=%s last=%s)", node.first, node.last))

sim = simulate({ "DAMAGE", "BURST_2", "LIGHT_BULLET", "SPITTER" })
node = sim.casts[1].nodes[1]
passck("head excludes the modifier prefix",
	node.first == 1 and node.head == 2 and node.last == 4,
	string.format(" (first=%s head=%s last=%s)", node.first, node.head, node.last))

sim = simulate({ "BOUNCY_ORB", "SCATTER_2", "LIGHT", "BOUNCE" })
node = sim.casts[2].nodes[1]
passck("wrapped-in span is tracked apart from the forward run",
	node.head == 2 and node.last == 4 and node.wfirst == 1 and node.wlast == 1 and node.wrap,
	string.format(" (head=%s last=%s wfirst=%s wlast=%s)", node.head, node.last,
		node.wfirst, node.wlast))

-- ---- `grouped`: does the bracket enclose more than one card? -----------------

sim = simulate({ "DAMAGE", "LIGHT_BULLET" })
passck("a modifier alone does not make a bracket",
	sim.casts[1].nodes[1].grouped == false)
sim = simulate({ "BURST_2", "LIGHT_BULLET", "SPITTER" })
passck("a multicast does", sim.casts[1].nodes[1].grouped == true)

-- ---- depleted cards ----------------------------------------------------------

sim = simulate({ "LIGHT_BULLET", "LIGHT_BULLET", "DAMAGE" }, 1, { [3] = 0 })
local c3 = sim.casts[3]
passck("depleted-only cast exists with no nodes",
	#sim.casts == 3 and #c3.nodes == 0 and not c3.wrapped and not sim.wrapped,
	string.format(" (casts=%d nodes=%d wrapped=%s)", #sim.casts, #c3.nodes, tostring(c3.wrapped)))
passck("depleted card is consumed: in slots, in the span, in cast.spent",
	c3.slots[1] == 3 and #c3.slots == 1 and c3.first == 3 and c3.last == 3
		and c3.spent ~= nil and c3.spent[1] == 3 and #c3.spent == 1)
passck("a cast with no depleted card reports no spent list", sim.casts[1].spent == nil)

-- ---- RESET -----------------------------------------------------------------

sim = simulate({ "LIGHT_BULLET", "RESET", "SPITTER", "BOMB" })
local rnode = sim.casts[2].nodes[1]
passck("reset node: kind, head and cleared list",
	rnode.kind == "reset" and rnode.head == 2 and #rnode.cleared == 2
		and rnode.cleared[1] == 3 and rnode.cleared[2] == 4 and #rnode.children == 0)
passck("reset node: the span covers the cleared cards", rnode.first == 2 and rnode.last == 4)
passck("reset cast: nets out to no slots, and reports no spent cards",
	#sim.casts[2].slots == 0 and sim.casts[2].spent == nil and sim.casts[2].wrapped)
sim = simulate({ "RESET", "SPITTER", "BOMB" }, 1, { [2] = 0 })
passck("a depleted card RESET clears is cleared, not spent",
	sim.casts[1].spent == nil and #sim.casts[1].nodes[1].cleared == 2)

-- ---- re-casts ---------------------------------------------------------------

sim = simulate({ "DIVIDE_2", "LIGHT_BULLET" })
passck("Divide By: the card it re-ran is the head, run twice, nothing left as a re-cast",
	sim.casts[1].nodes[1].id == "LIGHT_BULLET" and sim.casts[1].nodes[1].runs == 2
		and #sim.casts[1].nodes[1].children == 0)

-- a Greek letter's copies stay re-casts, folded when identical, one source each
sim = simulate({ "LIGHT_BULLET", "ALPHA" })
local copy = sim.casts[2].nodes[1].children[1]
passck("a Greek copy: flagged as a re-cast, with the slot it copied",
	copy.recast == true and copy.count == 1 and copy.sources[1] == 1)

-- ---- mana: straight from the engine's own counter ----------------------------

local function mana_of(tokens, spc)
	local out = {}
	for _, cast in ipairs(simulate(tokens, spc).casts) do out[#out + 1] = cast.mana end
	return out
end
local one = mana_of({ "LIGHT_BULLET" })[1]
local other = mana_of({ "SPITTER" })[1]
passck("mana: a cast costs the sum of its cards",
	one > 0 and other > 0 and mana_of({ "LIGHT_BULLET", "SPITTER" }, 2)[1] == one + other,
	string.format(" (%s + %s)", tostring(one), tostring(other)))

-- ---- always-cast cards --------------------------------------------------------

sim = simulate({ "LIGHT_BULLET" }, 1, nil, { "DAMAGE" })
passck("always-cast card is traced separately from the deck",
	#sim.casts[1].always >= 1 and sim.casts[1].always[1].id == "DAMAGE"
		and sim.casts[1].nodes[1].id == "LIGHT_BULLET")

-- ---- Divide By chains: exact run counts ----------------------------------------
--
-- A Divide By runs the card after it N times; when that card is itself a Divide
-- By the counts multiply.  The engine's own loop does the arithmetic (including
-- the cut-off that drops a deep Divide By to a single run), the adapter only
-- pools the runs, so these numbers are what the game fires.

check("divide chain: Divide 3 over Divide 2 over a bullet = 6 shots",
	{ "DIVIDE_3", "DIVIDE_2", "LIGHT_BULLET", "BOMB" }, 1,
	"{[DIVIDE_3,DIVIDE_2]LIGHT_BULLET:*6} | {BOMB}")
check("divide chain: Divide 10 over Divide 4 = 40 shots",
	{ "DIVIDE_10", "DIVIDE_4", "LIGHT_BULLET" }, 1,
	"{[DIVIDE_10,DIVIDE_4]LIGHT_BULLET:*40}")
check("divide chain: three Divide 4 in a row = 64 (below the depth cut-off)",
	{ "DIVIDE_4", "DIVIDE_4", "DIVIDE_4", "LIGHT_BULLET" }, 1,
	"{[DIVIDE_4,DIVIDE_4,DIVIDE_4]LIGHT_BULLET:*64}")
check("divide chain: a modifier before it stays outside the chain",
	{ "DAMAGE", "DIVIDE_2", "LIGHT_BULLET" }, 1,
	"{[DAMAGE,DIVIDE_2]LIGHT_BULLET:*2}")

-- The target is still in the deck while Divide By runs it, so a target that
-- draws (a modifier) pulls ITSELF back off the deck: Damage runs twice from the
-- Divide By and once more from that draw.  The chain says so rather than
-- pretending the bullet fired twice.
sim = simulate({ "DIVIDE_2", "DAMAGE", "LIGHT_BULLET" })
passck("divide over a modifier: the modifier is the one that repeats",
	show(sim) == "{[DIVIDE_2,DAMAGE,DAMAGE]LIGHT_BULLET}"
		and sim.casts[1].nodes[1].link_runs[2] == 2 and sim.casts[1].nodes[1].runs == nil,
	" (" .. show(sim) .. ")")

sim = simulate({ "DIVIDE_2", "LIGHT_BULLET" })
passck("a Divide By chain opens its own bracket, over every card it re-runs",
	sim.casts[1].nodes[1].head == 1 and sim.casts[1].nodes[1].grouped
		and sim.casts[1].nodes[1].divided
		and table.concat(sim.casts[1].nodes[1].marked, ",") == "1,2")

-- ---- Greek letters: which card was copied ---------------------------------------

check("alpha copies the first card of the cycle, and says which slot",
	{ "LIGHT_BULLET", "ALPHA", "BOMB" }, 1,
	"{LIGHT_BULLET} | {(ALPHA LIGHT_BULLET:*1@1)} | {BOMB}")
check("gamma copies the LAST card of the deck",
	{ "BOMB", "LIGHT_BULLET", "GAMMA", "SPITTER", "DAMAGE" }, 1,
	"{BOMB} | {LIGHT_BULLET} | {(GAMMA [DAMAGE]SPITTER:*1@5)} | {[DAMAGE]BOMB:~WRAP}W")
check("tau copies the next two cards (here only one is left)",
	{ "LIGHT_BULLET", "BOMB", "TAU", "SPITTER" }, 1,
	"{LIGHT_BULLET} | {BOMB} | {(TAU SPITTER:*1@4)} | {SPITTER}")
check("omega copies everything cast so far, one source per card",
	{ "LIGHT_BULLET", "BOMB", "OMEGA" }, 1,
	"{LIGHT_BULLET} | {BOMB} | {(OMEGA LIGHT_BULLET:*1@1 BOMB:*1@2)}")

-- ---- Add Trigger / Add Timer / Add Expiration Trigger ---------------------------
--
-- The body steps over modifiers / passives / others / multicasts, applies the
-- modifiers that still have charges, and lands on a target.  Everything below
-- is a way that can go differently; `swept` says what happened to each card
-- it stepped over, `trigger_failed` / `no_payload` say why nothing triggered.

local function first_node(s) return s.casts[1].nodes[1] end
local function swept_text(node)
	local out = {}
	for _, card in ipairs(node.swept or {}) do out[#out + 1] = card.id .. ":" .. card.effect end
	return table.concat(out, ",")
end

sim = simulate({ "ADD_TRIGGER", "BURST_2", "ADD_TIMER", "DAMAGE", "LIGHT_BULLET", "BOMB" })
passck("trigger scan: modifier applied, multicast and scanner stepped over with no effect",
	swept_text(first_node(sim)) == "BURST_2:ignored,ADD_TIMER:scanner,DAMAGE:applied"
		and first_node(sim).kind == "trigger" and first_node(sim).trigger == "hit_world",
	" (" .. swept_text(first_node(sim)) .. ")")

sim = simulate({ "ADD_TRIGGER", "DAMAGE", "LIGHT_BULLET", "BOMB" }, 1, { [2] = 0 })
passck("trigger scan: a DEPLETED modifier is still discarded, but not applied",
	swept_text(first_node(sim)) == "DAMAGE:depleted" and first_node(sim).kind == "trigger",
	" (" .. swept_text(first_node(sim)) .. ")")

check("trigger fails: nothing after it",
	{ "ADD_TRIGGER" }, 1, "{ADD_TRIGGER:!no_target}")
sim = simulate({ "ADD_TRIGGER", "SPEED" })
passck("trigger fails: the scan runs off the end; the modifier it applied stays in the wand",
	show(sim):find("^{ADD_TRIGGER:!no_target}") ~= nil
		and swept_text(first_node(sim)) == "SPEED:applied"
		and first_node(sim).swept[1].consumed == false,
	" (" .. show(sim) .. ")")
-- a Greek letter is stepped over (no effect); a card with no trigger version stops the scan
sim = simulate({ "ADD_TRIGGER", "GAMMA", "QUAD_SHOT", "BOMB" })
passck("trigger fails: the card it lands on cannot carry a trigger (Quad Shot)",
	first_node(sim).trigger_failed == "not_carrier"
		and swept_text(first_node(sim)) == "GAMMA:ignored" and #sim.casts == 3,
	" (" .. show(sim) .. ")")
check("trigger fails: the target is out of charges, nothing is consumed",
	{ "ADD_TRIGGER", "LIGHT_BULLET", "BOMB" }, 1,
	"{ADD_TRIGGER:!depleted_target} | {BOMB}", { [2] = 0 })

-- plain cast: the target is consumed and fired, but nothing is left to carry
check("trigger with nothing left to carry fires its target plainly",
	{ "ADD_TRIGGER", "DAMAGE", "LIGHT_BULLET" }, 1,
	"{[ADD_TRIGGER,DAMAGE]LIGHT_BULLET:!plain}")

-- the three flavours differ only in WHEN the payload fires
sim = simulate({ "ADD_TIMER", "LIGHT_BULLET", "BOMB" })
passck("add timer: payload fires after a delay, with the frame count",
	first_node(sim).trigger == "timer" and first_node(sim).trigger_frames == 20)
sim = simulate({ "ADD_DEATH_TRIGGER", "LIGHT_BULLET", "BOMB" })
passck("add expiration trigger: payload fires when the projectile expires",
	first_node(sim).trigger == "death")

-- ---- uncertainty -----------------------------------------------------------------

sim = simulate({ "LIGHT_BULLET", "DAMAGE" })
passck("a plain wand is certain", #S.uncertain_ids(sim) == 0 and sim.uncertain == nil)
sim = simulate({ "RANDOM_PROJECTILE" })
local ids = S.uncertain_ids(sim)
passck("a random spell is flagged, and named", #ids == 1 and ids[1] == "RANDOM_PROJECTILE",
	" (" .. table.concat(ids, ",") .. ")")

-- ---- conditional spells: known state is not a guess ---------------------------------

-- Cards the first cast fired, flattened to a list of ids.
local function fired(sim)
	local out = {}
	local function walk(nodes)
		for _, n in ipairs(nodes or {}) do
			out[#out + 1] = n.id
			walk(n.children)
		end
	end
	walk(sim.casts[1] and sim.casts[1].nodes)
	return table.concat(out, ",")
end

local if_hp = { "IF_HP", "LIGHT_BULLET", "IF_END", "BOUNCY_ORB" }
local fresh = support.new_engine()           -- nothing supplied: all defaults
local function run_in(eng, tokens)
	return S.simulate(eng, { tokens = tokens, spells_per_cast = 1 })
end
sim = run_in(fresh, if_hp)
passck("IF_HP on an unsupplied world is a guess", #S.uncertain_ids(sim) == 1,
	" (" .. table.concat(S.uncertain_ids(sim), ",") .. ")")

fresh.set_world({ hp = 4, max_hp = 4 })
sim = run_in(fresh, if_hp)
local healthy = fired(sim)
passck("IF_HP with the real HP supplied is certain", #S.uncertain_ids(sim) == 0)
passck("...and records the HP it depended on", sim.deps.hp == 4 and sim.deps.max_hp == 4)
passck("...and stays valid while those values hold", fresh.deps_hold(sim.deps))

fresh.set_world({ hp = 1, max_hp = 4 })
passck("...and is stale once HP changes", not fresh.deps_hold(sim.deps))
sim = run_in(fresh, if_hp)
passck("low HP takes the other branch", fired(sim) ~= healthy,
	" (" .. healthy .. " vs " .. fired(sim) .. ")")
passck("...and is certain as well", #S.uncertain_ids(sim) == 0)

-- every other: the toggle is the player's live state; each cast flips it.
local every = { "IF_HALF", "LIGHT_BULLET", "IF_END", "BOUNCY_ORB" }
sim = run_in(fresh, every)
passck("IF_HALF without the live toggle is a guess", #S.uncertain_ids(sim) == 1)
fresh.set_world({ every_other_state = 0 })
sim = run_in(fresh, every)
passck("IF_HALF with the live toggle is certain", #S.uncertain_ids(sim) == 0)
local first_run = fired(sim)
sim = run_in(fresh, every)
passck("a run always starts from the supplied toggle (no leak between runs)",
	fired(sim) == first_run)
fresh.set_world({ every_other_state = 1 })
sim = run_in(fresh, every)
passck("the other toggle value takes the other branch", fired(sim) ~= first_run)

-- randomness stays a guess whatever the world says
fresh.set_world({ hp = 4, max_hp = 4, every_other_state = 0 })
sim = run_in(fresh, { "RANDOM_PROJECTILE" })
passck("randomness is still uncertain with a full world", #S.uncertain_ids(sim) == 1)

-- ---- bad input -----------------------------------------------------------------------

sim = simulate({ "LIGHT_BULLET", "NO_SUCH_SPELL" })
passck("an unknown spell id is an error, not a crash", sim.error ~= nil and #sim.casts == 0)
sim = S.simulate(engine, { tokens = { "LIGHT_BULLET" }, shuffle = true })
passck("shuffle wands are reported, not simulated", sim.shuffle == true and #sim.casts == 0)

print(failures == 0 and "ALL PASS" or (failures .. " FAILED")); os.exit(failures == 0 and 0 or 1)
