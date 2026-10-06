# Grouping brackets (Lisp/SLIME-style) — design

> **Note.** The bracket *definition* below still holds. The implementation notes
> that mention `structure_meta.lua` / `M.build` describe the earlier hand-written
> simulator; the current pipeline is in `ARCHITECTURE.md`.

**Goal:** show a wand's *cast structure* — which modifiers feed which projectile,
which cards a multicast gathers, and what a trigger's payload is — as nested
brackets, the way SLIME shows Lisp expression structure.

## What a bracket means (the definition)

> A bracket encloses exactly the cards the engine removed from the deck
> while executing the bracket's head card. A cast bracket encloses the
> cards removed from the deck during one cast. A card a spell re-casts by
> reference (Alpha, Omega, …) is not removed, so it is never inside a
> bracket — the panel names it as a copy instead.

This is definition #4 of KoObEy's four candidates (drawn / executed / same shot
state / no longer in deck), and the only one a deck-stream visualizer can honor
without simulating the engine at runtime.

Status: **shipped on `main` 2026-06-09** (the `grouping-brackets` branch was
merged and deleted) — companion panel with cast grouping + wrap detection,
plus the in-UI rainbow slot brackets with the orange wrap carriage-return
line. Both on by default. See `STATUS.md` for the full iteration history.

## How Noita actually builds a shot (verified from data.wak)

`data/scripts/gun/gun.lua` resolves a shot by popping cards off **one flat deck**
in order (`draw_action` → `deck[1]`). Structure comes from three mechanisms:

| Mechanism | Engine call | Structural meaning |
| --------- | ----------- | ------------------ |
| **Multicast** (`DRAW_MANY`, e.g. BURST_2, CIRCLE_SHAPE) | `draw_actions(N)` | the next **N** drawn cards join this shot as a group |
| **Trigger / timer** projectile (e.g. SPARK_BOLT_TRIGGER, DELAYED_SPELL) | `add_projectile_trigger_*(entity, [delay,] count)` → `draw_shot(create_shot(count))` | opens a **nested sub-shot** of `count` cards as the payload |
| **Modifier** (`ACTION_TYPE_MODIFIER`) | mutates shot state `c.*` | prefix-attaches to the projectile it precedes |

Because draws are sequential from one stream, a wand's deck parses like a Lisp
token stream: multicast/trigger counts introduce sub-expressions. This is fully
derivable **statically** from each card's metadata — no need to run the engine.

## Casts and wand wrapping (verified from gun.lua, 2026-06-09)

The two facts the user actually builds wands around — *what fires together* and
*when the wand wraps* — fall out of `draw_action(instant_reload_if_empty)`:

- **A cast** (`_start_shot` → `_draw_actions_for_shot`) draws
  `gun.actions_per_round` (the wand's *spells/cast*) root expressions, passing
  `instant_reload_if_empty = false`: if the deck is empty on a root draw, the
  cast simply ends (and the cycle reloads). **Root draws never wrap.**
- **Every card-forced draw passes `true`**: all 203 `draw_actions(N, ...)` calls
  in `gun_actions.lua` pass `true`, and trigger payloads use
  `draw_shot(create_shot(N), true)`. On a forced draw with an empty deck the
  engine calls `move_discarded_to_deck()` + `order_deck()` — **the WRAP**: cards
  cast earlier this recharge cycle come back (sorted by `deck_index`, i.e. slot
  order, for non-shuffle wands; shuffled otherwise) and drawing continues from
  the wand's start. It also sets `start_reload`, so the recharge cycle ends
  after the wrapping cast — cards after that point never fire that cycle.
- **Chaining is decided by the card's body, not its type.** A card that calls
  `draw_actions(1, true)` consumes itself and pulls the next card — that is what
  "modifier" means structurally. 142/143 MODIFIERs and all 5 PASSIVEs do this,
  but so do 13 OTHERs (ALPHA, GAMMA, DUPLICATE, …) and 11 UTILITYs (I_SHOT, …).
  `RANDOM_MODIFIER` draws nothing → terminates a chain. `BURST_X` draws `#deck`
  (the whole remaining deck) → recorded as `draws = -1`.

`structure_meta.lua` therefore carries a `draws` field per card, and
`wand_structure.lua` is a **deck simulator**, not just a parser:
`M.simulate(tokens, meta, { spells_per_cast = N })` returns
`{ casts = { { nodes, wrapped }, ... }, wrapped }`, with `wrap = true` on every
node parsed across a wrap (the wrapping group *and* the wrapped-in cards),
`first`/`last` spans that reach back to the wand's start when wrapped,
`head` = the node's own card (the span excluding its leading-modifier prefix —
Lisp-wise modifiers sit outside the parens), and `wfirst`/`wlast` = the span
of cards drawn *after* the wrap (tagged at draw time), with `ffirst`/`flast` the
same for the cards drawn *before* it. A renderer wanting only the run an
expression occupies going forward must use `flast`, not `last`: a wrap can pull
in **more** cards than precede the head, so `last` is not even an upper bound on
the forward run.

