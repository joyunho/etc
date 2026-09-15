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
	print(string.format("  cooking.CalculateRecipe calls: %d (must stay 0)", Stub.Calls()))

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
-- cooking.CalculateRecipe ends in math.random(): using it as a search oracle
-- would be both unrepeatable and a source of world RNG churn.
check("never calls the randomised cooking.CalculateRecipe", r1.calls == 0, tostring(r1.calls))

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

print("\n=========== 5b. one of each before a second of anything ===========")

-- A cheap dish must still get made. Coffee is the case this exists for: every
-- dish DST Coffee and More adds costs 5 sanity on purpose, which rates it at 3
-- against a top dish's 330, so no bonus that leaves the ordering intact would
-- ever let one be brewed.
Core.Configure{ variety = "medium", budget = "high", allow_negative = false,
	taste_everything = true, same_dish_max = 3 }
Search.ResetCache(); Variety.Reset(); Core.ClearScoreCache()

local larder, order = {}, {}
for _ = 1, 40 do
	local card = Search.Choose(Stub.PANTRY, larder, true, Stub.COOKER)
	if card ~= nil then
		order[#order + 1] = card.name
		larder[card.name] = (larder[card.name] or 0) + 1
	end
end

local repeated_before_new = false
local made = {}
for i, name in ipairs(order) do
	if made[name] and i <= #order then
		-- Something was cooked twice. That is only allowed once the menu has
		-- nothing left that has never been cooked, which the run below checks
		-- directly; here we only want to see that it does not happen early.
		if i <= 10 then repeated_before_new = true end
	end
	made[name] = true
end

local distinct_first_ten = {}
for i = 1, math.min(10, #order) do distinct_first_ten[order[i]] = true end
local n = 0
for _ in pairs(distinct_first_ten) do n = n + 1 end

check("the first ten cooks are ten different dishes", n == 10 and not repeated_before_new,
	n .. " distinct: " .. table.concat(order, ", ", 1, math.min(10, #order)))

-- The contract, stated directly: nothing is cooked twice while something on the
-- menu has never been cooked at all.
Core.Configure{ variety = "medium", budget = "high", taste_everything = true, same_dish_max = 3 }
Search.ResetCache(); Variety.Reset(); Core.ClearScoreCache()

local seen, larder2, breaches = {}, {}, 0
for _ = 1, 40 do
	-- What the chef could have made this pass, before it chose.
	local card = Search.Choose(Stub.PANTRY, larder2, true, Stub.COOKER)
	if card ~= nil then
		if seen[card.name] then
			-- A repeat. Fine only if every other reachable dish is also spoken
			-- for; the cache holds exactly what it knew about at that moment.
			for _, entry in pairs(Search._cache) do
				for product in pairs(entry.map) do
					if not seen[product]
						and (larder2[product] or 0) == 0
						and Core.IsDishAllowed(Stub.COOKER, product) then
						breaches = breaches + 1
					end
				end
			end
		end
		seen[card.name] = true
		larder2[card.name] = (larder2[card.name] or 0) + 1
	end
end
check("nothing is cooked twice while something has never been cooked",
	breaches == 0, breaches .. " breach(es)")

-- variety = "off" means "always the best dish", so it must opt out.
Core.Configure{ variety = "off", budget = "high", taste_everything = true, same_dish_max = 3 }
Search.ResetCache(); Variety.Reset(); Core.ClearScoreCache()
local off_larder, off_distinct = {}, 0
for _ = 1, 20 do
	local card = Search.Choose(Stub.PANTRY, off_larder, true, Stub.COOKER)
	if card ~= nil then off_larder[card.name] = (off_larder[card.name] or 0) + 1 end
end
for _ in pairs(off_larder) do off_distinct = off_distinct + 1 end
check("variety=off still means the best dish, not a tour of the cookbook",
	off_distinct < n, off_distinct .. " vs " .. n)

Core.Configure{ taste_everything = true, same_dish_max = nil }

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

print("\n=========== 7. a stable pantry must not go dead ===========")
-- The failure this guards against: discovery used to stop for good once the
-- candidate cache hit its cap, so as dishes reached the same-dish limit the
-- chef ran out of things it knew about and silently handed back to NPC
-- Friends' vanilla-only chooser -- while hundreds of dishes were still
-- cookable from the very same pantry.
Core.Configure{ variety = "medium", budget = "medium", same_dish_max = 3, protect = {} }
Search.ResetCache(); Variety.Reset()

local stock, cooked, seen, unique, nils, first_nil = {}, 0, {}, 0, 0, nil

for pass = 1, 200 do
	local card = Search.Choose(Stub.PANTRY, stock, true, Stub.COOKER)
	if card == nil then
		nils = nils + 1
		if first_nil == nil then first_nil = pass end
	else
		cooked = cooked + 1
		stock[card.name] = (stock[card.name] or 0) + 1
		if seen[card.name] == nil then seen[card.name] = true; unique = unique + 1 end
	end
end

-- How many dishes this pantry can make at all: start fresh every time and
-- block everything already found, so each pass is forced to name something new
-- until there is nothing left. That is the number the stable-pantry run above
-- has to come close to.
local reachable, n_reachable = {}, 0
for pass = 1, 120 do
	Search.ResetCache(); Variety.Reset()

	local blocked = {}
	for name in pairs(reachable) do blocked[name] = 99 end

	local card = Search.Choose(Stub.PANTRY, blocked, true, Stub.COOKER)
	if card == nil then break end

	if reachable[card.name] == nil then
		reachable[card.name] = true
		n_reachable = n_reachable + 1
	end
end

print(string.format("  over 200 passes: cooked=%d  distinct=%d  gave up=%d  first give-up at pass %s",
	cooked, unique, nils, tostring(first_nil)))
print(string.format("  reachable from this pantry at all: %d", n_reachable))

-- Every dish it can find, cooked up to the cap, is unique * same_dish_max.
check("keeps cooking until the pantry is genuinely used up",
	cooked >= unique * 3 - 2, string.format("cooked=%d unique=%d", cooked, unique))
check("finds a wide menu from a stable pantry", unique >= 12, tostring(unique))
-- The regression: discovery froze at the candidate cap, so a long run found far
-- fewer dishes than a series of fresh starts would.
check("a long run finds as much as fresh starts do",
	unique >= math.floor(n_reachable * 0.8),
	string.format("long run=%d  reachable=%d", unique, n_reachable))
check("still never touches the randomised resolver", Stub.Calls() == 0, tostring(Stub.Calls()))

Core.Configure{ same_dish_max = 0 }

print("\n=========== 8. the panel's food quota is honoured ===========")
-- NPC Friends stops cooking altogether once COOK_MAX_TOTAL dishes are stored
-- ("음식 최대 개수" in the panel). We replace the function that enforced it, so
-- ignoring it here would silently kill a button the player can see.
Core.Configure{ variety = "medium", budget = "medium", same_dish_max = 0 }
Search.ResetCache(); Variety.Reset()

Stub.NPC_TUNING.COOK_MAX_TOTAL = 5
check("cooks while the larder is under the quota",
	Search.Choose(Stub.PANTRY, { meatballs = 2 }, true, Stub.COOKER) ~= nil)

Search.ResetCache(); Variety.Reset()
check("stops once the quota is reached",
	Search.Choose(Stub.PANTRY, { meatballs = 3, honeyham = 2 }, true, Stub.COOKER) == nil)

Stub.NPC_TUNING.COOK_MAX_TOTAL = 0
Search.ResetCache(); Variety.Reset()
check("0 means no limit",
	Search.Choose(Stub.PANTRY, { meatballs = 99 }, true, Stub.COOKER) ~= nil)

print("\n=========== 9. degenerate inputs ===========")
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
