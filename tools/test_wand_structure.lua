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
--   *N                   a re-cast copy, N times     (e.g. Divide By)
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
	"{(ALPHA (ALPHA:*1 ALPHA:*1))} | {LIGHT_BULLET}")


-- DIVIDE_* invoke deck[1] directly (no draw_actions call) -> they chain like
-- a modifier prefix, firing WITH the next card in the same cast.
check("DIVIDE re-casts the next card: shown as a group with a x2 re-cast",
	{ "DIVIDE_2", "LIGHT_BULLET" }, 1,
	"{(DIVIDE_2 LIGHT_BULLET:*2)}")


check("DIVIDE inside a multicast",
	{ "BURST_2", "DIVIDE_2", "LIGHT_BULLET", "SPITTER" }, 1,
	"{(BURST_2:x2 (DIVIDE_2 LIGHT_BULLET:*2) SPITTER)}")


-- the deck directly instead of force-drawing, so it never pulls the discard
-- back in. Trailing DAMAGE wraps (see above); trailing DIVIDE must not.
check("trailing DIVIDE does not wrap and has nothing to re-cast",
	{ "LIGHT_BULLET", "DIVIDE_2" }, 1,
	"{LIGHT_BULLET} | {DIVIDE_2}")


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
	"{[ADD_TRIGGER]LIGHT_BULLET}")


-- the modifier it stepped over is still in the deck to be drawn normally.
-- (The engine applies that modifier's body twice -- once in the scan, once when
-- drawn -- but that is shot state, not deck consumption, so no bracket says it.)
check("add trigger: a modifier it steps over is run but stays in the deck",
	{ "ADD_TRIGGER", "DAMAGE" }, nil,
	"{(ADD_TRIGGER DAMAGE:*1)} | {[DAMAGE]ADD_TRIGGER:~WRAP}W")


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
	"{(TAU LIGHT_BULLET:*1 [DAMAGE]LIGHT_BULLET:*1)} | {LIGHT_BULLET}", { [3] = 0 })


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
local recast = sim.casts[1].nodes[1].children[1]
passck("Divide By: one folded child, flagged as a re-cast, counted twice",
	recast.recast == true and recast.count == 2 and #sim.casts[1].nodes[1].children == 1)

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

-- ---- uncertainty -----------------------------------------------------------------

sim = simulate({ "LIGHT_BULLET", "DAMAGE" })
passck("a plain wand is certain", #S.uncertain_ids(sim) == 0 and sim.uncertain == nil)
sim = simulate({ "RANDOM_PROJECTILE" })
local ids = S.uncertain_ids(sim)
passck("a random spell is flagged, and named", #ids == 1 and ids[1] == "RANDOM_PROJECTILE",
	" (" .. table.concat(ids, ",") .. ")")

-- ---- bad input -----------------------------------------------------------------------

sim = simulate({ "LIGHT_BULLET", "NO_SUCH_SPELL" })
passck("an unknown spell id is an error, not a crash", sim.error ~= nil and #sim.casts == 0)
sim = S.simulate(engine, { tokens = { "LIGHT_BULLET" }, shuffle = true })
passck("shuffle wands are reported, not simulated", sim.shuffle == true and #sim.casts == 0)

print(failures == 0 and "ALL PASS" or (failures .. " FAILED")); os.exit(failures == 0 and 0 or 1)
