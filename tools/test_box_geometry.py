#!/usr/bin/env python3
"""Regression guard for the wand-BOX vertical geometry model.

Noita renders the wand inventory in C++ with no Lua API for box positions, so
files/grouping_overlay.lua MODELS each box from the wand sprite THICKNESS (art
height h in px). Both the slot-row offset and the box height are LINEAR in h:
    row_offset = row_a + row_b * h          (box top  -> slot-row top)
    box_h      = row_offset + below_c        (box top  -> box bottom)
2026-06-17 THICKNESS MODEL: box height is driven by sprite thickness, NOT the
diagonal 0.7071*(w+h) (which averaged width+thickness, so long-thin vs short-fat
wands with equal w+h got the same wrong box). Ground-truth (thickness -> box_h):
h7 -> 35.0/36.2u, h9 -> 38.2u, h15 -> 45.6u -> box_h = 26.9 + 1.25*h, fitting all
within ~0.65u including big wands. Validated by the "Shuffle" rows down a stack.
The constants are fit to in-game measurements; a bad edit used to ship silently.
This test parses the LIVE constants out of grouping_overlay.lua and asserts the
model still reproduces every measured anchor. Run it (and test_wand_structure.py)
after any BOX edit. Add a row to the anchor lists each time a new wand is measured.

It also guards the v1.2.4 starter-wand fix: XML wand sprites (handgun, bomb_wand)
must be keyed on backing PNG height in the generated wand_sprite_meta.lua (NOT the
RectAnimation frame_height), and the SPRITE_OVERRIDES must pin those starters to
their measured box. Run gen_wand_sprite_meta.py if the meta check fails.

This re-implements the (tiny) box-geometry formula and checks it against the
same constants the mod ships -- the geometry is engine-coupled (it feeds live
inventory reads), so it's validated by parsing the constants, not by executing
the Lua. (Pure simulator logic IS run directly now -- see
tools/test_wand_structure.lua.)
"""
import os
import re
import sys

LUA = os.path.join(os.path.dirname(__file__), "..", "files", "grouping_overlay.lua")

# (label, sprite thickness h [px], measured box-top -> slot-row-top offset [u], tol).
# Derived as box_h - below_c(15.6). The h7 pair spans 35.0/36.2u box_h (length
# adds ~0.17u/px, not modeled), so the h7 anchor uses the midpoint with a looser tol.
ROW_ANCHORS = [
    # thin wands sit on the floor (measured on wand_0654, h5, 2026-10-07)
    ("h5 wand (wand_0654), floored", 5, 18.70, 0.3),
    ("h7 wand (wand_0492/0511)", 7,  20.00, 0.8),
    ("h9 wand (wand_0531)",      9,  22.60, 0.6),
    ("h15 wand (wand_0860)",     15, 30.00, 0.6),
]
# (label, thickness h, measured box-top -> box-bottom [box height, u], tol). Read
# from box-bottom borders + "Shuffle"-row stacking checks. h7 midpoint (35.0/36.2).
BOX_H_ANCHORS = [
    ("h5 wand (wand_0654), floored", 5, 34.30, 0.3),
    ("h7 wand (wand_0492/0511)", 7,  35.60, 0.8),
    ("h9 wand (wand_0531)",      9,  38.20, 0.6),
    ("h15 wand (wand_0860)",     15, 45.60, 0.6),
]

# v1.2.4 starter-wand fix. Wands whose image_file is a sprite XML must be keyed on
# their backing PNG height (the engine sizes the box by the image), NOT the
# RectAnimation frame_height -- the frame-height bug undersized the box and drifted
# the whole stack down, and shipped silently. Two guards:
#   1. the GENERATED meta table resolves these to png height (regen if this fails),
#   2. the SPRITE_OVERRIDES pin the every-run starters to their measured box.
# (sprite key, expected wand_sprite_meta height [px] = backing png height).
META = os.path.join(os.path.dirname(__file__), "..", "files", "wand_sprite_meta.lua")
META_ANCHORS = [
    ("data/items_gfx/handgun.xml",   8),
    ("data/items_gfx/bomb_wand.xml", 8),
]
# (sprite key, measured box_h [u], measured row_top [u], tol). Middle-click 2026-06-19.
OVERRIDE_ANCHORS = [
    ("data/items_gfx/handgun.xml",   36.9, 21.9, 0.2),
    ("data/items_gfx/bomb_wand.xml", 36.9, 21.9, 0.2),
]