**Casts are delimited too**, one level outside the spell groups they contain,
whenever the wand has more than one cast or wraps (the same rule the panel uses
for its cast headers). `simulate` gives each cast its own `first`/`last` —
and `wfirst`/`wlast` if it wrapped — taken straight off the hand rather than
folded out of the node spans, since a node's `first` reaches back into the
wrapped-in segment and would smear a wrapping cast across the whole wand.
The rainbow is **one continuous progression across both axes**: each cast
advances it by one and so does each nesting level inside a group, so cast `ci`
sits at depth `ci-1` and its groups start at depth `ci`. A single-cast wand
gets no cast bracket and keeps its groups at depth 0, so it renders exactly as
it did before casts were delimited.

**A cast that fires one spell expression is not bracketed** (user call
2026-08-07): there is no simultaneity to show, so the pair is pure ink — and on
a cast whose single spell *is* a group, the two spans were identical, drawing
one boundary twice in two colours. A suppressed cast still consumes its rainbow
slot, so colours don't shift when a cast gains or loses a spell.

**The wrap is one enclosing bracket** (user call 2026-08-07), not a group split
across a seam:

```
[ chainsaw, chainsaw, [Double, Spitter [Double, Spitter]] ]
^ the wrap                                    closing wrap ^
```

A wrap always pulls from the wand's **start** and the wrapping cast always runs
to the deck's **end**, so everything involved lies in one contiguous run — from
the first wrapped-in card to that cast's last forward card. One bracket around
the lot, in `WRAP_COLOR`, outside every group and cast it contains (so its
record is collected before all of them, since collection order *is* nesting
order for the stacking pass — including casts that ran before the one that
wrapped). Everything inside is an ordinary rainbow bracket over its forward run.
It is the one non-rainbow delimiter: **orange marks the wrap, the rainbow marks
nesting.**

Three earlier attempts split the group across the seam instead, and all three
were rejected in play: a self-closed *orange* wrapped half read as an unrelated
group (the original report), seam glyphs with hooks pointing outward read as a
`[`/`]` facing the wrong way, and a bar with one outward tick "doesn't look like
brackets" — two side by side read as an H. The enclosure needs no seam glyph, no
carriage return, and no second pair: the loop reads as an enclosure. A wrap
inside a bare modifier chain builds no bracketed group at all, and the enclosure
covers that case for free (before, such a wrap drew nothing on the slot row).

Glyph planning (columns, rows, colours and the per-`(row, column, side)`
stacking that keeps co-located brackets from overprinting) is pure and lives in
`plan_delims`; `tools/test_slot_delims.lua` drives it with no game APIs.

**Stacking has to be drawn as well as planned.** A bracket's hooks grow with its
stack level (`TICK_W + stack*STACK_X`) so an outer bracket reaches past
everything nested inside it; with a fixed hook shorter than `STACK_X` the outer
hooks landed on the inner bar and were overpainted by it, leaving the outer
rendered as a bare vertical line — the whole reason the brackets "aren't
brackets". It was invisible while only closing brackets ever shared a card
edge; opens and the wrap enclosure made co-location the common case. `STACK_Y` is 2
for the same reason: at 1px apart, two neighbouring levels' hooks read as one
thick hook.
Validated by `tools/test_wand_structure.lua` (runs the real simulator under Lua)
with `tools/test_wand_structure.py` as a line-for-line Python cross-check mirror,
over hand-traced wands: cast splitting,
the classic trigger-at-deck-end wrap, trailing-modifier wrap, under-filled
multicast wrap, slot-order restore on wrap, BURST_X, RANDOM_MODIFIER.

