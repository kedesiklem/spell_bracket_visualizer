#!/usr/bin/env python3
"""Extract the game's own cast code from data.wak, for the offline tests.

The mod runs Noita's real gun.lua (files/engine/). In the game it reads those
files through ModTextFileGetContent; the offline tests have no game, so they
read them from .gun_ref/ instead, which this script fills.

They are Noita's copyrighted content, so they are NEVER committed: this writes
them to .gun_ref/ (gitignored) from the player's own install. That is also why
the tests cannot run in CI -- they need a Noita installation.

    python3 tools/extract_gun.py [path/to/data.wak]

Pure stdlib. Paths derive from this file's location, same as the other tools/.
"""
import struct, os, sys

MOD = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WAK = (sys.argv[1] if len(sys.argv) > 1 else
       os.environ.get("NOITA_WAK",
       os.path.normpath(os.path.join(MOD, "..", "..", "data", "data.wak"))))
OUT = os.path.join(MOD, ".gun_ref")

# Everything gun.lua and gun_actions.lua reach for, directly or via dofile_once.
# gun.lua      -> gun_enums, gunaction_generated, gun_generated, gunshoteffects_generated
# gun_actions  -> procedural/gun_action_utils, lib/utilities
WANTED = {
    "data/scripts/gun/gun.lua",
    "data/scripts/gun/gun_actions.lua",
    "data/scripts/gun/gun_enums.lua",
    "data/scripts/gun/gun_generated.lua",
    "data/scripts/gun/gunaction_generated.lua",
    "data/scripts/gun/gunshoteffects_generated.lua",
    "data/scripts/gun/gun_extra_modifiers.lua",
    "data/scripts/gun/procedural/gun_action_utils.lua",
    "data/scripts/lib/utilities.lua",
}


def entries(buf):
    count = struct.unpack_from("<I", buf, 4)[0]
    pos = 16
    for _ in range(count):
        off, size, plen = struct.unpack_from("<III", buf, pos); pos += 12
        name = buf[pos:pos + plen].decode("utf-8", "replace"); pos += plen
        yield name, off, size


def main():
    if not os.path.exists(WAK):
        raise SystemExit(
            "data.wak not found at %s\n"
            "Pass the path as an argument or set NOITA_WAK." % WAK)
    buf = open(WAK, "rb").read()
    found = {}
    for name, off, size in entries(buf):
        if name in WANTED:
            found[name] = buf[off:off + size]

    missing = WANTED - set(found)
    if missing:
        raise SystemExit("not found in wak (game update?):\n  " +
                         "\n  ".join(sorted(missing)))

    for name, blob in sorted(found.items()):
        dest = os.path.join(OUT, name)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as fh:
            fh.write(blob)
        print("%8d  %s" % (len(blob), name))
    print("\n%d files -> %s/" % (len(found), os.path.relpath(OUT, MOD)))


if __name__ == "__main__":
    main()
