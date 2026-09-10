-- test_merged.lua
--
-- Integration test for the file the installer actually ships:
-- build/NPC_HOF_Patch/files/npc_hof_cooking.lua
--
-- It goes through the real seam -- Install(CookingPlanner) replacing
-- FindBestRecipe on a stand-in planner table -- rather than poking at the
-- internals, so this is as close to "does it work in game" as we can get
-- outside the game.
--
--   lua5.1 tests/test_merged.lua

local here = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = here .. "/?.lua;" .. here .. "/../build/NPC_HOF_Patch/files/?.lua;" .. package.path

math.randomseed(20260910)

local Stub = require("dst_stub")
Stub.Register()

local failures = 0
local function check(label, ok, detail)
	if ok then
		print("  PASS  " .. label)
	else
		failures = failures + 1
		print("  FAIL  " .. label .. (detail and ("  -- " .. detail) or ""))
	end
end

-- ═══════════════════════════════════════════════════════════════════════════
--  A stand-in for NPC Friends' CookingPlanner
-- ═══════════════════════════════════════════════════════════════════════════

local ORIGINAL_SENTINEL = { name = "__original_was_called__" }
local original_calls = 0

local function NewPlanner()
	return {
		FindBestRecipe = function(pool, existing, is_warly, cooker_name)
			original_calls = original_calls + 1
			return ORIGINAL_SENTINEL
		end,
	}
end

print("\n=========== 1. Install() wires itself in ===========")

local Patch = require("npc_hof_cooking")
check("the built file returns a table with Install", type(Patch) == "table" and type(Patch.Install) == "function")

local Planner = NewPlanner()
local before  = Planner.FindBestRecipe

check("Install reports success", Patch.Install(Planner) == true)
check("FindBestRecipe was replaced", Planner.FindBestRecipe ~= before)
check("installing twice is a no-op", Patch.Install(Planner) == true)

print("\n=========== 2. it cooks modded dishes, with variety ===========")

local menu, distinct, mod_hits, n_distinct = {}, {}, 0, 0

for i = 1, 25 do
	local card = Planner.FindBestRecipe(Stub.PANTRY, {}, true, Stub.COOKER)

	check_card = nil
	if card == ORIGINAL_SENTINEL then
		check("did not fall back to the original on a full pantry", false, "pass " .. i)
	elseif card == nil then
		check("returned a dish on a full pantry", false, "pass " .. i)
	else
		menu[#menu + 1] = card.name
		if distinct[card.name] == nil then n_distinct = n_distinct + 1 end
		distinct[card.name] = (distinct[card.name] or 0) + 1
		if Stub.IsModDish(card.name) then mod_hits = mod_hits + 1 end

		local slots = 0
		for _, sel in ipairs(card._selected_ingredients or {}) do
			slots = slots + sel.take_count
			if Stub.PANTRY[sel.prefab] == nil or sel.container == nil or sel.slot == nil then
				check("every chosen ingredient points at a real pantry slot", false, tostring(sel.prefab))
			end
		end
		if slots ~= 4 then
			check("the plan fills exactly 4 pot slots", false, card.name .. " -> " .. slots)
		end
		if type(card.cooktime) ~= "number" then
			check("the plan carries a numeric cooktime", false, card.name)
		end
	end
end

local names = {}
for name, count in pairs(distinct) do names[#names + 1] = name .. " x" .. count end
table.sort(names)
print("  menu: " .. table.concat(names, ", "))

check("cooked 25 dishes", #menu == 25, tostring(#menu))
check("most picks are modded dishes", mod_hits >= 15, tostring(mod_hits) .. "/25")
check("rotated through many dishes", n_distinct >= 6, tostring(n_distinct))
check("never cooked the excluded monsterlasagna", distinct["monsterlasagna"] == nil)
check("never cooked the blacklisted ratatouille", distinct["ratatouille"] == nil)
check("never cooked wetgoop", distinct["wetgoop"] == nil)
check("no meatball-first bias", (distinct["meatballs"] or 0) <= 3, tostring(distinct["meatballs"]))

print("\n=========== 3. falls back to the original when it cannot help ===========")

original_calls = 0
local empty = Planner.FindBestRecipe({}, {}, true, Stub.COOKER)
check("empty pantry defers to NPC Friends", empty == ORIGINAL_SENTINEL and original_calls == 1)

original_calls = 0
local unknown = Planner.FindBestRecipe(Stub.PANTRY, {}, true, "some_unknown_pot")
check("unknown cooker defers to NPC Friends", unknown == ORIGINAL_SENTINEL and original_calls == 1)

print("\n=========== 4. a broken pantry never crashes the NPC ===========")

original_calls = 0
local poisoned = { kyno_flour = { total = 2 } }  -- no `locations` at all
local ok, result = pcall(Planner.FindBestRecipe, poisoned, {}, true, Stub.COOKER)
check("malformed pantry does not raise", ok, tostring(result))
check("malformed pantry falls back instead", result == ORIGINAL_SENTINEL or result == nil,
	tostring(result and result.name))

print("\n=========== 5. same_dish_max is honoured ===========")

local stocked = {}
for _, d in ipairs(Stub.MOD_DISHES) do stocked[d[1]] = 99 end
local violated = false
for i = 1, 10 do
	local card = Planner.FindBestRecipe(Stub.PANTRY, stocked, true, Stub.COOKER)
	if card ~= nil and card ~= ORIGINAL_SENTINEL and stocked[card.name] then violated = true end
end
check("never cooks a dish already stocked past the cap", not violated)

print("")
if failures == 0 then
	print("ALL CHECKS PASSED")
	os.exit(0)
else
	print(failures .. " CHECK(S) FAILED")
	os.exit(1)
end
