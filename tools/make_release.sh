#!/usr/bin/env bash
# Build the manual-install release zip (for non-Steam / non-Workshop users).
#
# Ships ONLY what Noita needs at runtime plus LICENSE and INSTALL.txt -- no
# tools, docs, git or Workshop metadata. The zip root is the folder
# "spell_bracket_visualizer", which is the name the mod's own dofile paths
# require, so users can extract it straight into Noita\mods\.
#
#   ./tools/make_release.sh            -> dist/spell_bracket_visualizer-v1.3.0.zip
#
# The version is read from files/grouping_overlay.lua so it can never drift.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

version="$(sed -n 's/^local VERSION = "\(v[^"]*\)".*/\1/p' files/grouping_overlay.lua)"
[ -n "$version" ] || { echo "error: could not read VERSION from files/grouping_overlay.lua" >&2; exit 1; }

# Everything the game loads, plus the license and the install guide.
# init.lua and grouping_overlay.lua reference these by exact path.
payload=(
	init.lua
	settings.lua
	mod.xml
	compatibility.xml
	mod_id.txt
	files/grouping_overlay.lua
	files/wand_structure.lua
	files/wand_sim_cache.lua
	files/slot_marks.lua
	files/engine/lua_compat.lua
	files/engine/engine_stubs.lua
	files/engine/live_world.lua
	files/engine/game_env.lua
	files/engine/cast_tracer.lua
	files/engine/wand_runner.lua
	files/engine/engine.lua
	files/wand_sprite_meta.lua
	files/ui/pixel.png
	LICENSE
	INSTALL.txt
)

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
dest="$stage/spell_bracket_visualizer"

for f in "${payload[@]}"; do
	[ -f "$f" ] || { echo "error: missing $f" >&2; exit 1; }
	mkdir -p "$dest/$(dirname "$f")"
	cp "$f" "$dest/$f"
done

# CRLF for the file Windows users open in Notepad.
sed -i 's/$/\r/' "$dest/INSTALL.txt"

mkdir -p dist
zip_name="dist/spell_bracket_visualizer-$version.zip"
rm -f "$zip_name"

# Python's zipfile rather than the zip(1) binary -- not installed everywhere,
# and this keeps the entry order (and so the archive) reproducible.
STAGE="$stage" ZIP_NAME="$PWD/$zip_name" python3 - <<'PY'
import os, zipfile
stage, out = os.environ["STAGE"], os.environ["ZIP_NAME"]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
	for dirpath, dirnames, filenames in os.walk(stage):
		dirnames.sort()
		for name in sorted(filenames):
			full = os.path.join(dirpath, name)
			z.write(full, os.path.relpath(full, stage))
	for info in z.infolist():
		print(f"  {info.file_size:>7}  {info.filename}")
PY

echo "built $zip_name"
