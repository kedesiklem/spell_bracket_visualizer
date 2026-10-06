#!/usr/bin/env texlua
-- Tests for files/slot_marks.lua (which cards get an underline or a strike) and
-- for the overlay's drawing of them, against the real engine.
--
--     texlua tools/test_slot_marks.lua
--
-- The planner is pure (slots in, columns out), so the interesting checks are on
-- its output; one extra case drives the REAL draw_marks with a recording Gui to
-- make sure every planned mark turns into exactly one line.

local here = arg[0]:match("^(.*)[/\\]") or "."
local support = dofile(here .. "/test_support.lua")
support.install_mod_loader()
local engine = support.new_engine()
local S = dofile_once("mods/spell_bracket_visualizer/files/wand_structure.lua")
local marks_of = dofile_once("mods/spell_bracket_visualizer/files/slot_marks.lua")

local failures = 0
local function eq(name, got, want)
	if got == want then print("PASS " .. name) return end
	failures = failures + 1
	print("FAIL " .. name .. "\n    expect " .. tostring(want) .. "\n    got    " .. tostring(got))
end

--- Plan a gap-free wand and print its marks as "underline 0-2 | strike 2".
local function plan(tokens, uses)
	local sim = S.simulate(engine, { tokens = tokens, spells_per_cast = 1, uses = uses })
	assert(not sim.error, sim.error)
	local cols, rows = {}, {}
	for i = 1, #tokens do cols[i] = i - 1; rows[i] = 0 end
	local out = {}
	for _, m in ipairs(marks_of.collect(sim, cols, rows)) do
		if m.kind == "underline" then out[#out + 1] = string.format("underline %d-%d", m.ca, m.cb)
		elseif m.kind == "copied" then out[#out + 1] = string.format("copied %d x%d", m.col, m.n)
		else out[#out + 1] = string.format("strike %d", m.col) end
	end
	return table.concat(out, " | "), marks_of.collect(sim, cols, rows)
end

eq("modifiers and their projectile are one underline",
	(plan({ "DAMAGE", "CRITICAL_HIT", "LIGHT_BULLET" })), "underline 0-2")
eq("a bare projectile is not underlined", (plan({ "LIGHT_BULLET" })), "")
eq("a modifier inside a multicast underlines only its own chain",
	(plan({ "BURST_2", "DAMAGE", "LIGHT_BULLET", "SPITTER" })), "underline 1-2")
eq("Add Trigger's scan is underlined up to its target, not the payload",
	(plan({ "ADD_TRIGGER", "DAMAGE", "LIGHT_BULLET", "BOMB" })), "underline 0-2")
eq("a depleted card is struck through",
	(plan({ "LIGHT_BULLET", "LIGHT_BULLET", "DAMAGE" }, { [3] = 0 })), "strike 2")

-- what a copier re-ran gets a dot; a card nobody copied gets none
eq("alpha marks the card it copied (slot 1 -> column 0)",
	(plan({ "LIGHT_BULLET", "ALPHA", "BOMB" })), "copied 0 x1")
eq("a wand without a copier has no copy marks",
	(plan({ "LIGHT_BULLET", "BOMB" })), "")
eq("alpha copying itself marks nothing (it is not another card)",
	(plan({ "ALPHA", "LIGHT_BULLET" })), "")
eq("omega marks every card it re-ran",
	(plan({ "LIGHT_BULLET", "BOMB", "OMEGA" })), "copied 0 x1 | copied 1 x1")
eq("two copiers of the same card stack on it",
	(plan({ "LIGHT_BULLET", "ALPHA", "ALPHA", "BOMB" })), "copied 0 x2")

-- a chain that sits on two displayed rows draws nothing rather than a bad line
do
	local sim = S.simulate(engine, { tokens = { "DAMAGE", "LIGHT_BULLET" }, spells_per_cast = 1 })
	local out = marks_of.collect(sim, { 0, 1 }, { 0, 1 })
	eq("a chain split across slot rows is not underlined", #out, 0)
end

-- the overlay turns each planned mark into one line
do
	function GuiColorSetForNextWidget() end
	local images = 0
	function GuiImage() images = images + 1 end
	local overlay = dofile_once("mods/spell_bracket_visualizer/files/grouping_overlay.lua")
	local _, planned = plan({ "DAMAGE", "LIGHT_BULLET", "LIGHT_BULLET" }, { [3] = 0 })
	overlay._test.draw_marks(nil, planned, 640, { { top = 100, bot = 112 } }, { n = 0 })
	eq("draw_marks: one line per mark", images, #planned)
end

print(failures == 0 and "ALL PASS" or (failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