def grab(src, name, kind="field"):
    pat = (r"\blocal\s+%s\s*=\s*(-?[\d.]+)" if kind == "local"
           else r"\b%s\s*=\s*(-?[\d.]+)") % re.escape(name)
    m = re.search(pat, src)
    if not m:
        raise SystemExit("FAIL: could not find constant %r in grouping_overlay.lua" % name)
    return float(m.group(1))


def grab_meta(meta_src, key):
    m = re.search(r'\["%s"\]\s*=\s*(\d+)' % re.escape(key), meta_src)
    return int(m.group(1)) if m else None


def grab_override(src, key):
    """box_h, row_top from a SPRITE_OVERRIDES entry (None,None if absent)."""
    m = re.search(r'\["%s"\]\s*=\s*\{([^}]*)\}' % re.escape(key), src)
    if not m:
        return None, None
    body = m.group(1)
    bh = re.search(r"box_h\s*=\s*(-?[\d.]+)", body)
    rt = re.search(r"row_top\s*=\s*(-?[\d.]+)", body)
    return (float(bh.group(1)) if bh else None,
            float(rt.group(1)) if rt else None)


def main():
    src = open(LUA, encoding="utf-8").read()

    row_a   = grab(src, "row_a")
    row_b   = grab(src, "row_b")
    min_h   = grab(src, "min_h")
    below_c = grab(src, "below_c")

    def row_top(h):
        return row_a + row_b * max(h, min_h)   # the floor: thin sprites do not shrink the box

    def box_h(h):
        return row_top(h) + below_c

    fails = []

    for label, h, meas, tol in ROW_ANCHORS:
        got = row_top(h)
        ok = abs(got - meas) <= tol
        print("%s row_top(h=%d): model %.2fu vs measured %.2fu  err %+.2fu  [%s]"
              % ("PASS" if ok else "FAIL", h, got, meas, got - meas, label))
        if not ok:
            fails.append("%s row_top off %+.2fu (tol %.2f)" % (label, got - meas, tol))

    for label, h, meas, tol in BOX_H_ANCHORS:
        got = box_h(h)
        ok = abs(got - meas) <= tol
        print("%s box_h(h=%d):  model %.2fu vs measured %.2fu  err %+.2fu  [%s]"
              % ("PASS" if ok else "FAIL", h, got, meas, got - meas, label))
        if not ok:
            fails.append("%s box_h off %+.2fu (tol %.2f)" % (label, got - meas, tol))

    # --- v1.2.4: XML wand sprites keyed on png height (generator output) ---
    meta_src = open(META, encoding="utf-8").read()
    for key, exp in META_ANCHORS:
        got = grab_meta(meta_src, key)
        ok = got == exp
        print("%s meta[%s] = %s  (expected %d = backing png height)"
              % ("PASS" if ok else "FAIL", key.rsplit("/", 1)[-1], got, exp))
        if not ok:
            fails.append("%s meta height %s != %d -- regen wand_sprite_meta.lua "
                         "(frame_height regression?)" % (key, got, exp))

    # --- v1.2.4: starter-wand SPRITE_OVERRIDES pin the measured box ---
    for key, mbh, mrt, tol in OVERRIDE_ANCHORS:
        gbh, grt = grab_override(src, key)
        if gbh is None or grt is None:
            print("FAIL override[%s] missing box_h/row_top" % key.rsplit("/", 1)[-1])
            fails.append("%s SPRITE_OVERRIDES entry missing box_h/row_top" % key)
            continue
        ok = abs(gbh - mbh) <= tol and abs(grt - mrt) <= tol
        print("%s override[%s]: box_h %.1fu (meas %.1f), row_top %.1fu (meas %.1f)"
              % ("PASS" if ok else "FAIL", key.rsplit("/", 1)[-1], gbh, mbh, grt, mrt))
        if not ok:
            fails.append("%s override box_h %.1f/row_top %.1f off measured %.1f/%.1f "
                         "(tol %.2f)" % (key, gbh, grt, mbh, mrt, tol))

    # sanity: both linear & strictly increasing, and the box bottom is always
    # below the row top by exactly below_c (the stacking depends on box_h).
    if not (row_top(5) < row_top(10) < row_top(15)):
        fails.append("row_top not strictly increasing -- linear model broken")
    elif abs((box_h(11.0) - row_top(11.0)) - below_c) > 1e-9:
        fails.append("box_h - row_top != below_c -- box-height coupling broken")
    else:
        print("PASS row_top & box_h linear/increasing; box_h - row_top == below_c (%.2fu)" % below_c)

    print()
    if fails:
        print("%d failure(s):" % len(fails))
        for f in fails:
            print("  - " + f)
        sys.exit(1)
    print("0 failure(s)")


if __name__ == "__main__":
    main()
