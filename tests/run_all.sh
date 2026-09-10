#!/usr/bin/env bash
# Run everything that can be checked without launching the game.
#
#   tests/run_all.sh [path-to-a-pristine-npc_cooking_planner.lua]
#
# Needs lua5.1 (same version DST runs) and, for the installer tests, pwsh.

set -uo pipefail

cd "$(dirname "$0")/.."

LUA=${LUA:-lua5.1}
LUAC=${LUAC:-luac5.1}
PWSH=${PWSH:-pwsh}
PLANNER=${1:-}

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
elif [ -z "$PLANNER" ]; then
	printf '   \033[33mSKIP\033[0m pass a pristine npc_cooking_planner.lua as $1\n'
elif "$PWSH" -NoProfile -File tests/test_patcher.ps1 -Planner "$PLANNER" -Luac "$LUAC"; then
	ok "tests/test_patcher.ps1"
else
	bad "tests/test_patcher.ps1"
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
	printf '\033[32mALL GREEN\033[0m\n'
else
	printf '\033[31mSOMETHING FAILED\033[0m\n'
fi
exit "$fail"
