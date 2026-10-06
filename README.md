# Spell Bracket Visualizer

A [Noita](https://noitagame.com/) mod that shows a wand's **cast structure**
Lisp/SLIME-style, so you can see at a glance which spells fire
**simultaneously** in each cast, which modifiers feed which projectile, what a
multicast gathers, what a trigger's payload is — and, crucially for rapid-fire
wands, **when the wand WRAPS** (a forced draw past the deck's end pulls cards
from the wand's start and forces the recharge).

Two views, both live while the inventory is open:

1. **Wand structure panel** (anchored to the right of the screen, tracking the
   selected wand and updating live as you rearrange spells): an indented tree
   of the held wand, one cast per section, rainbow nesting spines by depth,
   spell names colored by action type. Wrapping casts get a loud orange
   `WRAPS! -> recharge` banner and wrapped-in cards are marked `~`. It pins to
   the selected wand's box when the structure is short and takes over the full
   right column when it isn't, drawing opaque and on top so it stays readable;
   long structures clamp to the screen (`... +N more`) instead of overflowing.
2. **Slot brackets** (in the wand UI itself): `[ ]` bracket glyphs hugging
   each group's first and last card — SLIME rainbow parens, color cycling by
   nesting depth, no text labels (the card art already says what the group
   is). Leading modifiers sit *outside* the brackets, matching Lisp
   notation. **Casts are bracketed too**, one level outside the groups they
   contain, so what fires together is visible at a glance; the rainbow is one
   continuous progression across both axes, advancing per cast *and* per
   nesting level. A cast firing a single spell isn't bracketed — there is no
   simultaneity to show. Brackets that share a card edge stack outward from it,
   the outermost's hooks reaching past the inner ones.
   **Orange marks the wrap**: one enclosing bracket around the whole looping
   structure, from the first card the wrap pulled back in to where the cast ran
   out of deck, tagged `wraps to front` at its closing end:

   ```
   [ chainsaw, chainsaw, [Double spell, Spitter [Double spell, Spitter]] ]
   ^ the wrap                                              closing wrap ^
   ```

## Install

**Steam:** subscribe on the
[Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3743473994).

**Everyone else (GOG / DRM-free / by hand):** grab the zip from the
[latest release](https://github.com/dontoisme/spell_bracket_visualizer/releases/latest)
and extract it into your Noita `mods` folder (the one next to `noita.exe`), so
that `Noita/mods/spell_bracket_visualizer/init.lua` exists. Then enable
**Spell Bracket Visualizer** in the game's Mods menu.

The folder must be named exactly `spell_bracket_visualizer` — the mod loads its
own files by that path, so GitHub's green "Download ZIP" button (which produces
`spell_bracket_visualizer-main`) will *not* work unless you rename it. The
release zip is already laid out correctly and contains only the files the game
needs; `INSTALL.txt` inside it has the long-form walkthrough and troubleshooting.

## How it works

**What a bracket means**

> A bracket encloses exactly the cards the engine removed from the deck
> while executing the bracket's head card. A cast bracket encloses the
> cards removed from the deck during one cast. A card a spell re-casts by
> reference (Alpha, Omega, …) is not removed, so it is never inside a
> bracket — the panel names it as a copy instead.

Trigger payloads stay nested because they're consumed by the forced draw
even though they fire later. Re-casts (Divide By, the Greek letters) are shown
as children marked `again:` with a `xN` count, since the card they copy stays
in the deck.

**Where the structure comes from.** The mod does not model the game's draw
rules: it **runs the game's own `gun.lua`** over a copy of your wand inside a
sandbox (`files/engine/`) and records which cards each spell removed from the
deck. That is the approach of [WandDBG](https://github.com/kaliuresis/WandDBG)
by kaliuresis, and it means Divide By, Alpha, RESET, Add Trigger, wraps and
depleted spells all behave exactly as in the game. Always-cast spells are
listed separately (they join every cast). Shuffle wands show nothing at all —
their draw order randomizes each cycle, so there is no fixed structure to
display. See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full design.

The engine renders the inventory itself (no Lua hook exposes slot or box
positions), so the panel draws on its own Gui at safe coordinates, while the
slot brackets use a calibrated model of the wand-box layout: a wand's box height
is driven by its sprite THICKNESS (`26.9 + 1.25 x art height` engine units, read
live via `GuiGetImageDimensions`, with `wand_sprite_meta.lua` as the offline
lookup), and boxes stack from there — so brackets stay put across wand pickups,
reordering, and selection changes.

## Settings (in the in-game mod settings menu)

All settings are runtime-scoped and apply immediately.

- **Wand Structure Panel** — the text tree on/off.
- **Wand Structure Panel: Text Size** — Tiny / Small / Medium / Large. With a
  font mod (e.g. Better Font) or a language with a smooth non-pixel font
  (Japanese, …) the game ignores the smaller sizes; the panel detects that and
  switches itself to **Large** automatically (see `docs/FONT_COMPAT.md`).
- **Long rows in the panel** — a row too wide for the panel is cut with `...`:
  hover it to read the full text in a tooltip, click it to open it in place
  (click again to close). A structure taller than the screen scrolls with
  **PageUp / PageDown**. (No setting: this is always on.)
- **Slot Brackets** — the in-UI rainbow brackets (on by default).
- **Slot Marks** — an underline under a modifier chain (the modifiers and the
  card they modify) and a red strike through cards that are drawn but never
  fire: depleted spells, cards a failed IF threw away, plus a small dot above a
  card that a Greek letter (or Double Spell...) copied, one dot per kind of
  copier, each in its own colour (on by default).
- **Ignore Depleted Spells** — model spells with 0 charges the way the game
  does it (they're skipped and the next card drawn instead), giving the right
  wand structure and wrap points. Turn off to pretend every card fires,
  depleted or not (on by default).
- **Uncertain Wands: Slot Brackets** — a wand holding a spell whose behaviour
  depended on a guess (an IF spell reading the world, a random draw, an engine
  call the sandbox can't model) draws no slot brackets by default and shows a
  small `?` at the end of the row; Hide keeps that rule, Show draws the
  brackets anyway for players who want the approximation (Hide by default).
- **Debug Info (for bug reports)** — resolution/GUI readout plus per-box guide
  lines; screenshot this if the brackets ever misalign.

## Project layout

```
init.lua                        # OnWorldPostUpdate: drives the overlay
settings.lua                    # mod settings menu
files/engine/                   # runs the game's own gun.lua in a sandbox
  engine.lua                    #   single entry point
  game_env.lua                  #   the sandbox + game file loader
  engine_stubs.lua              #   fake Noita API / world, uncertainty report
  live_world.lua                #   reads HP, enemies... from the live game
  cast_tracer.lua               #   records each cast as a tree of nodes
  wand_runner.lua               #   the protocol for firing a wand
  lua_compat.lua                #   LuaJIT / Lua 5.3 differences (unpack)
files/wand_structure.lua        # re-shapes the recording into the expression tree
files/wand_sim_cache.lua        # one simulation per wand change, not per frame
files/slot_marks.lua            # which cards get an underline / strike-through (pure)
files/grouping_overlay.lua      # reads the live wand + draws panel / slot brackets
files/wand_sprite_meta.lua      # generated wand sprite sizes (box layout)
tools/test_support.lua          # shared loader / engine factory for the tests
tools/test_wand_structure.lua   # expression-shape tests against the real engine
tools/test_slot_delims.lua      # slot-bracket planner (nesting, casts, wrap)
tools/test_panel_rows.lua       # panel row clamp (+N more fold, sticky legend)
tools/test_slot_marks.lua       # underline / strike planning + drawing
tools/test_font_compat.lua      # non-pixel-font layout checks
tools/preview_wand.lua          # print any wand's brackets / tree, no game needed
tools/extract_gun.py            # copy gun.lua etc. out of data.wak into .gun_ref/
tools/gen_icons.py              # (retired icon-recolor feature; see below)
tools/make_release.sh           # builds dist/<mod>-<version>.zip for manual installs
INSTALL.txt                     # manual-install guide (shipped in the release zip)
docs/ARCHITECTURE.md            # how the pieces fit, and why
mod.xml, compatibility.xml
workshop.xml                    # Steam Workshop manifest (name/desc/tags/excludes)
```

## Testing

1. Enable **Spell Bracket Visualizer** in the mod menu, start/continue a run.
2. Hold a wand and open the inventory: the panel docks beside its box; with
   Slot Brackets enabled, rainbow strips mark each group in the wand boxes.
3. `python3 tools/extract_gun.py` once (writes the gitignored `.gun_ref/` from
   your own Noita install), then `lua tools/test_wand_structure.lua` runs the
   expression-shape tests against Noita's real `gun.lua`; they need the game's
   files, so they are local-only.
4. `lua tools/test_slot_delims.lua` runs the real slot-bracket planner —
   nesting depth, cast brackets, the wrap enclosure, stacking on a shared card
   edge, wands with empty slots.
5. `lua tools/test_slot_marks.lua` runs the underline / strike planner and its
   drawing against the real engine.
6. `lua tools/test_panel_rows.lua` runs the real panel row clamp — the
   `... +N more` fold and the sticky `?` legend that has to survive it.
7. `lua tools/test_font_compat.lua` validates the non-pixel-font fixes
   (`docs/FONT_COMPAT.md`) by driving the real panel layout with stubbed
   pixel-like / zero-measuring / nil-returning fonts, then prints the in-game
   checklist for verifying against the Better Font mod or a TTF language.

To eyeball a specific wand without starting a run, `tools/preview_wand.lua`
prints its delimiters as a Lisp line, coloured with the rainbow the mod would
actually draw:

```
$ lua tools/preview_wand.lua CHAINSAW,CHAINSAW,BURST_2,SPITTER,BURST_2,SPITTER

  [Chainsaw, Chainsaw, [Burst 2, Spitter, [Burst 2, Spitter]]]
```

It drives the same `collect_wand_delims`/`plan_delims` the overlay does, so the
structure is exactly what would land on the slot row. It says nothing about the
*geometry* — where the wand box sits, how the glyphs meet the card art — which
is calibrated from screenshots and still needs the game.

Pass `--uncertain` to name any cards whose behaviour depended on a guess, `--tree` to print each cast's expression tree as a Lisp line (re-casts marked `*N`), e.g. `lua tools/preview_wand.lua DIVIDE_3,LIGHT_BULLET --tree --mana`.
Pass `--mana` to print the mana cost of each cast alongside the spells it contains.
Pass `--uses=SLOT:N,SLOT:N` to mark depleted spells (0 charges) for the engine to track through wraps, e.g. `lua tools/preview_wand.lua LIGHT_BULLET,LIGHT_BULLET,DAMAGE --per-cast=1 --uses=3:0 --mana`.

Unsafe Lua APIs are not requested (`request_no_api_restrictions="0"` in `mod.xml`).

## Retired: icon recolor

The mod originally re-pointed every vanilla spell's icon at a generated copy
with a type-colored border (red projectile, blue modifier, …). It was retired
2026-06-09 — the rainbow brackets made the borders redundant visual noise.
To revive it: `git log` for `files/recolor_actions.lua` / `files/known_ids.lua`
and the `OnModInit` hook in `init.lua`, and regenerate the icons with
`python3 tools/gen_icons.py`.

## Known limitations

- The cast code runs in a sandbox with a *fake* world (no enemies nearby, full
  health, a fixed random sequence). Spells that read it — the Requirement (If)
  spells, the random-draw spells, Zeta — are marked `?`, and their wand hides
  its slot brackets by default (see the setting above).
- Spells added by other mods are simulated like vanilla ones (their code is
  read from the live `gun_actions.lua`), unless they call an engine function
  the sandbox doesn't model; those are marked `?` too.
- The panel can't know your mana, so a cast that fizzles mid-way on mana may
  differ from the simulation. (Depleted 0-charge spells *are* handled — see
  the settings above.)
- Shuffle wands get **no panel and no brackets** — the real draw order
  randomizes each cycle, so any displayed structure would be just one
  arrangement of many.
- With a non-pixel UI font — font mods ("Better Font") and the smooth-font
  languages (Japanese, …) — Noita ignores fractional text scales when *drawing*
  while still shrinking them when *measuring*, so the panel used to be built
  ~3× too small for its own text and spilled off the right edge of the screen.
  v1.3.1 detects that from the engine's own measurements and pins the panel to
  the one scale where the two agree (Large); on the vanilla pixel font nothing
  changes and your chosen size is kept. Analysis: `docs/FONT_COMPAT.md`.
- The slot brackets' geometry is a *model* of the engine's wand-box layout (no
  Lua API exposes the real positions). It's calibrated against GUI 640×360 and
  scaled by that constant, so it holds at every GUI resolution Noita produces,
  but an unusual wand sprite can still sit ~1 engine unit off, and a game update
  could shift the layout. Turn on **Debug Info** and send a screenshot if so;
  the panel is always reliable regardless.

## Credits

The idea of evaluating a wand by running the game's real cast code in a
sandbox comes from [WandDBG](https://github.com/kaliuresis/WandDBG) by
kaliuresis; the fake-world stand-ins in `files/engine/engine_stubs.lua` follow
its approach. Noita and its game files belong to Nolla Games; the mod reads
them from the player's own install and ships none of them.
