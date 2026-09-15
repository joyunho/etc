-- test_spice.lua
--
-- The seasoning station: picking a job, loading the station, and getting past
-- NPC Friends' four-item gate.
--
--   lua5.1 tests/test_spice.lua
--
-- The stand-in for NPCCookingBehavior below is not a guess. It mirrors what the
-- shipped behaviour does, read out of the file itself:
--
--   * `_MakeTakeActionFn(items, taken)` returns fn(npc, container); the fn
--     moves each item into the NPC's inventory and appends its PREFAB NAME to
--     `taken` -- names, not entities.
--   * after the pickup route is exhausted, the behaviour needs #taken >= 4 or
--     it gives up.
--   * `_MakePutActionFn(taken, plan, node)` returns fn(npc, pot); the fn moves
--     up to four of those prefabs from the inventory into the pot and, if it
--     placed four and stewer:CanCook(), starts the pot inside
--     WithForcedProduct(plan.recipe_name, plan.cooktime, ...).
--
-- So a stand-in that enforces the same two gates is the thing worth testing
-- against: if our wrappers get a two-slot station loaded and started here, they
-- do it in the game for the same reasons.

io.stdout:setvbuf("line")

local here = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = here .. "/?.lua;" .. here .. "/../npcfriends_hof_cooking/scripts/?.lua;" .. package.path

local Stub = require("dst_stub")
Stub.Register()

local cooking = package.loaded["cooking"]

-- DST's spiced recipes, in DST's shape (scripts/spicedfoods.lua).
cooking.recipes.portablespicer = {}
for _, base in ipairs({ "meatballs", "bonestew", "wetgoop" }) do
	for _, spice in ipairs({ "SPICE_GARLIC", "SPICE_CHILI", "SPICE_SALT" }) do
		local name = base .. "_" .. string.lower(spice)
		cooking.recipes.portablespicer[name] =
		{
			name     = name,
			basename = base,
			spice    = spice,
			cooktime = 0.12,
			priority = 100,
			health   = 3,
			hunger   = 12.5,
			sanity   = 0,
			test     = function() return false end,
		}
	end
end

local Core  = require("hofnpc_core")
local Spice = require("hofnpc_spice")

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
--  Stand-ins
-- ═══════════════════════════════════════════════════════════════════════════

local guid = 0
local function NextGUID() guid = guid + 1 return guid end

local function Item(prefab, tags, stack)
	local tagset = {}
	for _, tag in ipairs(tags or {}) do tagset[tag] = true end

	local item
	item =
	{
		prefab = prefab,
		GUID   = NextGUID(),
		IsValid = function() return true end,
		HasTag  = function(self, tag) return tagset[tag] == true end,
		components = stack and stack > 1 and
		{
			stackable =
			{
				n = stack,
				StackSize = function(self) return self.n end,
				Get = function(self, count)
					self.n = self.n - (count or 1)
					return Item(prefab, tags, nil)
				end,
			},
		} or {},
	}
	return item
end

local function Container(items)
	local slots = {}
	for i, item in ipairs(items) do slots[i] = item end

	local ent
	ent =
	{
		prefab  = "treasurechest",
		GUID    = NextGUID(),
		IsValid = function() return true end,
		components =
		{
			container =
			{
				GetNumSlots   = function() return 9 end,
				GetItemInSlot = function(_, slot) return slots[slot] end,
				RemoveItemBySlot = function(_, slot)
					local it = slots[slot] slots[slot] = nil return it
				end,
			},
		},
	}
	return ent
end

