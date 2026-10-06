#!/usr/bin/env lua5.4
-- Preview a wand's slot brackets in the terminal, without the game.
--
--     lua tools/preview_wand.lua CHAINSAW,CHAINSAW,BURST_2,SPITTER,BURST_2,SPITTER
--     lua tools/preview_wand.lua TNTBOX,TNTBOX,HORIZONTAL_ARC,...  --per-cast=2
--
-- Prints the delimiters as a Lisp line -- the notation the brackets are meant
-- to read as -- coloured with the ACTUAL rainbow the mod would draw:
--
--     [ Chainsaw, Chainsaw, [Double spell, Spitter [Double spell, Spitter]] ]
--
-- It drives the REAL collect_wand_delims and plan_delims (via _test), so the
-- nesting, the colours, the cast brackets, the single-spell suppression and the
-- wrap enclosure are exactly what the mod would put on the slot row. It cannot
-- check the parts calibrated against screenshots -- where the wand box sits, how
-- tall the slot row is, how the glyphs land on the card art -- so it answers
-- "is the structure right?", not "does it look right in game".
--
-- Options:
--   --per-cast=N   spells per cast (default 1)
--   --cols=A,B,..  real slot column of each card, for wands with empty slots
--                  (default: card i sits in column i-1)
--   --plain        no ANSI colour
--   --glyphs       also dump the raw glyph list (side, column, stack level)
--   --uncertain    name the cards whose behaviour depended on a guess (an "If"
--                  spell, a random draw...), if any
--   --tree         also print each cast's expression tree as a Lisp line,
--                  re-casts marked *N (e.g. Divide By)
--   --mana         mana cost per cast
--   --uses=SLOT:N,SLOT:N
--                  charge counts (uses_remaining) for depleted-spell tracking

local here = arg[0]:match("^(.*)[/\\]") or "."
local support = dofile(here .. "/test_support.lua")
support.install_mod_loader()
local engine = support.new_engine()

-- grouping_overlay only calls these when it DRAWS; loading it needs them to
-- exist because the file is one chunk.
function GuiZSet() end
function GuiColorSetForNextWidget() end
function GuiImage() end
function GuiText() end
function GuiGetTextDimensions() return 0, 0 end

local S = dofile_once("mods/spell_bracket_visualizer/files/wand_structure.lua")
local T = assert(dofile_once("mods/spell_bracket_visualizer/files/grouping_overlay.lua")._test,
	"grouping_overlay.lua did not return its _test exports")

-- ---- args ------------------------------------------------------------------

local spells, per_cast, cols_arg, plain, show_glyphs = nil, 1, nil, false, false
local show_uncertain, show_mana, show_tree, uses_arg = false, false, false, nil
for _, a in ipairs(arg) do
	if a == "--plain" then plain = true
	elseif a == "--glyphs" then show_glyphs = true
	elseif a == "--uncertain" then show_uncertain = true
	elseif a == "--tree" then show_tree = true
	elseif a == "--mana" then show_mana = true
	elseif a:match("^%-%-per%-cast=") then per_cast = tonumber(a:match("=(.+)")) or 1
	elseif a:match("^%-%-cols=") then cols_arg = a:match("=(.+)")
	elseif a:match("^%-%-uses=") then uses_arg = a:match("=(.+)")
	elseif a:match("^%-%-") then
		io.stderr:write("unknown option: " .. a .. "\n"); os.exit(2)
	else spells = a end
end
if not spells then
	io.stderr:write("usage: lua tools/preview_wand.lua SPELL,SPELL,... " ..
		"[--per-cast=N] [--cols=A,B,...] [--plain] [--glyphs] [--uncertain] [--tree] [--mana] [--uses=SLOT:N,SLOT:N]\n")
	os.exit(2)
end

