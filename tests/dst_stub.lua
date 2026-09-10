-- dst_stub.lua
--
-- A faithful-enough stand-in for Don't Starve Together's cooking system, so the
-- patch can be exercised outside the game: ingredient tag accumulation, recipe
-- test functions, priority tie-breaking and the wetgoop fallback all behave the
-- way scripts/cooking.lua does.
--
-- It is loaded into package.loaded["cooking"], which is what both the patch
-- modules and the built npc_hof_cooking.lua require.

local Stub = {}

local cooking = { ingredients = {}, recipes = {} }
local calls = 0

function Stub.Calls() return calls end
function Stub.ResetCalls() calls = 0 end

local function AddIngredient(name, tags)
	cooking.ingredients[name] = { tags = tags }
end

local function AddCookerRecipe(cooker, recipe)
	cooking.recipes[cooker] = cooking.recipes[cooker] or {}
	cooking.recipes[cooker][recipe.name] = recipe
end

function cooking.IsCookingIngredient(name)
	return cooking.ingredients[name] ~= nil
end

local function GetIngredientValues(names)
	local tags, counts = {}, {}
	for _, n in ipairs(names) do
		counts[n] = (counts[n] or 0) + 1
		local data = cooking.ingredients[n]
		if data and data.tags then
			for tag, val in pairs(data.tags) do
				tags[tag] = (tags[tag] or 0) + val
			end
		end
	end
	return { tags = tags, names = counts }
end

function cooking.CalculateRecipe(cooker, names)
	calls = calls + 1

	local ing  = GetIngredientValues(names)
	local pool = cooking.recipes[cooker] or {}

	local best, best_priority = nil, nil
	for _, recipe in pairs(pool) do
		if recipe.test(cooker, ing.names, ing.tags) then
			local p = recipe.priority or 0
			if best_priority == nil or p > best_priority then
				best, best_priority = recipe, p
			end
		end
	end

	if best == nil then
		return "wetgoop", 0.5
	end
	return best.name, best.cooktime or 1
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Vanilla-ish ingredients
-- ═══════════════════════════════════════════════════════════════════════════

AddIngredient("meat",        { meat = 1 })
AddIngredient("smallmeat",   { meat = 0.5 })
AddIngredient("monstermeat", { meat = 1, monster = 1 })
AddIngredient("berries",     { fruit = 0.5 })
AddIngredient("carrot",      { veggie = 1 })
AddIngredient("corn",        { veggie = 1 })
AddIngredient("potato",      { veggie = 1 })
AddIngredient("dragonfruit", { fruit = 1 })
AddIngredient("honey",       { sweetener = 1 })
AddIngredient("butter",      { fat = 1, dairy = 1 })
AddIngredient("ice",         { frozen = 1 })
AddIngredient("twigs",       { inedible = 1 })
AddIngredient("bird_egg",    { egg = 1 })
AddIngredient("red_cap",     { veggie = 0.5 })
AddIngredient("fishmeat",    { meat = 1, fish = 1 })
AddIngredient("goatmilk",    { dairy = 1 })

-- ═══════════════════════════════════════════════════════════════════════════
--  "Heap of Foods" style ingredients -- real custom tags, matching the shape of
--  that mod's own AddIngredientValues calls.
-- ═══════════════════════════════════════════════════════════════════════════

local MOD_INGREDIENTS = {
	{ "kyno_flour",       { inedible = 1,  flour     = 1 } },
	{ "kyno_syrup",       { sweetener = 1, syrup     = 1 } },
	{ "kyno_bacon",       { meat = 0.5,    bacon     = 1 } },
	{ "kyno_white_cap",   { veggie = 0.5,  mushrooms = 1 } },
	{ "kyno_foliage",     { veggie = 0.25, foliage   = 1 } },
	{ "kyno_radish",      { veggie = 1 } },
	{ "kyno_mussel",      { fish = 0.5,    mussel    = 1 } },
	{ "kyno_shark_fin",   { fish = 1 } },
	{ "kyno_aloe",        { veggie = 1,    succulent = 1 } },
	{ "kyno_coffeebeans", { seeds = 1 } },
	{ "kyno_beanbugs",    { beanbug = 1,   veggie    = 0.5 } },
	{ "gorge_bread",      { bread = 1 } },
	{ "kyno_sap",         { inedible = 1,  sap       = 1 } },
	{ "kyno_cheese",      { dairy = 1,     cheese    = 1 } },
	{ "kyno_tomato",      { veggie = 1,    tomato    = 1 } },
}
for _, e in ipairs(MOD_INGREDIENTS) do
	AddIngredient(e[1], e[2])
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Dishes
-- ═══════════════════════════════════════════════════════════════════════════

Stub.COOKER = "portablecookpot"
local C = Stub.COOKER

AddCookerRecipe(C, { name = "meatballs", priority = -1, cooktime = 0.5,
	health = 3, hunger = 62.5, sanity = 5,
	test = function(c, n, t) return (t.meat or 0) >= 1 and (t.inedible or 0) < 1 end })

AddCookerRecipe(C, { name = "baconeggs", priority = 10, cooktime = 1,
	health = 20, hunger = 75, sanity = 5,
	test = function(c, n, t) return (t.egg or 0) >= 2 and (t.meat or 0) >= 2 end })

AddCookerRecipe(C, { name = "honeyham", priority = 2, cooktime = 1,
	health = 30, hunger = 75, sanity = 5,
	test = function(c, n, t) return (t.sweetener or 0) >= 1 and (t.meat or 0) >= 1.5 end })

AddCookerRecipe(C, { name = "dragonpie", priority = 10, cooktime = 1,
	health = 40, hunger = 75, sanity = 5,
	test = function(c, n, t) return (n.dragonfruit or 0) >= 1 and (t.meat or 0) == 0 end })

