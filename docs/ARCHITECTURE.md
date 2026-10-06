# Architecture

This document explains how the mod decides what to draw, and which file owns
which decision. If you only want to use the mod, the README is enough.

## The one idea: run the game's own cast code

Earlier versions of this mod carried a hand-written simulator: a table saying
how many cards each spell draws, plus a re-implementation of the engine's draw
rules. Every spell that behaved differently (the Greek letters, Divide By,
Add Trigger, RESET) needed its own special case, and every special case was a
guess about the engine.

The mod now does what [WandDBG](https://github.com/kaliuresis/WandDBG) does:
it **runs the game's real `gun.lua`** over a copy of the wand, inside a
sandbox, and records what happened. Nothing about the draw rules is
re-implemented here, so when the engine does something surprising (Alpha as the
first card copies itself until the recursion limit; Divide By re-runs its
target several times) the panel shows exactly that.

> Credit: the sandboxed-evaluation approach and the fake-world stand-ins in
> `engine_stubs.lua` follow kaliuresis' WandDBG (`files/debugger.lua`). The game
> files themselves belong to Nolla Games and are read from the player's own
> install at runtime; none are shipped with the mod.

## What a bracket means

> A bracket encloses exactly the cards the engine **removed from the deck**
> while executing the bracket's head card.

The tracer therefore never asks "how many cards does this spell draw?". It
watches `table.remove` on the deck and attributes each removal to the card
whose body was running at that moment. A multicast's bracket is whatever it
pulled out; a trigger's is its payload; a modifier's is the card it modified.
RESET replaces the whole deck table, so its bracket is "everything it cleared".
A card a spell merely *re-casts* (Divide By, Alpha) stays in the deck, so it is
shown as a re-cast child (`again: ... xN`), not as part of a bracket.

## Data flow

```
 wand in the inventory
        |  grouping_overlay.read_deck / read_config
        v
 { tokens, always, spells_per_cast, uses, shuffle }
        |  wand_sim_cache  (skip the work if the wand has not changed)
        v
 wand_structure.simulate(engine, wand)
        |  engine.run(wand)            -> raw recording (a tree of nodes)
        |  re-shape                    -> expressions, spans, flags
        v
 { casts = { { nodes = { expression... }, mana, wrapped, ... } } }
        |
        v
 grouping_overlay: panel rows + slot-bracket glyphs
```

## Files and their single responsibility

### Engine layer (`files/engine/`) - "what does the game do?"

| File | Responsibility |
| --- | --- |
| `engine.lua` | The only entry point: wires the four pieces below and exposes `run`, `knows`, `name_key`, `action_type`. |
| `game_env.lua` | The sandbox. Noita exposes no `load`/`loadstring`, so (like WandDBG) the cast code runs in the global table, which is OVERLAID for the duration of each call: every CamelCase function (the engine API) is replaced by a counting no-op, the sandbox's own state is applied, and afterwards everything is restored exactly (even after an error). The cast code never reaches a real engine function; Lua's own functions and Noita's `dofile` internals stay available. |
| `engine_stubs.lua` | Stand-ins for the Noita API that spell bodies call: no-ops, a fake player/world for the reads that steer drawing, a deterministic RNG, and a report of everything that had to be guessed (reads of values nobody supplied) plus the values each run depended on. |
| `live_world.lua` | Reads the state the conditional spells check (HP, wallet, nearby enemies/projectiles, every-other toggle) from the LIVE game, read-only and outside the sandbox, so those spells are answered truthfully instead of guessed. |
| `cast_tracer.lua` | Hooks around `gun.lua` that record each cast as a tree of nodes (spans of removed slots, wraps, cleared decks, uncertainty). Pure observation; it changes nothing. |
| `wand_runner.lua` | The protocol for operating `gun.lua` from outside (load deck, start shot, play always-casts, draw, reload), repeated until the wand recharges. |
| `lua_compat.lua` | The one place LuaJIT (the game) and Lua 5.3+ (offline tools) differ: `unpack`. |

### Presentation-independent logic (`files/`)

| File | Responsibility |
| --- | --- |
| `wand_structure.lua` | Re-shapes the raw recording into the expression tree the overlay draws: folds modifiers into their head, groups multicasts, detects the Add Trigger scan, folds identical re-casts, computes slot spans. It decides nothing about game rules. Its header documents the output shape. |
| `slot_marks.lua` | Plans the extra marks on the slot row (underline a modifier chain, strike a card that never fired, dot a card a Greek letter copied). Pure: slots in, columns out. |
| `wand_sim_cache.lua` | Memoises simulations keyed by the wand's contents, so the engine runs once per change rather than once per frame. |

### Overlay (`files/`) - "how is it drawn?"

| File | Responsibility |
| --- | --- |
| `grouping_overlay.lua` | Reads the live wand, builds the engine lazily on the first frame (after every mod appended its spells), and draws the panel and the slot brackets. |
| `wand_sprite_meta.lua` | Generated table of wand sprite sizes for the box-layout model. |

### Tools (`tools/`) - not shipped in the release zip

| File | Responsibility |
| --- | --- |
| `test_support.lua` | Loader and engine factory shared by every offline test. |
| `test_wand_structure.lua` | Expression-shape tests against the real engine. |
| `test_sandbox_swap.lua`, `test_slot_delims.lua`, `test_slot_marks.lua`, `test_panel_rows.lua`, `test_font_compat.lua` | Bracket planner, mark planner, panel row clamp, font-safety layout. |
| `preview_wand.lua` | Print any wand's brackets and expression tree in the terminal. |
| `extract_gun.py` | Copy `gun.lua` and friends out of the player's `data.wak` into the git-ignored `.gun_ref/`. |

## Spells that get special treatment

Most cards are presented exactly as the engine recorded them. Three families
need a little more, and each one is derived from the recording, not guessed:

**Divide By.** The engine's own loop runs the card after it N times (and the
target of a Divide By can be a Divide By). Divide By is recognised by the one
thing only it does: its body returns an iteration count. The runs of its target
are pooled into one node, so a chain collapses to `[Divide 3, Divide 2] Light
Bullet x6`, where 6 is simply how many times the engine ran the bullet (the
depth cut-off that drops a deep Divide By to one run is the engine's, not ours).
Identical neighbours fold (`Divide 4 x3`). A target that draws pulls itself back
off the deck, so a modifier under a Divide By is reported as the thing that
repeats (`Damage x3`) rather than as extra bullets.

**Greek letters (and any card that re-runs another).** A re-cast keeps the slot
of the card whose body ran (`sources`). The panel says `(copies slot 3)` and the
wand gets a small dot above that card, one per copier. A card copying itself
(Alpha as the first card) is not marked.

**Add Trigger / Add Timer / Add Expiration Trigger.** The recording says what
left the deck but not why a scan that left nothing stopped, so the body's
decision is replayed over the deck as it stood when the body began
(`analyse_scan` in `wand_structure.lua`): modifiers it steps over are applied if
they still have charges and discarded either way; passives, multicasts and other
scanners are stepped over with no effect; the scan fails (nothing consumed, the
cards stay in the wand) when it runs off the end of the deck, lands on a card
with no trigger version, or lands on a depleted card; and with no card left to
carry a payload the target fires plainly. The replay is checked against what the
tracer saw the body pull out of the deck (`pulled`); a disagreement is flagged,
never shown.

## Uncertainty

The conditional spells (If HP, If enemies, Every Other...) branch on game state,
so the sandbox needs a world to answer from. Each value in it is either

- **known**: `live_world.lua` read it from the running game (HP, wallet, enemies
  and projectiles nearby, the every-other toggle). Reading a known value is not a
  guess, so the wand stays certain; the structure shown is the one the game would
  produce *right now*. The value is recorded on the result (`deps`), and the
  simulation cache recomputes the wand as soon as a value it consulted changes
  (and only then); or
- **guessed**: nobody supplied it, so it sits at a default (full health, nothing
  nearby...). Reading it counts as a guess.

A card whose body made a guess, drew a random number, or called an engine
function the sandbox does not model is marked **uncertain**: its name gets a `?`
in the panel, and the wand's slot brackets are hidden by default (setting:
*Uncertain Wands*). State the sandbox owns itself (what a spell wrote with
`GlobalsSetValue` earlier in the same run) is bookkeeping and never a guess.
Radii are the one approximation: the sandbox counts per tag, so `live_world.lua`
measures the radii vanilla uses (240 px enemies, 160 px projectiles).

## Running the tests

```
python3 tools/extract_gun.py            # once: needs your Noita install
texlua tools/test_wand_structure.lua    # or any Lua 5.1+ / LuaJIT
texlua tools/test_slot_delims.lua
texlua tools/test_panel_rows.lua
texlua tools/test_live_world.lua
```

`.gun_ref/` holds Nolla's game files: it is git-ignored and never ships.

## Not verified outside the game

The offline tests cannot exercise the game's own `dofile` (how the mod loads
`gun.lua` and whether it applies other mods' `ModLuaFileAppend` spells), that
Noita's engine API really is all CamelCase (the overlay neutralises functions
by that rule), or the engine's per-frame cost on a large inventory. These need
a play-test.