local tokens = {}
for id in spells:gmatch("[^,%s]+") do tokens[#tokens + 1] = id:upper() end
if #tokens == 0 then io.stderr:write("no spells given\n"); os.exit(2) end

local unknown = {}
for _, id in ipairs(tokens) do
	if not engine.knows(id) then unknown[#unknown + 1] = id end
end
if #unknown > 0 then
	-- The engine refuses a wand holding a spell the game does not define, so an
	-- id typo is reported rather than silently changing the structure.
	io.stderr:write("error: not a spell the game defines: "
		.. table.concat(unknown, ", ") .. "\n")
	os.exit(2)
end

local cols, rows = {}, {}
if cols_arg then
	local i = 0
	for c in cols_arg:gmatch("[^,%s]+") do i = i + 1; cols[i] = tonumber(c) end
end
for i = 1, #tokens do
	cols[i] = cols[i] or (i - 1)
	rows[i] = 0
end

local uses = {}
if uses_arg then
	for pair in uses_arg:gmatch("[^,%s]+") do
		local slot, n = pair:match("^([^:]+):(.+)$")
		if not slot or not n then
			io.stderr:write("malformed --uses value: " .. pair .. "\n"); os.exit(2)
		end
		slot = tonumber(slot)
		n = tonumber(n)
		if not slot or not n then
			io.stderr:write("malformed --uses value: " .. pair .. "\n"); os.exit(2)
		end
		uses[slot] = n
	end
end

-- ---- colour ----------------------------------------------------------------

local function paint(text, c)
	if plain or not c then return text end
	return string.format("\27[38;2;%d;%d;%dm%s\27[0m",
		math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255), text)
end

local function pretty(id)
	local s = tostring(id):gsub("_", " "):lower()
	return (s:gsub("(%a)([%w]*)", function(a, b) return a:upper() .. b end))
end

-- ---- build ------------------------------------------------------------------

local sim = S.simulate(engine, { tokens = tokens, spells_per_cast = per_cast,
	uses = next(uses) and uses or nil })
if sim.error then io.stderr:write("error: " .. sim.error .. "\n"); os.exit(1) end
local groups = T.collect_wand_delims(sim, cols, rows)
local glyphs = T.plan_delims(groups)

-- card sitting in each displayed column
local card_at = {}
local maxcol = 0
for i, id in ipairs(tokens) do
	card_at[cols[i]] = pretty(id)
	if cols[i] > maxcol then maxcol = cols[i] end
end

-- glyphs by column and side; outermost (highest stack) is drawn furthest out,
-- so opens print outer -> inner and closes inner -> outer
local at = {}
for _, gl in ipairs(glyphs) do
	local k = gl.col .. ":" .. gl.side
	at[k] = at[k] or {}
	table.insert(at[k], gl)
end
for k, list in pairs(at) do
	local left = k:match(":(.+)$") == "left"
	table.sort(list, function(a, b)
		if left then return a.stack > b.stack else return a.stack < b.stack end
	end)
end

-- one piece per displayed column: its opening brackets, the card, its closing
-- brackets. An empty slot shows as "." -- it still occupies a column, and a
-- bracket can land on the gap beside it.
local out = {}
for col = 0, maxcol do
	local piece = {}
	for _, gl in ipairs(at[col .. ":left"] or {}) do piece[#piece + 1] = paint("[", gl.c) end
	piece[#piece + 1] = (card_at[col] or ".")
	for _, gl in ipairs(at[col .. ":right"] or {}) do piece[#piece + 1] = paint("]", gl.c) end
	out[#out + 1] = table.concat(piece)
end

-- ---- print ------------------------------------------------------------------

print()
print(string.format("%d spells, %d per cast, %d cast%s%s",
	#tokens, per_cast, #sim.casts, #sim.casts == 1 and "" or "s",
	sim.wrapped and "  -- WRAPS" or ""))

if show_uncertain then
	local ids = S.uncertain_ids(sim)
	print(#ids == 0 and "certain: nothing depended on a guess"
		or "uncertain: " .. table.concat(ids, ", "))
end

print()
print("  " .. table.concat(out, ", "))
print()

for ci, cast in ipairs(sim.casts) do
	local names = {}
	for _, n in ipairs(cast.nodes) do names[#names + 1] = pretty(n.id) end
	local suffix = ""
	if show_mana then
		local mana_str
		if cast.mana == math.floor(cast.mana) then
			mana_str = string.format("%d", cast.mana)
		else
			mana_str = string.format("%g", cast.mana)
		end
		suffix = suffix .. "  mana=" .. mana_str
	end
	if cast.spent and #cast.spent > 0 then
		suffix = suffix .. "  spent: " .. table.concat(cast.spent, ", ")
	end
	print(string.format("  cast %d: slots %s..%s%s   (%d spell%s: %s)%s",
		ci, tostring(cast.first), tostring(cast.last),
		cast.wfirst and ("  WRAPS in " .. cast.wfirst .. ".." .. cast.wlast) or "",
		#cast.nodes, #cast.nodes == 1 and "" or "s", table.concat(names, ", "), suffix))
end
if show_tree then
	-- The expression tree as a Lisp line: "(head child child)", modifiers in [ ].
	local function lisp(e)
		local text = (#e.modifiers > 0 and ("[" .. table.concat(e.modifiers, ",") .. "] ") or "")
			.. pretty(e.id)
		if e.recast then
			text = text .. " *" .. (e.count or 1)
			if e.sources then text = text .. " (copies slot " .. table.concat(e.sources, ",") .. ")" end
		end
		if e.runs then text = text .. " x" .. e.runs end
		if e.trigger_failed then text = text .. " !" .. e.trigger_failed end
		if e.no_payload then text = text .. " !plain" end
		if e.swept then
			local parts = {}
			for _, c in ipairs(e.swept) do parts[#parts + 1] = c.id .. ":" .. c.effect end
			text = text .. " <swept " .. table.concat(parts, ",") .. ">"
		end
		if #(e.children or {}) == 0 then return text end
		local kids = {}
		for _, c in ipairs(e.children) do kids[#kids + 1] = lisp(c) end
		return "(" .. text .. " " .. table.concat(kids, " ") .. ")"
	end
	for ci, cast in ipairs(sim.casts) do
		local parts = {}
		for _, n in ipairs(cast.nodes) do parts[#parts + 1] = lisp(n) end
		print(string.format("  cast %d: %s", ci, table.concat(parts, "  ")))
	end
	print()
end
print()
print(string.format("  %d delimiter%s:", #groups, #groups == 1 and "" or "s"))
for _, g in ipairs(groups) do
	print(string.format("    %s  columns %d..%d%s",
		paint("[ ]", g.c), g.ca, g.cb, g.wrap and "   the WRAP enclosure" or ""))
end

if show_glyphs then
	print()
	for i, gl in ipairs(glyphs) do
		print(string.format("    glyph %2d  %-5s col %2d  stack %d%s",
			i, gl.side, gl.col, gl.stack, gl.label and ("  \"" .. gl.label .. "\"") or ""))
	end
end
print()
