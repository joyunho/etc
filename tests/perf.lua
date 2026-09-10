-- perf.lua
--
-- Measures the cost of one planning pass at Heap of Foods scale, because the
-- whole design rests on the claim that probing the game's recipe resolver a
-- bounded number of times is cheap enough to do on a live server.
--
--   lua5.1 tests/perf.lua
--
-- The synthetic world here is deliberately worse than a real one: 250 recipes
-- on a single cooker and a 40-type pantry is more than Heap of Foods plus
-- vanilla, and more ingredient variety than most bases keep in reach.

local here = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = here .. "/../npcfriends_hof_cooking/scripts/?.lua;" .. package.path

math.randomseed(7)

local RECIPE_COUNT   = 250
local PANTRY_TYPES   = 40
local WARM_PASSES    = 10

local TAGS = {
	"meat", "veggie", "fruit", "fish", "egg", "dairy", "sweetener", "frozen",
	"inedible", "flour", "syrup", "bacon", "mushrooms", "foliage", "mussel",
	"cheese", "tomato", "seeds", "sap", "bread",
}

local cooking = { ingredients = {}, recipes = { portablecookpot = {} } }
local calls = 0

function cooking.IsCookingIngredient(name)
	return cooking.ingredients[name] ~= nil
end

for i = 1, 60 do
	local tags = {}
	for k = 0, 2 do
		tags[TAGS[((i + k * 7) % #TAGS) + 1]] = (k == 0) and 1 or 0.5
	end
	cooking.ingredients["ing_" .. i] = { tags = tags }
end

for i = 1, RECIPE_COUNT do
	local a, b = TAGS[(i % #TAGS) + 1], TAGS[((i * 3) % #TAGS) + 1]
	local need_a = 1 + (i % 2)
	cooking.recipes.portablecookpot["dish_" .. i] =
	{
		name     = "dish_" .. i,
		priority = i % 20,
		cooktime = 1,
		health   = (i % 5) * 5,
		hunger   = 25 + (i % 4) * 12.5,
		sanity   = (i % 3) * 5,
		test     = function(c, n, t)
			return (t[a] or 0) >= need_a and (t[b] or 0) >= 0.5
		end,
	}
end

function cooking.CalculateRecipe(cooker, names)
	calls = calls + 1

	local tags = {}
	for _, name in ipairs(names) do
		local data = cooking.ingredients[name]
		if data then
			for tag, value in pairs(data.tags) do
				tags[tag] = (tags[tag] or 0) + value
			end
		end
	end

	local best, best_priority = nil, nil
	for _, recipe in pairs(cooking.recipes[cooker]) do
		if recipe.test(cooker, names, tags) then
			if best_priority == nil or recipe.priority > best_priority then
				best, best_priority = recipe, recipe.priority
			end
		end
	end

	if best == nil then
		return "wetgoop", 0.5
	end
	return best.name, best.cooktime
end

package.loaded["cooking"] = cooking

local Core    = require("hofnpc_core")
local Search  = require("hofnpc_search")
local Variety = require("hofnpc_variety")

Core.SetHost{ tuning = { COOK_SAME_DISH_MAX = 3 }, recipes = {} }

local pool = {}
for i = 1, PANTRY_TYPES do
	pool["ing_" .. i] =
	{
		total = 6,
		locations = { { container = { GUID = i }, slot = 1, count = 6 } },
	}
end

print(string.format("recipes=%d  pantry types=%d  (Lua %s)",
	RECIPE_COUNT, PANTRY_TYPES, _VERSION))
print("")
print("budget   cold pass            warm pass            first dish")
print("-------  -------------------  -------------------  ----------")

for _, budget in ipairs({ "low", "medium", "high" }) do
	Core.Configure{ variety = "medium", budget = budget }
	Search.ResetCache()
	Variety.Reset()

	calls = 0
	local t0 = os.clock()
	local card = Search.Choose(pool, {}, true, "portablecookpot")
	local cold, cold_calls = os.clock() - t0, calls

	calls = 0
	local t1 = os.clock()
	for _ = 1, WARM_PASSES do
		Search.Choose(pool, {}, true, "portablecookpot")
	end
	local warm = (os.clock() - t1) / WARM_PASSES

	print(string.format("%-7s  %6.1f ms / %4d probes  %5.1f ms / %3d probes  %s",
		budget, cold * 1000, cold_calls, warm * 1000, calls / WARM_PASSES,
		card and card.name or "nil"))
end

print("")
print("A pass only runs when a pot is free and the chef decides to cook, and the")
print("cold cost is paid again only when the set of ingredient types in reach")
print("changes. Everything in between is a warm pass.")
