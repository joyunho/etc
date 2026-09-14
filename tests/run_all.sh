#!/usr/bin/env bash
# Run everything that can be checked without launching the game.
#
#   tests/run_all.sh [path-to-a-pristine-NPC-Friends-3684000581-folder]
#
# Needs lua5.1 (same version DST runs) and, for the installer tests, pwsh.

set -uo pipefail

cd "$(dirname "$0")/.."

LUA=${LUA:-lua5.1}
LUAC=${LUAC:-luac5.1}
PWSH=${PWSH:-pwsh}
MODROOT=${1:-}

fail=0
step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
ok()   { printf '   \033[32mOK\033[0m   %s\n' "$1"; }
bad()  { printf '   \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }

step "Lua syntax"
for f in npcfriends_hof_cooking/modinfo.lua npcfriends_hof_cooking/modmain.lua \
         npcfriends_hof_cooking/scripts/*.lua patch/header.lua patch/install_stub.lua; do
	if out=$("$LUAC" -p "$f" 2>&1); then ok "$f"; else bad "$f: $out"; fi
done

step "Build the patch package"
if python3 patch/build.py; then ok "patch/build.py"; else bad "patch/build.py"; fi

step "Lua syntax of the built file"
if out=$("$LUAC" -p build/NPC_HOF_Patch/files/npc_hof_cooking.lua 2>&1); then
	ok "build/NPC_HOF_Patch/files/npc_hof_cooking.lua"
else
	bad "built file: $out"
fi

step "Unit tests"
if "$LUA" tests/test_search.lua; then ok "tests/test_search.lua"; else bad "tests/test_search.lua"; fi

step "Integration tests (through the shipped file)"
if "$LUA" tests/test_merged.lua; then ok "tests/test_merged.lua"; else bad "tests/test_merged.lua"; fi

step "Performance"
"$LUA" tests/perf.lua || bad "tests/perf.lua"

step "Installer tests"
if ! command -v "$PWSH" >/dev/null 2>&1; then
	printf '   \033[33mSKIP\033[0m pwsh not installed\n'
elif [ -z "$MODROOT" ]; then
	printf '   \033[33mSKIP\033[0m pass a pristine NPC Friends folder as $1\n'
elif "$PWSH" -NoProfile -File tests/test_patcher.ps1 -ModRoot "$MODROOT" -Luac "$LUAC"; then
	ok "tests/test_patcher.ps1"
else
	bad "tests/test_patcher.ps1"
fi

step "Launchers"
# Double-clicking a .bat cannot pass it a word, so every action that needs
# "stop" ships a second file with it already filled in.
for pair in "hangul_UNDO.bat hangul" "korean_UNDO.bat korean" "bisect_UNDO.bat bisect"; do
	set -- $pair
	f="build/NPC_HOF_Patch/$1"
	if [ ! -f "$f" ]; then
		bad "$1 is missing"
	elif ! grep -q -- "-Action $2 -Arg \"stop\"" "$f"; then
		bad "$1 does not pass stop"
	else
		ok "$1"
	fi
done
for f in build/NPC_HOF_Patch/*.bat; do
	if LC_ALL=C grep -qP '[^\x00-\x7F]' "$f"; then bad "$(basename "$f") is not ASCII"; fi
done

step "Korean string patch"
python3 korean_patch/build_korean.py >/dev/null || bad "korean_patch/build_korean.py"
for f in korean_patch/modinfo.lua korean_patch/modmain.lua; do
	if "$LUAC" -p "$f" 2>/dev/null; then ok "$f"; else bad "$f"; fi
done
if "$LUA" tests/test_korean.lua >/dev/null; then ok "tests/test_korean.lua"; else bad "tests/test_korean.lua"; fi

step "Bisect tests (simulated server)"
if ! command -v "$PWSH" >/dev/null 2>&1; then
	printf '   \033[33mSKIP\033[0m pwsh not installed\n'
elif "$PWSH" -NoProfile -File tests/test_bisect.ps1; then
	ok "tests/test_bisect.ps1"
else
	bad "tests/test_bisect.ps1"
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
	printf '\033[32mALL GREEN\033[0m\n'
else
	printf '\033[31mSOMETHING FAILED\033[0m\n'
fi
exit "$fail"