-- A seasoning station: two slots, a stewer, and DST's own CanCook rule --
-- container:IsFull(), which for two slots means the dish and the spice.
local function Station()
	local held = {}
	local cooking_now, done, product = false, false, nil

	local ent
	ent =
	{
		prefab  = "portablespicer",
		GUID    = NextGUID(),
		IsValid = function() return true end,
		components =
		{
			container =
			{
				numslots    = 2,
				GetNumSlots = function() return 2 end,
				GiveItem    = function(_, item) held[#held + 1] = item return true end,
				IsFull      = function() return #held >= 2 end,
				slots       = held,
			},
			stewer =
			{
				IsCooking = function() return cooking_now end,
				IsDone    = function() return done end,
				CanCook   = function() return #held >= 2 end,
				StartCooking = function()
					cooking_now = true
					local names = {}
					for _, it in ipairs(held) do names[#names + 1] = it.prefab end
					product = cooking.CalculateRecipe("portablespicer", names)
				end,
			},
		},
	}
	ent.held    = held
	ent.Product = function() return product end
	ent.Cooking = function() return cooking_now end
	return ent
end

local function Chef()
	local slots = {}
	local inst
	inst =
	{
		prefab  = "npcfriend",
		GUID    = NextGUID(),
		IsValid = function() return true end,
		components =
		{
			inventory =
			{
				maxslots      = 15,
				GetItemInSlot = function(_, s) return slots[s] end,
				GiveItem      = function(_, item)
					for i = 1, 15 do
						if slots[i] == nil then slots[i] = item return true end
					end
					return false
				end,
				RemoveItem = function(_, item)
					for i = 1, 15 do
						if slots[i] == item then slots[i] = nil return item end
					end
					return nil
				end,
			},
		},
	}
	inst.slots = slots
	return inst
end

_G.GetTime = function() return 0 end

-- ═══════════════════════════════════════════════════════════════════════════
print("=== 1. recognising a seasoning station ===")

Core.Configure({ enabled = true, use_spicer = true, same_dish_max = 3, allow_negative = false })
Core.SetHost({})
Spice.Reset()

local station = Station()
check("a two-slot cooker with spiced recipes is a seasoning station", Spice.IsStation(station))

local pot = {
	prefab = "cookpot", GUID = NextGUID(), IsValid = function() return true end,
	components = {
		container = { numslots = 4, GetNumSlots = function() return 4 end },
		stewer = { IsCooking = function() return false end, IsDone = function() return false end },
	},
}
check("a Crock Pot is not", not Spice.IsStation(pot))

local twoslot = {
	prefab = "some_mod_thing", GUID = NextGUID(), IsValid = function() return true end,
	components = {
		container = { numslots = 2, GetNumSlots = function() return 2 end },
		stewer = { IsCooking = function() return false end, IsDone = function() return false end },
	},
}
check("a two-slot cooker with no spiced recipes is not", not Spice.IsStation(twoslot))

-- ═══════════════════════════════════════════════════════════════════════════
print("")
print("=== 2. finding the dish and the spice ===")

local chest = Container{
	Item("meatballs",   { "preparedfood" }, 4),
	Item("spice_garlic",{ "spice" }, 2),
	Item("berries",     {}),
	Item("bonestew_spice_salt", { "preparedfood", "spicedfood" }),
}

local pantry = Spice.Scan({ chest })
check("the cooked dish is found",        pantry.dishes.meatballs ~= nil)
check("the spice is found",              pantry.spices.spice_garlic ~= nil)
check("a raw ingredient is not a dish",  pantry.dishes.berries == nil)
check("an already spiced dish is left alone", pantry.dishes.bonestew_spice_salt == nil)

local job = Spice.Choose(station, pantry, {})
check("a job is chosen", job ~= nil and job.product == "meatballs_spice_garlic",
	job and job.product or "nil")
check("it names the dish and the spice",
	job ~= nil and job.dish.prefab == "meatballs" and job.spice.prefab == "spice_garlic")

check("no job when the larder is already full of it",
	Spice.Choose(station, pantry, { meatballs_spice_garlic = 3 }) == nil)

check("no job without a spice",
	Spice.Choose(station, Spice.Scan({ Container{ Item("meatballs", { "preparedfood" }) } }), {}) == nil)
check("no job without a dish",
	Spice.Choose(station, Spice.Scan({ Container{ Item("spice_garlic", { "spice" }) } }), {}) == nil)

local card = Spice.Card(job)
check("the card names the spiced dish", card.name == "meatballs_spice_garlic")
check("and asks for exactly two items", #card._selected_ingredients == 2)

-- ═══════════════════════════════════════════════════════════════════════════
print("")
print("=== 3. NPC Friends' four-item gate ===")

-- Their behaviour, reduced to the two gates that matter.
local Behaviour = {}
Behaviour.__index = Behaviour

function Behaviour._MakeTakeActionFn(self, items, taken)
	return function(npc, container)
		local cont = container.components.container
		for _, want in ipairs(items) do
			local item = cont:GetItemInSlot(want.slot)
			if item ~= nil and item.prefab == want.prefab then
				local one = item
				if item.components.stackable ~= nil and item.components.stackable:StackSize() > 1 then
					one = item.components.stackable:Get(want.take_count or 1)
				else
					cont:RemoveItemBySlot(want.slot)
				end
				npc.components.inventory:GiveItem(one)
				for _ = 1, (want.take_count or 1) do taken[#taken + 1] = want.prefab end
			end
		end
	end
end

function Behaviour._MakePutActionFn(self, taken, plan, node)
	return function(npc, target)
		-- Their loader: up to four prefabs out of the inventory into the pot,
		-- and only cook if it placed four.
		local placed = 0
		for _, prefab in ipairs(taken) do
			if placed >= 4 then break end
			for slot = 1, npc.components.inventory.maxslots do
				local item = npc.components.inventory:GetItemInSlot(slot)
				if item ~= nil and item.prefab == prefab then
					npc.components.inventory:RemoveItem(item)
					target.components.container:GiveItem(item)
					placed = placed + 1
					break
				end
			end
		end
		if placed >= 4 and target.components.stewer:CanCook() then
			target.components.stewer:StartCooking(npc)
		end
	end
end

_G.NPCCookingBehavior = Behaviour

-- The planner seam, with the one function our loader calls.
local forced_with = nil
local planner =
{
	WithForcedProduct = function(product, cooktime, fn)
		forced_with = product
		local orig = cooking.CalculateRecipe
		cooking.CalculateRecipe = function() return product, cooktime end
		pcall(fn)
		cooking.CalculateRecipe = orig
	end,
}
Core.SetHost({ planner = planner })

check("Attach finds the behaviour class", Spice.Attach(planner) == true)

-- Run a spice job through it exactly as the behaviour would.
local chef    = Chef()
local target  = Station()
local chest2  = Container{ Item("meatballs", { "preparedfood" }, 4), Item("spice_garlic", { "spice" }, 2) }
local pantry2 = Spice.Scan({ chest2 })
local job2    = Spice.Choose(target, pantry2, {})

Spice.npc = chef
Spice.Claim(job2)

local node  = { _plan = { cookpot = target, recipe_name = job2.product, cooktime = job2.cooktime } }
local taken = {}

local take = Behaviour._MakeTakeActionFn(node, {
	{ slot = 1, prefab = "meatballs",    take_count = 1 },
	{ slot = 2, prefab = "spice_garlic", take_count = 1 },
}, taken)
take(chef, chest2)

check("the chef is carrying two real items",
	#chef.slots > 0 and taken[1] == "meatballs" and taken[2] == "spice_garlic")
check("but the take list is padded to four, so their gate lets it through",
	#taken >= 4, tostring(#taken))

local put = Behaviour._MakePutActionFn(node, taken, node._plan, node)
put(chef, target)

check("the station was loaded with exactly two items", #target.held == 2,
	tostring(#target.held))
check("the dish went in",  target.held[1] ~= nil and target.held[1].prefab == "meatballs")
check("the spice went in", target.held[2] ~= nil and target.held[2].prefab == "spice_garlic")
check("the station started cooking", target.Cooking() == true)
check("and it made the dish the plan named", target.Product() == "meatballs_spice_garlic",
	tostring(target.Product()))
check("the product was forced, as NPC Friends does for a pot",
	forced_with == "meatballs_spice_garlic", tostring(forced_with))

-- ═══════════════════════════════════════════════════════════════════════════
print("")
print("=== 4. an ordinary cook is untouched ===")

local plain_taken = {}
local plain_node  = { _plan = { cookpot = pot, recipe_name = "meatballs", cooktime = 1 } }
local plain_take  = Behaviour._MakeTakeActionFn(plain_node, {
	{ slot = 1, prefab = "meatballs", take_count = 1 },
}, plain_taken)
plain_take(Chef(), Container{ Item("meatballs", { "preparedfood" }) })

check("a Crock Pot plan is not padded", #plain_taken == 1, tostring(#plain_taken))

-- Behaviour._MakePutActionFn is our wrapper by now; the one Attach set aside is
-- the real thing. Watch that, not the field, or the two call each other.
local called_through = false
local real_put = Spice._orig.put
Spice._orig.put = function(...) called_through = true return real_put(...) end
Behaviour._MakePutActionFn(plain_node, plain_taken, plain_node._plan, plain_node)
check("and its loader is NPC Friends' own", called_through)
Spice._orig.put = real_put

-- ═══════════════════════════════════════════════════════════════════════════
print("")
print("=== 5. it gives up rather than spinning ===")

Spice.Reset()
Spice.attached = true
Spice.pending  = job
Spice.npc      = chef
check("a job is offered", Spice.Wanted() == true)

Spice.last[chef.GUID] = true
check("but never twice in a row", Spice.Wanted() == false)

Spice.last[chef.GUID] = false
Spice.strikes = 3
check("and not at all once the station keeps refusing", Spice.Wanted() == false)

Spice.strikes = 0
Core.Configure({ use_spicer = false })
check("turning it off stops it", Spice.Wanted() == false)
Core.Configure({ use_spicer = true })

Spice.attached = false
check("and so does never having attached", Spice.Wanted() == false)

-- A missing behaviour class must not throw, just decline.
_G.NPCCookingBehavior = nil
Spice.attached = false
check("no behaviour class means no spicing, not a crash", Spice.Attach(planner) == false)

print("")
if failures == 0 then
	print("ALL CHECKS PASSED")
	os.exit(0)
else
	print(failures .. " CHECK(S) FAILED")
	os.exit(1)
end