**Always-cast cards** (`permanently_attached`) never sit in the deck — the
engine plays them at the start of every cast — so the overlay reads them
separately and excludes them from the simulation (they used to corrupt the
slot mapping).

## Foundation (landed on this branch)

- **`tools/gen_structure_meta.py`** — parses `gun_actions.lua` out of `data.wak`
  and emits per-card metadata: `type`, `group` (multicast draw count),
  `trigger`/`payload` (nested sub-shot). Pure stdlib.
- **`files/structure_meta.lua`** — generated table, 422 actions
  (13 multicast, 28 trigger).
- **`files/wand_structure.lua`** — `M.build(tokens, meta)`: the pure
  deck→tree parser (recursive descent matching the rules above). No game APIs,
  so it is unit-testable. Validated against hand-traced wands (nested multicasts,
  trigger payloads, modifier attachment, dangling modifiers, under-filled
  multicasts) — see commit message / `tools` validation.

Example — deck `[DAMAGE, BURST_2, LIGHT_BULLET, LIGHT_BULLET_TRIGGER, MAGIC_BOLT]`:

```
[DAMAGE] (BURST_2 x2
  LIGHT_BULLET
  (LIGHT_BULLET_TRIGGER ->payload1
    MAGIC_BOLT))
```

## Runtime data (verified available)

- **Detect inventory open:** `GameIsInventoryOpen() -> bool`.
- **Read the wand's cards in order:** held wand entity →
  `EntityGetAllChildren(wand)`; each card child has an `ItemActionComponent`
  (`action_id`) and an `ItemComponent` (`inventory_slot` → order). Read with
  `ComponentGetValue2`. Active wand via the player's inventory
  (`GameGetAllInventoryItems(player)` + the selected quick-slot).

So both inputs the renderer needs — *is the inventory open* and *the ordered
card list* — are readily available from Lua.

## Open question: prefixes vs. the definition (raised 2026-09-09, not decided)

`Divide By 2, Spark Bolt` at 1/cast draws **no slot bracket at all**. Two rules
combine to produce that, and each was reasonable on its own:

1. **Modifiers sit outside the parens** (`f8e9f75`, 2026-06-09, user feedback
   round 2). The open bracket moved from `node.first` to `node.head` so a
   leading modifier stays outside, matching the panel's `[Light] Double
   scatter x2` notation and Lisp intuition.
2. **A single-node cast draws no cast bracket** (`grouping_overlay.lua`, the
   `#cast.nodes <= 1` drop, user call 2026-08-07). A bracket around one spell
   that is not itself a group is pure ink.

Together they mean a wand whose whole cast is "one prefix + one projectile" has
its bracket eliminated from both directions: the node is a leaf so it gets none
of its own, and the cast has one node so the cast bracket is dropped.

**Why this is now worth revisiting.** v1.4.0 published a definition (§1): *a
bracket encloses exactly the cards the engine removed from the deck while
executing the bracket's head card*. Divide By 2 **does** remove Spark Bolt from
the deck — that is precisely why it is a prefix and not a wrapper. So the
definition says there is something to enclose here, and the display says there
isn't. The two rules predate the definition and were never checked against it.

Note the tension is not academic for Divide specifically: Divide is the one
"modifier-like" card whose consumption of the next card is the whole point, and
it is the card KoObEy asked to have hidden. Drawing nothing at all says less
than either alternative.

**Options, none costed yet:**

- *Leave it.* Prefix + one spell is legible without a bracket, and the panel row
  already shows `[Divide by 2] Spark Bolt`. Cheapest; the definition then has a
  stated display exception.
- *Bracket the head alone* (`[Spark Bolt]` with Divide outside). Honours both
  existing rules but puts a bracket around a single card, which rule 2 called
  pure ink.
- *Bracket the consumption span* (`[Divide by 2, Spark Bolt]`). Matches the
  definition literally, and contradicts rule 1 for exactly the cards whose
  prefix-ness comes from consuming.
- *Split the rule by cause*: modifiers that merely mutate shot state stay
  outside (rule 1 intact); cards that CONSUME the next card — `chain=true`
  Divides, and the Add Trigger scan — bracket what they consumed. This is the
  only option where the drawn bracket and the published definition agree for
  every card, and it is a small change to `collect_delims`.

