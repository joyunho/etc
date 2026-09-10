-- test_search.lua
--
-- Unit tests for the patch modules under npcfriends_hof_cooking/scripts/.
-- (tests/test_merged.lua covers the same logic through the shipped, merged
-- file and the real Install() seam.)
--
--   lua5.1 tests/test_search.lua

local here = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = here .. "/?.lua;" .. here .. "/../npcfriends_hof_cooking/scripts/?.lua;" .. package.path

math.randomseed(12345)

local Stub = require("dst_stub")
Stub.Register()

local Core    = require("hofnpc_core")
local Search  = require("hofnpc_search")
local Variety = require("hofnpc_variety")

Core.SetHost{ tuning = Stub.NPC_TUNING, recipes = Stub.NPC_COOKING_RECIPES }

local failures = 0
local function check(label, ok, detail)
	if ok then
		print("  PASS  " .. label)
	else
		failures = failures + 1
		print("  FAIL  " .. label .. (detail and ("  -- " .. detail) or ""))
	end
end

local function RunSession(label, cfg, passes, existing)
	Core.Configure(cfg)
	Search.ResetCache()
	Variety.Reset()
	Stub.ResetCalls()

	local first_pass_calls, chosen, distinct, mod_hits, n_distinct = nil, {}, {}, 0, 0

	for i = 1, passes do
		local before = Stub.Calls()
		local card = Search.Choose(Stub.PANTRY, existing or {}, true, Stub.COOKER)
		if first_pass_calls == nil then first_pass_calls = Stub.Calls() - before end

		if card ~= nil then
			chosen[#chosen + 1] = card.name
			if distinct[card.name] == nil then n_distinct = n_distinct + 1 end
			distinct[card.name] = (distinct[card.name] or 0) + 1
			if Stub.IsModDish(card.name) then mod_hits = mod_hits + 1 end

			local slots = 0
			for _, sel in ipairs(card._selected_ingredients) do
				slots = slots + sel.take_count
				if Stub.PANTRY[sel.prefab] == nil or sel.container == nil or sel.slot == nil then
					check("selection points at a real pantry slot", false, tostring(sel.prefab))
				end
			end
			if slots ~= 4 then
				check("selection fills exactly 4 pot slots", false, card.name .. " -> " .. slots)
			end
		end
	end

	print(string.format("\n%s", label))
	print(string.format("  passes=%d  chosen=%d  distinct=%d  modded=%d",
		passes, #chosen, n_distinct, mod_hits))
	print(string.format("  CalculateRecipe: first pass=%d, total=%d",
		first_pass_calls or 0, Stub.Calls()))

	local names = {}
	for name, count in pairs(distinct) do names[#names + 1] = name .. " x" .. count end
	table.sort(names)
	print("  menu: " .. table.concat(names, ", "))

	return { chosen = chosen, distinct = distinct, n_distinct = n_distinct,
	         mod_hits = mod_hits, calls = Stub.Calls(), first = first_pass_calls }
end

print("\n=========== 1. medium variety, medium budget ===========")
local r1 = RunSession("medium/medium", { variety = "medium", budget = "medium", debug = false }, 25)
check("finds a dish every pass", #r1.chosen == 25, tostring(#r1.chosen))
check("cooks modded dishes", r1.mod_hits > 0, tostring(r1.mod_hits))
check("rotates through several dishes", r1.n_distinct >= 5, tostring(r1.n_distinct))
check("skips the excluded monsterlasagna", r1.distinct["monsterlasagna"] == nil)
check("skips the blacklisted ratatouille", r1.distinct["ratatouille"] == nil)
check("never cooks wetgoop", r1.distinct["wetgoop"] == nil)
check("warm passes are cheaper than the cold one",
	r1.first > (r1.calls - r1.first) / 24,
	string.format("first=%d avg_rest=%.0f", r1.first, (r1.calls - r1.first) / 24))

print("\n=========== 2. variety off repeats itself ===========")
local r2 = RunSession("off/medium", { variety = "off", budget = "medium" }, 25)
check("variety=off is more repetitive than medium", r2.n_distinct < r1.n_distinct,
	string.format("off=%d medium=%d", r2.n_distinct, r1.n_distinct))

print("\n=========== 3. variety high widens the menu ===========")
local r3 = RunSession("high/high", { variety = "high", budget = "high" }, 25)
check("variety=high is at least as wide as medium", r3.n_distinct >= r1.n_distinct,
	string.format("high=%d medium=%d", r3.n_distinct, r1.n_distinct))

print("\n=========== 4. same_dish_max ===========")
local stocked = {}
for _, d in ipairs(Stub.MOD_DISHES) do stocked[d[1]] = 99 end
stocked["meatballs"] = 99
stocked["honeyham"]  = 99
local r4 = RunSession("stocked pantry", { variety = "medium", budget = "medium", same_dish_max = 3 }, 10, stocked)
local violated = false
for name in pairs(r4.distinct) do if stocked[name] then violated = true end end
check("never cooks a dish stocked past the cap", not violated)

print("\n=========== 5. harmful dishes need opting in ===========")

-- An explicit blacklist entry always wins, whatever allow_negative says.
local only_monster = Stub.MakePool{ { "monstermeat", 8 }, { "twigs", 4 } }
Core.Configure{ variety = "off", budget = "medium", allow_negative = true }
Search.ResetCache(); Variety.Reset()
local blacklisted = Search.Choose(only_monster, {}, true, Stub.COOKER)
check("an excluded dish stays excluded even with allow_negative",
	blacklisted == nil or blacklisted.name ~= "monsterlasagna",
	blacklisted and blacklisted.name or "nil")

-- kyno_bitterbrew costs health and sanity but is on nobody's blacklist.
local only_sap = Stub.MakePool{ { "kyno_sap", 8 } }

Core.Configure{ variety = "off", budget = "medium", allow_negative = false }
Search.ResetCache(); Variety.Reset()
local safe = Search.Choose(only_sap, {}, true, Stub.COOKER)
check("skips the negative-value dish by default",
	safe == nil or safe.name ~= "kyno_bitterbrew", safe and safe.name or "nil")

Core.Configure{ allow_negative = true }
Search.ResetCache(); Variety.Reset()
local risky = Search.Choose(only_sap, {}, true, Stub.COOKER)
check("cooks it once the player opts in",
	risky ~= nil and risky.name == "kyno_bitterbrew", risky and risky.name or "nil")
Core.Configure{ allow_negative = false }

print("\n=========== 6. protected ingredients are never spent ===========")
Core.Configure{ variety = "off", budget = "high", protect = { kyno_shark_fin = true } }
Search.ResetCache(); Variety.Reset()
local used_protected = false
for i = 1, 10 do
	local card = Search.Choose(Stub.PANTRY, {}, true, Stub.COOKER)
	for _, sel in ipairs(card and card._selected_ingredients or {}) do
		if sel.prefab == "kyno_shark_fin" then used_protected = true end
	end
end
check("a protected ingredient is never picked", not used_protected)
Core.Configure{ protect = {} }

print("\n=========== 7. degenerate inputs ===========")
Search.ResetCache(); Variety.Reset()
check("empty pantry returns nil", Search.Choose({}, {}, true, Stub.COOKER) == nil)
check("unknown cooker returns nil", Search.Choose(Stub.PANTRY, {}, true, "no_such_pot") == nil)
check("nil pantry returns nil", Search.Choose(nil, {}, true, Stub.COOKER) == nil)
check("nil cooker returns nil", Search.Choose(Stub.PANTRY, {}, true, nil) == nil)

print("")
if failures == 0 then
	print("ALL CHECKS PASSED")
	os.exit(0)
else
	print(failures .. " CHECK(S) FAILED")
	os.exit(1)
end