AddCookerRecipe(C, { name = "ratatouille", priority = 0, cooktime = 0.5,
	health = 3, hunger = 25, sanity = 5,
	test = function(c, n, t) return (t.veggie or 0) >= 0.5 and (t.meat or 0) == 0 end })

AddCookerRecipe(C, { name = "monsterlasagna", priority = 10, cooktime = 1,
	health = -20, hunger = 37.5, sanity = -20,
	test = function(c, n, t) return (t.monster or 0) >= 2 end })

AddCookerRecipe(C, { name = "icecream", priority = 10, cooktime = 1,
	health = 0, hunger = 25, sanity = 50,
	test = function(c, n, t)
		return (t.dairy or 0) >= 1 and (t.sweetener or 0) >= 1 and (t.frozen or 0) >= 1
			and (t.meat or 0) == 0 and (t.veggie or 0) == 0
	end })

Stub.MOD_DISHES = {
	{ "kyno_pancakes",     { flour = 1, sweetener = 1 },  30, 60, 15, 12 },
	{ "kyno_baconpie",     { bacon = 1, flour = 1 },      40, 75, 10, 12 },
	{ "kyno_mushroomsoup", { mushrooms = 2 },             20, 50, 20, 11 },
	{ "kyno_seafoodgumbo", { mussel = 1, fish = 1 },      30, 62, 15, 12 },
	{ "kyno_sharkfinsoup", { fish = 2 },                  45, 75,  5, 13 },
	{ "kyno_beansalad",    { beanbug = 1, veggie = 1 },   15, 37, 10, 11 },
	{ "kyno_frenchtoast",  { bread = 1, egg = 1 },        25, 50, 12, 12 },
	{ "kyno_syrupcake",    { syrup = 1, flour = 1 },      20, 62, 25, 13 },
	{ "kyno_cheesecake",   { cheese = 1, sweetener = 1 }, 30, 60, 30, 13 },
	{ "kyno_caprese",      { tomato = 1, cheese = 1 },    25, 45, 20, 12 },
	{ "kyno_aloejuice",    { succulent = 1 },             15, 25, 25, 10 },
	{ "kyno_coffee",       { seeds = 1, sweetener = 1 },   0, 20, 40, 11 },
	{ "kyno_foliagewrap",  { foliage = 1, meat = 1 },     20, 55,  5, 11 },
	{ "kyno_saptaffy",     { sap = 1, sweetener = 1 },    10, 40, 15, 11 },
	{ "kyno_radishstew",   { veggie = 2, flour = 1 },     25, 55, 10, 12 },
	-- Costs health and sanity, but is on nobody's blacklist: this is what
	-- allow_negative actually gates.
	{ "kyno_bitterbrew",   { sap = 2 },                  -10, 30, -5, 14 },
}

for _, d in ipairs(Stub.MOD_DISHES) do
	local name, req, health, hunger, sanity, priority = d[1], d[2], d[3], d[4], d[5], d[6]
	AddCookerRecipe(C, {
		name = name, priority = priority, cooktime = 1,
		health = health, hunger = hunger, sanity = sanity,
		test = function(c, n, t)
			for tag, amount in pairs(req) do
				if (t[tag] or 0) < amount then return false end
			end
			return true
		end,
	})
end

function Stub.IsModDish(name)
	return name:sub(1, 5) == "kyno_" or name == "gorge_bread"
end

-- ═══════════════════════════════════════════════════════════════════════════
--  A pantry, in the shape CookingPlanner.ScanIngredients produces
-- ═══════════════════════════════════════════════════════════════════════════

function Stub.MakePool(spec)
	local pool, guid = {}, 0
	for _, e in ipairs(spec) do
		guid = guid + 1
		pool[e[1]] = {
			total = e[2],
			locations = { { container = { GUID = guid, prefab = "icebox" }, slot = guid % 9 + 1, count = e[2] } },
		}
	end
	return pool
end

Stub.PANTRY = Stub.MakePool{
	{ "meat", 4 }, { "smallmeat", 6 }, { "berries", 8 }, { "carrot", 6 },
	{ "corn", 6 }, { "potato", 4 }, { "honey", 6 }, { "butter", 2 },
	{ "ice", 8 }, { "twigs", 10 }, { "bird_egg", 6 }, { "goatmilk", 3 },
	{ "dragonfruit", 2 }, { "fishmeat", 4 }, { "red_cap", 4 },
	{ "kyno_flour", 8 }, { "kyno_syrup", 4 }, { "kyno_bacon", 4 },
	{ "kyno_white_cap", 6 }, { "kyno_mussel", 4 }, { "kyno_shark_fin", 3 },
	{ "kyno_cheese", 4 }, { "kyno_tomato", 5 }, { "kyno_aloe", 3 },
	{ "kyno_coffeebeans", 4 }, { "gorge_bread", 4 }, { "kyno_foliage", 5 },
	{ "kyno_sap", 3 }, { "kyno_radish", 5 }, { "kyno_beanbugs", 3 },
}

-- Stand-ins for the two NPC Friends modules the patch reads.
Stub.NPC_TUNING = {
	COOK_SAME_DISH_MAX    = 3,
	COOK_RECIPE_BLACKLIST = { wetgoop = true, ratatouille = true },
}

Stub.NPC_COOKING_RECIPES = {
	IsExcluded = function(name) return name == "monsterlasagna" end,
}

function Stub.Register()
	package.loaded["cooking"] = cooking
	package.loaded["npc_tuning"] = Stub.NPC_TUNING
	package.loaded["npc/npc_cooking_recipes"] = Stub.NPC_COOKING_RECIPES
	return cooking
end

Stub.cooking = cooking

return Stub
