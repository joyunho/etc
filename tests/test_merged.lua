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

-- The diagnostic reads GetTime() for its rate limit.
local fake_now = 0
function GetTime() return fake_now end

local plan_calls = 0

local function NewPlanner()
	return {
		FindBestRecipe = function(pool, existing, is_warly, cooker_name)
			original_calls = original_calls + 1
			return ORIGINAL_SENTINEL
		end,
		-- Stands in for NPC Friends' PlanCooking, which gives up silently.
		PlanCooking = function(inst, containers, cookpots, is_warly)
			plan_calls = plan_calls + 1
			return nil
		end,
		-- Stands in for the scanner that walks 1..GetNumSlots(): a closed
		-- modded chest reports zero slots, so this comes back empty.
		ScanIngredients = function(containers)
			local pool = {}
			for _, c in ipairs(containers or {}) do
				local cont = c.components and c.components.container
				for i = 1, (cont and cont:GetNumSlots() or 0) do
					local item = cont.slots[i]
					if item then
						pool[item.prefab] = pool[item.prefab] or { total = 0, locations = {} }
						pool[item.prefab].total = pool[item.prefab].total + 1
						table.insert(pool[item.prefab].locations, { container = c, slot = i, count = 1 })
					end
				end
			end
			return pool
		end,
		CountExistingDishes = function(containers) return {} end,
	}
end

-- A chest that is genuinely full but answers "0 slots" until someone opens it.
local function NewClosedChest(prefabs, reported_slots)
	local slots = {}
	for i, prefab in ipairs(prefabs) do
		slots[i] = { prefab = prefab, IsValid = function() return true end,
		             HasTag = function() return false end }
	end
	return {
		prefab  = "treasurechest",
		IsValid = function() return true end,
		components = {
			container = {
				slots         = slots,
				GetNumSlots   = function() return reported_slots end,
				GetItemInSlot = function(self, i) return i <= reported_slots and slots[i] or nil end,
			},
		},
	}
end