Whatever is chosen, `README.md` (":23"), `docs/workshop_description.bbcode`
("Reading the brackets") and §1 of the plan all state the convention and would
need to move together. Decide after v1.4.0 ships; changing it now would
invalidate the screenshots 1.4.0 was verified against.

## Open decision: rendering

The wand spell **inventory is rendered entirely by the engine** — there is no
Lua inventory GUI (confirmed: no `data/scripts/gui/`, no `draw_action_icon`,
nothing). Mods can only draw their own GUI via `GuiCreate`/`GuiStartFrame`, and
**the engine never exposes where it drew the spell slots**. GUI coordinates also
*scale with resolution* (`GuiGetScreenDimensions` is resolution-dependent). That
forces a choice in how we present the brackets:

- **A. Overlay on the native slots.** Draw bracket glyphs/lines directly over the
  wand's spell row in the inventory. Matches the original vision exactly, *but*
  requires hardcoding/measuring the slot origin + pitch in GUI space and tracking
  it across resolutions, UI scale, and the quick- vs full-inventory views. Most
  fragile; most likely to break on a game update.
- **B. Companion "structure" panel.** When the inventory is open, draw our own
  panel (coords we fully control) that lists the wand's spells in order with
  indentation + nesting brackets and the type colors from `main`. Always correct,
  resolution-proof, can show deep nesting clearly. Trade-off: it sits beside the
  native slots rather than literally on them.
- **C. Hybrid.** Ship B first (guaranteed working), then attempt A as an optional
  overlay layer once B's tree rendering is solid.

**Recommendation: C** — build B now (it reuses the whole validated foundation and
can't be blocked by the slot-position problem), then treat the native overlay as
an enhancement we can tune against a real screen.

## Implemented (panel — phase 1)

- **`files/grouping_overlay.lua`** — reads the active wand (`Inventory2Component.
  mActiveItem`) and its cards (`ItemActionComponent.action_id`, ordered by
  `ItemComponent.inventory_slot`), builds the tree, flattens it to indented
  color-coded lines, and draws a panel via our own `Gui` while
  `GameIsInventoryOpen()`.
- **`init.lua`** — `OnWorldPostUpdate` calls it, lazily loaded and `pcall`-guarded
  so any failure disables the panel instead of breaking the game.
- **`settings.lua`** — `show_grouping` toggle (RUNTIME scope).
- Colors reuse the per-type palette from `main`.

## Remaining work (HISTORICAL — all items since resolved; STATUS.md is current)

Kept as the design-time record. How each closed out: (1) everything verified
in-game over 2026-06-09..11; (2) always-cast cards got their own "always:"
line (verified), mod spells fall back to leaves, shuffle wands now show
NOTHING at all (no panel, no brackets — user call), multi-cast splits are
the cast-grouping feature itself; (3) the slot overlay shipped as a co-equal
feature — the "selected box is taller" limitation turned out to be FALSE
(tall wand sprite in disguise; selection changes nothing); (4) localized
`$action_*` names landed in the panel.

1. **Verify in-game** (needs a real run) — confirm `mActiveItem` reads, slot
   ordering, and panel placement; tune position/width/legibility.
2. **Edge cases:** always-cast cards (currently sorted by slot like the rest —
   may want a separate section), mod-added spells (unknown → leaf, OK),
   shuffle wands (deck order randomizes at cast — panel shows static slot order;
   note this), `cast count` > 1 (panel shows whole deck, not per-shot split).
3. **Phase 2 — wand-box slot overlay** (the build-aid vision): *calibrated, but
   fundamentally limited.* `draw_box_brackets` enumerates every carried wand and
   draws grouping brackets under each wand box's spell row (`BOX` table = GUI-
   fraction geometry). Calibrated against GUI 640×360 (px = 2.5×GUI): non-selected
   boxes align; the **selected box renders ~12 GUI taller and can't be detected**,
   so the box you're editing reads slightly high. Toggle: `show_slot_brackets`.
   See `STATUS.md` for the decision point (likely make the panel primary). Panel
   remains the reliable fallback.
4. **Polish:** friendlier names via the `$action_*` translations instead of
   prettified ids; optional connector glyphs.
