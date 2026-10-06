#!/usr/bin/env lua5.4
-- Runs the REAL files/grouping_overlay.lua delimiter planner (collect_delims +
-- plan_delims) against the REAL engine (the game's own gun.lua, from .gun_ref/), so the
-- slot-bracket NESTING is covered without the game:
--
--     lua5.4 tools/test_slot_delims.lua
--
-- Both functions are pure -- columns, rows, colors and stack indices, no Gui
-- and no pixels -- which is exactly why the planning was split out of
-- draw_delims. Everything below the planner (x/y arithmetic, hook drawing) is
-- still eyeball-verified from a screenshot; see docs/GROUPING_DESIGN.md.
--
-- The invariant these tests exist to protect (regression 2026-08-07): ONE
-- GROUP IS ONE COLOR, and every delimiter is a real bracket. A group straddling
-- a wand wrap is drawn as four glyphs -- a [ ] pair around each half, all in
-- the group's own rainbow color, joined by the orange carriage return. It is
-- never drawn in WRAP_COLOR: orange belongs to the carriage return alone, and
-- painting the wrapped half orange is what made one group read as two.
-- The two glyphs the return attaches to are flagged `seam`; they are drawn
-- exactly like any other bracket.

local here = arg[0]:match("^(.*)[/\\]") or "."
local MOD = here .. "/.."
local support = dofile(here .. "/test_support.lua")
support.install_mod_loader()   -- grouping_overlay.lua resolves deps via dofile_once
local engine = support.new_engine()
local S = dofile_once("mods/spell_bracket_visualizer/files/wand_structure.lua")

--- Simulate with the real engine; `opts` = { spells_per_cast, uses, always }.
local function simulate(tokens, opts)
	opts = opts or {}
	return S.simulate(engine, { tokens = tokens, spells_per_cast = opts.spells_per_cast or 1,
		uses = opts.uses, always = opts.always })
end

local overlay = dofile(MOD .. "/files/grouping_overlay.lua")
local T = assert(overlay._test, "grouping_overlay.lua did not return its _test exports")
assert(T.collect_delims and T.plan_delims, "_test is missing the delimiter planner")

-- ---- tiny check harness (same conventions as test_wand_structure.lua) -------

local failures = 0
local function passck(name, ok, detail)
	if ok then
		print("PASS " .. name)
	else
		failures = failures + 1
		print("FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
	end
end
local function eq(name, got, want)
	passck(name, got == want, tostring(got) .. " ~= " .. tostring(want))
end

-- ---- plan a wand -----------------------------------------------------------

-- Simulate `tokens` at `spc` spells/cast and plan its slot glyphs, through the
-- REAL collect_wand_delims -- the same entry point draw_box_brackets uses, so
-- cast delimiting, rainbow depth and wrap enclosure are all covered here rather
-- than re-implemented. Assumes a gap-free wand (card i sits in column i-1 on
-- row 0) unless `cols` says otherwise; the gap test at the end passes real
-- columns.
local function plan(tokens, spc, cols, rows)
	local sim = simulate(tokens, { spells_per_cast = spc })
	cols = cols or {}
	rows = rows or {}
	for i = 1, #tokens do
		cols[i] = cols[i] or (i - 1)
		rows[i] = rows[i] or 0
	end
	local groups = T.collect_wand_delims(sim, cols, rows)
	return T.plan_delims(groups), groups, sim
end

-- "L0 R3^1 L1 R3" -- compact glyph rendering: side + column, "^N" = stack level
-- (omitted at 0, the innermost/on-the-card position).
local function show(glyphs)
	local out = {}
	for _, gl in ipairs(glyphs) do
		out[#out + 1] = ((gl.side == "left") and "L" or "R") .. gl.col
			.. ((gl.stack > 0) and ("^" .. gl.stack) or "")
	end
	return table.concat(out, " ")
end

local function same_color(a, b)
	return a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

-- WRAP_COLOR belongs to the wrap enclosure and nothing else: a GROUP or CAST
-- bracket drawn orange is the original bug (it read as an unrelated group).
local function orange_is_wrap_only(glyphs)
	for _, gl in ipairs(glyphs) do
		if same_color(gl.c, T.WRAP_COLOR) ~= (gl.wrap == true) then return false end
	end
	return true
end

-- ---- 1. the reported wand (screenshot 2026-08-07) --------------------------
--
-- LUMINOUS_DRILL / BURST_2 / HEAVY_SPREAD / LIGHT_BULLET at 1 spell/cast.
-- cast 2 draws Double Spell (slot 2), gathers [Heavy spread] Light bullet
-- (slots 3-4), then runs out of deck and WRAPS back to Luminous drill (slot 1).
-- The WRAP encloses the whole looping structure -- slot 1 (the card it pulled
-- back in) through slot 4 (where the cast ran out of deck) -- and the Double
-- Spell group sits inside it over its forward run, slots 2..4:
--
--     [ Luminous [Double, Heavy spread, Light bullet] ]
--
-- Both casts fire a SINGLE spell expression, so neither is bracketed (nothing
-- fires simultaneously in a one-spell cast, and cast 2's span would have been
-- identical to the Double Spell group's -- one boundary drawn twice). The
-- rainbow still advances per cast, so the group lands at depth 2.
do
	local glyphs, groups, sim = plan(
		{ "LUMINOUS_DRILL", "BURST_2", "HEAVY_SPREAD", "LIGHT_BULLET" }, 1)
	eq("report/two single-spell casts", #sim.casts[1].nodes .. "," .. #sim.casts[2].nodes, "1,1")
	eq("report/the wrap enclosure plus one group", #groups, 2)
	eq("report/glyphs", show(glyphs), "L0 R3^1 L1 R3")
	passck("report/the enclosure comes first, and is the wrap",
		groups[1].wrap == true and groups[1].ca == 0 and groups[1].cb == 3)
	passck("report/it is the only orange thing", orange_is_wrap_only(glyphs))
	passck("report/the closing bracket carries the tag",
		glyphs[2].label == "wraps to front" and glyphs[4].label == nil)
	-- the rainbow is ONE progression across both axes (user call 2026-08-07):
	-- every cast advances it by one, and so does every nesting level inside a
	-- group -- and a suppressed cast still consumes its slot, so the colors
	-- don't shift when a cast gains or loses a spell. cast 2 owns depth 1, so
	-- the Double Spell inside it is depth 2.
	passck("report/the group continues at depth 2", same_color(glyphs[3].c, T.nest_color(2)))
end

-- ---- 1b. cast spans and the rainbow across many casts ----------------------
--
-- The 12-slot wand from the second screenshot, 2 spells/cast: four casts, the
-- last one wrapping out of a Pentagram (5-way multicast). Casts 1-3 hold only
-- leaves -- a spell plus its modifier prefix -- so before casts were delimited
-- this whole wand drew exactly ONE bracket pair. Cast spans must cover the
-- modifier prefixes, not just the spell that fires. Every cast here fires TWO
-- spells, so unlike case 1 every cast is bracketed.
do
	local glyphs, groups, sim = plan({
		"TNTBOX", "TNTBOX", "HORIZONTAL_ARC", "GUNPOWDER_TRAIL", "TNTBOX", "TNTBOX",
		"SPIRALING_SHOT", "TNTBOX", "TNTBOX", "RECOIL", "TNTBOX", "PENTAGRAM_SHAPE" }, 2)
	eq("wand12/four casts", #sim.casts, 4)
	local function span(ci)
		local c = sim.casts[ci]
		return c.first .. ".." .. c.last
			.. (c.wfirst and (" w" .. c.wfirst .. ".." .. c.wlast) or "")
	end
	eq("wand12/cast 1 span", span(1), "1..2")
	eq("wand12/cast 2 span", span(2), "3..6")  -- [Aiming Arc, Gunpowder trail] Box, Box
	eq("wand12/cast 3 span", span(3), "7..9")  -- [Spiral Arc] Box, Box
	eq("wand12/cast 4 span", span(4), "10..12 w1..8") -- wraps into the wand's start
	eq("wand12/wrap enclosure + four casts + one Pentagram group", #groups, 6)
	-- The wrap encloses columns 0..11, the WHOLE row -- including casts 1-3,
	-- which ran before the one that wrapped. So its [ on column 0 must stack
	-- OUTSIDE cast 1's, and its ] on column 11 outside cast 4's and the
	-- Pentagram's: it is collected before every other record for exactly that.
	passck("wand12/the enclosure spans the whole row",
		groups[1].wrap == true and groups[1].ca == 0 and groups[1].cb == 11)
	eq("wand12/glyphs", show(glyphs),
		"L0^1 R11^2 L0 R1 L2 R5 L6 R8 L9 R11^1 L11 R11")
	passck("wand12/the enclosure sits outside cast 1",
		glyphs[1].stack > glyphs[3].stack)
	passck("wand12/it is the only orange thing", orange_is_wrap_only(glyphs))
	for ci = 1, 4 do
		passck("wand12/cast " .. ci .. " takes rainbow slot " .. (ci - 1),
			same_color(groups[ci + 1].c, T.nest_color(ci - 1)))
	end
	passck("wand12/the Pentagram continues at depth 4",
		same_color(groups[6].c, T.nest_color(4)))
end

-- ---- 2. single cast, no wrap: plain nested pairs, no enclosure --------------
--
-- BURST_3 gathers a trigger that carries one payload spell: two nested groups,
-- both ending on the last card, so their closes stack (outer steps right).
-- The whole wand empties in ONE cast, so no cast bracket is drawn (a pair
-- around the entire slot row says nothing) and the groups keep depth 0 --
-- this wand renders exactly as it did before casts were delimited.
do
	local glyphs, groups, sim = plan(
		{ "BURST_3", "LIGHT_BULLET", "BULLET_TIMER", "LIGHT_BULLET" }, 4)
	eq("plain/one cast", #sim.casts, 1)
	passck("plain/does not wrap", not sim.wrapped)
	eq("plain/no cast bracket, no enclosure", #groups, 2)
	eq("plain/glyphs", show(glyphs), "L0 R3^1 L2 R3")
	passck("plain/nothing is orange", orange_is_wrap_only(glyphs))
	passck("plain/no labels", not (glyphs[2].label or glyphs[4].label))
	passck("plain/outer and inner differ in color",
		not same_color(glyphs[1].c, glyphs[3].c))
	passck("plain/outer stays at depth 0", same_color(glyphs[1].c, T.nest_color(0)))
	passck("plain/inner is depth-1", same_color(glyphs[3].c, T.nest_color(1)))
end

-- ---- 3. nested groups inside one enclosure ---------------------------------
--
-- LIGHT_BULLET / BURST_2 / BURST_2 / LIGHT_BULLET at 1/cast. Cast 2's outer Double Spell
-- gathers an inner Double Spell, which takes slot 4 and then wraps to slot 1.
-- ONE enclosure covers the loop (slots 1..4) and the two groups nest inside it
-- over their forward runs:  [ Light bullet [Double [Double, Light bullet]] ]
do
	local glyphs, groups = plan(
		{ "LIGHT_BULLET", "BURST_2", "BURST_2", "LIGHT_BULLET" }, 1)
	-- both casts fire a single spell, so neither is bracketed (case 1's rule)
	eq("nested/one enclosure + two groups, no cast brackets", #groups, 3)
	eq("nested/glyphs", show(glyphs), "L0 R3^2 L1 R3^1 L2 R3")
	passck("nested/the enclosure is outermost on the shared close",
		glyphs[2].wrap == true and glyphs[2].stack == 2)
	passck("nested/only the enclosure is orange", orange_is_wrap_only(glyphs))
	passck("nested/exactly one label", glyphs[2].label == "wraps to front"
		and not (glyphs[4].label or glyphs[6].label))
end

-- ---- 4. a group living wholly in the wrapped-in segment --------------------
--
-- BURST_2 / LIGHT_BULLET / LIGHT_BULLET / BURST_2 at 1/cast. Cast 2's Double Spell (slot 4)
-- wraps immediately and pulls in the wand's leading Double Spell, whose own
-- card was drawn AFTER the wrap -- so it has no forward run at all and falls
-- back to first..last, slots 1..3. Cast 2's own Double Spell has a forward run
-- of exactly its own card, slot 4. Column 0 therefore carries THREE opening
-- brackets (the enclosure, cast 1's group, and the wrapped-in group), which is
-- the overprint per-side stacking prevents; opens never stacked before the fix.
do
	local glyphs, groups, sim = plan(
		{ "BURST_2", "LIGHT_BULLET", "LIGHT_BULLET", "BURST_2" }, 1)
	local outer = sim.casts[2].nodes[1]
	local inner = outer.children[1]
	passck("fully/outer wrapped", outer.wfirst ~= nil)
	passck("fully/outer's forward run is its own card alone", outer.flast == 4)
	passck("fully/inner has no forward run at all", inner.flast == nil)
	eq("fully/enclosure + three groups", #groups, 4)
	eq("fully/glyphs", show(glyphs), "L0^2 R3^1 L0^1 R2^1 L3 R3 L0 R2")
	local st = {}
	for _, gl in ipairs(glyphs) do
		if gl.side == "left" and gl.col == 0 then st[#st + 1] = gl.stack end
	end
	eq("fully/all three column-0 opens got distinct stacks",
		table.concat(st, ","), "2,1,0")
	passck("fully/only the enclosure is orange", orange_is_wrap_only(glyphs))
end

-- ---- 5. empty slots: glyphs follow the real columns -------------------------
--
-- Same wand as case 1 but the cards sit in columns 0, 2, 3, 5 (gaps at 1 and
-- 4). Every glyph must move with its card -- the brackets hug slots, not deck
-- indices.
do
	local glyphs = plan({ "LUMINOUS_DRILL", "BURST_2", "HEAVY_SPREAD", "LIGHT_BULLET" }, 1,
		{ 0, 2, 3, 5 })
	eq("gaps/glyphs", show(glyphs), "L0 R5^1 L2 R5")
end

-- ---- 6. a wrap with no group at all: just the enclosure ---------------------
--
-- LIGHT_BULLET / DAMAGE at 1 spell/cast. Cast 2 draws the bare Damage modifier,
-- which force-draws its replacement, finds the deck empty and WRAPS onto Light
-- bullet. Nothing on the wand has children, so no group is bracketed -- before
-- the wrap got its own enclosure this wand drew no slot-row apparatus at all.
do
	local glyphs, groups, sim = plan({ "LIGHT_BULLET", "DAMAGE" }, 1)
	passck("bare/cast 2 wrapped", sim.casts[2].wfirst ~= nil)
	passck("bare/no node has children",
		#(sim.casts[2].nodes[1].children or {}) == 0)
	eq("bare/the enclosure is the only delimiter", #groups, 1)
	passck("bare/and it is the wrap", groups[1].wrap == true)
	eq("bare/glyphs", show(glyphs), "L0 R1")
	passck("bare/tagged", glyphs[2].label == "wraps to front")
end

-- ---- 7. the "wraps to front" tag holds still --------------------------------
--
-- The tag is anchored to the wand BOX, not to the bracket it labels. A wrap
-- enclosure is the outermost delimiter on its column, so it carries the
-- deepest stack on the wand -- and stack moves a glyph right (STACK_X) AND
-- down (STACK_Y). While the tag hung off the glyph, every extra nesting level
-- in the wand slid the tag further down and right, until it sat on the box's
-- bottom border, unreadable. This drives the REAL draw_delims through Gui
-- stubs and asserts the drawn position does not depend on stack depth at all.
do
	local drawn
	function GuiColorSetForNextWidget() end
	function GuiImage() end
	function GuiText(gui, x, y, text) drawn = { x = x, y = y, text = text } end
	function GuiGetTextDimensions(gui, text) return 6 * #text, 9 end

	local ORANGE, GREY = T.WRAP_COLOR, { 0.6, 0.6, 0.6 }
	local REFW, BOX_RIGHT, BOX_TOP = 640, 500, 80
	local rows_geo = { { top = 100, bot = 112 } }

	-- The wrap enclosure closing on column 9, with `depth` other groups closing
	-- on that same column so the enclosure stacks outward past them. Groups are
	-- collected outer-first, so the wrap (added first) takes the top stack --
	-- exactly as collect_wand_delims orders them.
	local function tag_at(depth)
		local groups = { { ca = 0, ra = 0, cb = 9, rb = 0, c = ORANGE, wrap = true } }
		for i = 1, depth do
			groups[#groups + 1] = { ca = i, ra = 0, cb = 9, rb = 0, c = GREY }
		end
		drawn = nil
		T.draw_delims(nil, groups, REFW, rows_geo, { n = 0 }, BOX_RIGHT, BOX_TOP)
		return drawn
	end

	local flat, deep = tag_at(0), tag_at(6)
	passck("tag/drawn at all", flat ~= nil and flat.text == "wraps to front")
	eq("tag/x does not move with stack depth", deep and deep.x, flat and flat.x)
	eq("tag/y does not move with stack depth", deep and deep.y, flat and flat.y)
	eq("tag/right-aligned inside the box",
		flat and flat.x, BOX_RIGHT - 6 * #"wraps to front" - 2)
	eq("tag/sits in the box's header band", flat and flat.y, BOX_TOP + 4)
	-- INSIDE the box: never under the slot row (no room -- the box bottom is
	-- barely below it) and never past it into the gap before the next wand.
	passck("tag/above the slot row, inside the box",
		(flat and flat.y or 0) > BOX_TOP and (flat and flat.y or 0) < rows_geo[1].top)
end

-- ---- 8. T1.4 -- uncertain wands hide brackets, draw one "?" instead -----------
--
-- Suppression lives in draw_box_brackets (the planner never sees uncertainty),
-- so this drives the REAL draw_box_brackets through the same kind of recording
-- Gui stubs case 7 uses. A wand whose structure depended on a guess (an "If"
-- spell, a random draw...) draws no bracket glyphs and exactly one dim
-- "? uncertain" tag in the box header band under "hide"; "show" draws the
-- brackets as before and no "?".
do
	local drawn
	function GuiColorSetForNextWidget() end
	function GuiImage(gui, id, x, y, path, a, w, h) drawn.images = drawn.images + 1 end
	function GuiText(gui, x, y, text) drawn.texts[#drawn.texts + 1] = text end
	function GuiGetTextDimensions(gui, text) return 6 * #text, 9 end

	-- Reuses case 2's ("plain") tokens, which reliably draw two nested bracket
	-- pairs at spc=4 -- so "show" has something to show. The uncertainty flag is
	-- stamped independently here (as collect_wand_boxes would from the engine's
	-- report), standing in for a wand that also holds a random spell.
	local UNCERTAIN_TOKENS = { "BURST_3", "LIGHT_BULLET", "BULLET_TIMER", "LIGHT_BULLET" }
	local function make_wd()
		return {
			tokens = UNCERTAIN_TOKENS,
			xs = { 0, 1, 2, 3 },
			per_row = 99,
			cfg = { shuffle = false },
			uncertain = true,
			uncertain_ids = { "RANDOM_PROJECTILE" },
			sim = simulate(UNCERTAIN_TOKENS, { spells_per_cast = 4 }),
			rows_geo = { { top = 100, bot = 112 } },
			right = 500,
			top = 80,
		}
	end

	drawn = { images = 0, texts = {} }
	T.draw_box_brackets(nil, 640, { make_wd() }, false, "hide")
	local qmarks = 0
	for _, t in ipairs(drawn.texts) do if t == "? uncertain" then qmarks = qmarks + 1 end end
	eq("uncertain/hide: exactly one '?' glyph", qmarks, 1)
	eq("uncertain/hide: no bracket glyphs drawn", drawn.images, 0)

	drawn = { images = 0, texts = {} }
	T.draw_box_brackets(nil, 640, { make_wd() }, false, "show")
	qmarks = 0
	for _, t in ipairs(drawn.texts) do if t == "? uncertain" then qmarks = qmarks + 1 end end
	eq("uncertain/show: no '?' glyph", qmarks, 0)
	passck("uncertain/show: brackets drawn (bracket() draws 3 GuiImage per glyph)", drawn.images > 0)
end

-- ---- 9. T1.7 -- read_deck stops filtering, hands back `uses` -----------------
--
-- read_deck used to drop a depleted card out of the deck entirely (and remap
-- the survivors' columns through `xs`, gated by a Greek-wand exception). The
-- simulator now models depleted cards itself (a retried-past pop, see
-- files/wand_structure.lua's header), so read_deck's only job is to report
-- every non-permanent card AS-IS -- id, real column, and its uses_remaining
-- where readable -- and let the caller decide whether to hand `uses` to
-- simulate() at all (collect_wand_boxes). This drives the REAL read_deck
-- through stubs of the three game APIs it calls, a 3-card wand with slot 2
-- depleted (uses_remaining == 0).
do
	local WAND = "WAND"
	local CARDS = {
		{ id = "LIGHT_BULLET", x = 0, uses = -1 }, -- unlimited use: -1
		{ id = "HEAVY_SPREAD", x = 1, uses = 0 },  -- depleted
		{ id = "DAMAGE",       x = 2, uses = 5 },
	}

	function EntityGetAllChildren(e)
		if e ~= WAND then return {} end
		local out = {}
		for i = 1, #CARDS do out[i] = i end
		return out
	end
	function EntityGetFirstComponentIncludingDisabled(child, name)
		if name == "ItemActionComponent" then return "IAC" .. child end
		if name == "ItemComponent" then return "IC" .. child end
		return nil
	end
	function ComponentGetValue2(comp, field)
		local kind, idx = comp:match("^(%a+)(%d+)$")
		local card = CARDS[tonumber(idx)]
		if kind == "IAC" then
			if field == "action_id" then return card.id end
		elseif kind == "IC" then
			if field == "inventory_slot" then return card.x, 0 end
			if field == "permanently_attached" then return false end
			if field == "uses_remaining" then return card.uses end
		end
		return nil
	end

	local tokens, always, xs, uses = T.read_deck(WAND, true)
	eq("read_deck/three tokens", #tokens, 3)
	eq("read_deck/no always-cast cards", #always, 0)
	eq("read_deck/slot 2 is depleted", uses[2], 0)
	passck("read_deck/nothing pre-filtered -- HEAVY_SPREAD stays in tokens",
		tokens[2] == "HEAVY_SPREAD")
	passck("read_deck/xs is the identity (real column per token, nothing dropped)",
		xs[1] == 0 and xs[2] == 1 and xs[3] == 2)

	-- Clean up the stubs so they don't leak into later runs of this file (none
	-- follow today, but the plan() helper above never expected these globals).
	EntityGetAllChildren = nil
	EntityGetFirstComponentIncludingDisabled = nil
	ComponentGetValue2 = nil
end

-- ---- 10. T1.7 -- a depleted card inside a multicast's gather ----------------
--
-- BURST_2 (draws=2) gathers the next two CARDS THAT FIRE, not the next two
-- slots: with slot 2 depleted, drawing retries past it (files/wand_structure.lua
-- M.simulate's `draw()`), so the group's children are the cards at slots 3 and
-- 4 -- but the group's span is still 1..4, because the span is [head .. last
-- child], and slot 2 sits inside that range even though no node covers it.
-- That is the definition working as designed (§ T1.7 point 4): a bracket
-- spanning across a spent slot visually includes it, and this is the one test
-- that pins the behavior down instead of just asserting it in a comment.
do
	local glyphs, groups, sim = plan(
		{ "BURST_2", "LIGHT_BULLET", "SPITTER", "BOMB" }, 1, nil, nil)
	-- plan() doesn't thread `uses` through simulate, so drive M.simulate
	-- directly here the same way plan() does internally.
	sim = simulate({ "BURST_2", "LIGHT_BULLET", "SPITTER", "BOMB" },
		{ spells_per_cast = 1, uses = { [2] = 0 } })
	local cols, rows = {}, {}
	for i = 1, 4 do cols[i] = i - 1; rows[i] = 0 end
	groups = T.collect_wand_delims(sim, cols, rows)
	glyphs = T.plan_delims(groups)

	eq("spent-span/one cast", #sim.casts, 1)
	local node = sim.casts[1].nodes[1]
	eq("spent-span/BURST_2 head at slot 1", node.first, 1)
	eq("spent-span/gather reaches slot 4 (BOMB), past the depleted slot 2", node.last, 4)
	eq("spent-span/cast consumed slot 2 as spent, not in a node",
		sim.casts[1].spent and sim.casts[1].spent[1], 2)
	eq("spent-span/the multicast bracket spans columns 0..3 (slots 1..4)",
		show(glyphs), "L0 R3")
end

-- ---- 11. T1.10d -- RESET's cleared cards get their own bracket -------------
--
-- LIGHT_BULLET, RESET, SPITTER, BOMB at 1 spell/cast. Cast 1 fires the single
-- Light bullet -- no bracket (one spell, nothing simultaneous). Cast 2 draws
-- RESET (slot 2), which clears the rest of the deck (Spitter/Bomb, slots 3-4)
-- and then restores it, wrapping the wand. RESET's own bracket must enclose
-- exactly what it cleared -- head (its own slot) through the last cleared
-- card -- even though the node has no children: nothing about the cleared
-- cards ran, so collect_delims can't recurse into them, but the bracket
-- definition (README "What a bracket means") still owes them a pair.
do
	local glyphs, groups, sim = plan(
		{ "LIGHT_BULLET", "RESET", "SPITTER", "BOMB" }, 1)
	passck("reset/cast 2 wraps", sim.casts[2].wrapped == true)
	local node = sim.casts[2].nodes[1]
	eq("reset/RESET node kind", node.kind, "reset")
	eq("reset/RESET clears slots 3-4", table.concat(node.cleared, ","), "3,4")
	eq("reset/cast 1 draws no bracket, RESET gets exactly one", #groups, 1)
	-- slots 2..4 -> columns 1..3
	eq("reset/bracket spans RESET's slot through the last cleared card",
		show(glyphs), "L1 R3")
	passck("reset/nothing is orange (no group actually wrapped)",
		orange_is_wrap_only(glyphs))
end

-- ---- 12. T1.10d -- a bare RESET clears nothing, so it draws no bracket -----
--
-- RESET alone: the deck is empty by the time it fires, so node.cleared is
-- empty and there is nothing to enclose. Still wraps (the one-shot restore
-- always fires), but a wrap with nothing inside it draws no enclosure either
-- (case 6's rule) since no node has a nonempty span to wrap around.
do
	local glyphs, groups, sim = plan({ "RESET" }, 1)
	passck("bare-reset/wraps", sim.casts[1].wrapped == true)
	local node = sim.casts[1].nodes[1]
	eq("bare-reset/kind", node.kind, "reset")
	eq("bare-reset/clears nothing", #node.cleared, 0)
	eq("bare-reset/no delimiters at all", #groups, 0)
	eq("bare-reset/no glyphs", show(glyphs), "")
end

-- ---- 13. T1.10d -- a chained modifier sits outside RESET's bracket ---------
--
-- DAMAGE, RESET, SPITTER at 1 spell/cast. DAMAGE chains onto RESET as its
-- modifier prefix (meta: draws=1, no payload -> chains()), so RESET's node
-- spans first=1 (DAMAGE's slot) .. last=3, but its BRACKET uses head (its
-- own slot, 2), not first -- same as every other bracket-worthy node -- so
-- the modifier prints outside the bracket, matching the "[mods] name" panel
-- convention.
do
	local glyphs, groups, sim = plan({ "DAMAGE", "RESET", "SPITTER" }, 1)
	local node = sim.casts[1].nodes[1]
	eq("reset-mod/RESET's span includes the modifier's slot", node.first, 1)
	eq("reset-mod/RESET's own slot is 2", node.head, 2)
	eq("reset-mod/RESET clears slot 3", table.concat(node.cleared, ","), "3")
	eq("reset-mod/one bracket, from RESET's slot (not the modifier's)", #groups, 1)
	-- slots 2..3 -> columns 1..2; DAMAGE (slot 1 / column 0) sits outside
	eq("reset-mod/bracket runs head..last, modifier excluded",
		show(glyphs), "L1 R2")
end

print(failures == 0 and "\nALL PASS" or ("\n" .. failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