local function NewChef()
	local said = {}
	return {
		GUID = 1234,
		components = {
			talker    = { Say = function(self, text) said[#said + 1] = text end },
			inventory = { maxslots = 12, GetItemInSlot = function() return nil end },
		},
		said = said,
	}
end

local function NewContainer(items)
	local slots = {}
	for i, prefab in ipairs(items) do slots[i] = { prefab = prefab, IsValid = function() return true end } end
	return {
		prefab  = "treasurechest",
		IsValid = function() return true end,
		components = {
			container = {
				GetNumSlots   = function() return 9 end,
				GetItemInSlot = function(self, i) return slots[i] end,
			},
		},
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

Stub.ResetCalls()

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

-- The real cooking.CalculateRecipe breaks ties with math.random(), so using it
-- to explore combinations would be unrepeatable and would churn world RNG.
check("never calls the randomised cooking.CalculateRecipe", Stub.Calls() == 0, tostring(Stub.Calls()))

-- The card_def dishes are the ones Heap of Foods states outright; they must be
-- found by the exact path, not left to the bounded search to stumble on.
local carded = 0
for _, d in ipairs(Stub.MOD_DISHES) do
	if d[7] ~= nil and distinct[d[1]] then carded = carded + 1 end
end
check("dishes that state their own ingredients get cooked", carded >= 3, tostring(carded))

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

print("\n=========== 6. a closed chest is not an empty chest ===========")
-- Container:GetNumSlots() comes from the widget parameters, and several
-- container mods only fill those in when the chest is opened. Until then the
-- usual `for slot = 1, GetNumSlots()` loop runs zero times and a full chest
-- reads as empty -- which is why the chef would only cook once a player opened
-- the fridge.
-- cheese + cheese + honey + berries makes kyno_cheesecake, which nothing
-- filters out, so a failure here is the scan and not the menu.
local CONTENTS     = { "kyno_cheese", "kyno_cheese", "honey", "berries" }
local full_chest   = NewClosedChest(CONTENTS, 9)
local closed_chest = NewClosedChest(CONTENTS, 0)

local pool_open = Planner.ScanIngredients({ full_chest })
local kinds_open = 0
for _ in pairs(pool_open) do kinds_open = kinds_open + 1 end
check("an open chest scans normally", kinds_open == 3, tostring(kinds_open))

local pool_closed = Planner.ScanIngredients({ closed_chest })
local kinds_closed = 0
for _ in pairs(pool_closed) do kinds_closed = kinds_closed + 1 end
check("a closed chest is recovered instead of read as empty", kinds_closed == 3, tostring(kinds_closed))

-- And the recovered pool has to be usable, not just non-empty.
local usable = true
for prefab, data in pairs(pool_closed) do
	if data.total < 1 or #data.locations < 1 or data.locations[1].container == nil
		or data.locations[1].slot == nil then
		usable = false
	end
end
check("the recovered pool has real container slots", usable)

local from_closed = Planner.FindBestRecipe(pool_closed, {}, true, Stub.COOKER)
check("a dish can be planned from a closed chest",
	from_closed ~= nil and from_closed ~= ORIGINAL_SENTINEL,
	from_closed == ORIGINAL_SENTINEL and "fell back" or tostring(from_closed and from_closed.name))

print("\n=========== 6b. the station chooser goes through the shipped file ===========")

-- The seasoning station fix has to reach the game through Install(), not just
-- through the module, so drive it the way npc_cooking_planner.lua does.
do
	local guid = 0
	local function Station(prefab, slots)
		guid = guid + 1
		return {
			prefab = prefab, GUID = guid,
			IsValid = function() return true end,
			components = {
				stewer = { IsCooking = function() return false end, IsDone = function() return false end },
				container = { numslots = slots, GetNumSlots = function(self) return self.numslots end },
			},
		}
	end

	local P = NewPlanner()
	-- NPC Friends' own chooser: first station with an idle stewer, whatever it is.
	P.FindAvailableCookpot = function(cookpots)
		for _, pot in ipairs(cookpots) do
			if pot.components.stewer and not pot.components.stewer:IsCooking()
				and not pot.components.stewer:IsDone() then
				return pot
			end
		end
		return nil
	end

	local before = P.FindAvailableCookpot({ Station("portablespicer", 2), Station("cookpot", 4) })
	check("without the patch the chef would walk to the seasoning station",
		before.prefab == "portablespicer", before.prefab)

	Patch.applied = false
	Patch.Install(P)

	local after = P.FindAvailableCookpot({ Station("portablespicer", 2), Station("cookpot", 4) })
	check("after Install() it walks to the pot instead",
		after ~= nil and after.prefab == "cookpot", after and after.prefab or "nil")

	local none = P.FindAvailableCookpot({ Station("portablespicer", 2) })
	check("and a seasoning station on its own is refused rather than stalled on",
		none == nil, none and none.prefab or "nil")
end

print("\n=========== 7. it explains why the chef gave up ===========")

local chef = NewChef()

-- Chests full of things the game does not consider cooking ingredients.
fake_now = 1000
Planner.PlanCooking(chef, { NewContainer({ "log", "rocks", "flint" }) }, {}, true)
check("PlanCooking is wrapped and still returns nil", plan_calls == 1)
check("the chef says something about the missing pot or ingredients", #chef.said == 1,
	table.concat(chef.said, " | "))

-- Same failure a second later: it must not spam.
Planner.PlanCooking(chef, { NewContainer({ "log" }) }, {}, true)
check("it does not repeat itself straight away", #chef.said == 1, tostring(#chef.said))

-- A minute later it may speak again.
fake_now = 1100
Planner.PlanCooking(chef, { NewContainer({ "log" }) }, {}, true)
check("it speaks again after the interval", #chef.said == 2, tostring(#chef.said))

-- With a working pot but no usable ingredients, it must name that case.
local pot = {
	IsValid = function() return true end,
	components = { stewer = { IsCooking = function() return false end, IsDone = function() return false end } },
}
chef = NewChef()
fake_now = 2000
Planner.PlanCooking(chef, { NewContainer({ "log", "rocks" }) }, { pot }, true)
check("it reports 'no usable ingredients' when the pot is fine",
	#chef.said == 1 and chef.said[1]:find("재료") ~= nil, table.concat(chef.said, " | "))
print("  chef said: " .. table.concat(chef.said, " | "))

-- A malformed container must not crash the NPC.
local ok_diag = pcall(Planner.PlanCooking, chef, { { prefab = "broken" } }, { pot }, true)
check("a malformed container does not raise", ok_diag)

print("")
if failures == 0 then
	print("ALL CHECKS PASSED")
	os.exit(0)
else
	print(failures .. " CHECK(S) FAILED")
	os.exit(1)
end
