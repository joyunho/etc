-- test_realmods.lua
--
-- The one test that is not written against a fixture. It loads Don't Starve
-- Together's own cooking.lua, loads three real food mods on top of it, and asks
-- the shipped chef how many of their dishes it can actually work out how to
-- make.
--
--   lua5.1 tests/test_realmods.lua <dst-scripts> <workshop-content-322330>
--
-- Both folders are things the player already has:
--   <dst-scripts>   .../Don't Starve Together/data/scripts
--   <workshop>      .../steamapps/workshop/content/322330
--
-- Skips (exit 0) when either is missing, so the suite still runs on a machine
-- that does not have the game installed.
--
-- The three mods are the ones this was built for. What matters about them is
-- not their names but their shape: none of them carries a card_def, so the
-- exact path cannot touch them, and two of them add ingredients a player owns
-- two or three of, which is what the old blind combination search could not
-- reach. Every food mod that registers through AddCookerRecipe looks like this.

local here = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = here .. "/?.lua;" .. here .. "/../npcfriends_hof_cooking/scripts/?.lua;" .. package.path

local DST = arg[1] or os.getenv("DSTSCRIPTS")
local WS  = arg[2] or os.getenv("DSTWORKSHOP")

local function skip(why)
	print("  SKIP  tests/test_realmods.lua -- " .. why)
	os.exit(0)
end

if DST == nil or WS == nil then
	skip("pass <dst-scripts> <workshop-content-322330>, or set $DSTSCRIPTS and $DSTWORKSHOP")
end

local Real = require("dst_real")
local cooking, err = Real.Load(DST)
if cooking == nil then
	skip(tostring(err))
end

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
--  The mods, described exactly as their own modmain.lua registers them
-- ═══════════════════════════════════════════════════════════════════════════

local MODS =
{
	{
		id   = "1736542280",
		name = "Korean Foods & Items",
		-- modmain.lua:62-67 -- no AddIngredientValues at all; every recipe is
		-- built out of vanilla ingredients.
		scripts = "scripts",
		recipes =
		{
			{ module = "ko_foodrecipes",       cookers = { "cookpot", "portablecookpot", "archive_cookpot" } },
			{ module = "ko_foodrecipes_warly", cookers = { "portablecookpot" } },
		},
	},
	{
		id   = "2628511903",
		name = "Halloween Theme Food",
		-- modmain.lua:53-59
		scripts = "scripts",
		ingredients =
		{
			{ { "htf_eyerose" },      { veggie = 1.0 }, true },
			{ { "htf_blackmushroom" }, { veggie = 1.0 }, true },
		},
		recipes =
		{
			{ module = "htf_foodrecipes", cookers = { "cookpot", "portablecookpot", "archive_cookpot" } },
		},
	},
	{
		id   = "2981932326",
		name = "DST Coffee and More",
		-- init/init_cooking.lua -- modimport'ed, so it registers as it runs.
		files = { { path = "init/init_cooking.lua" } },
	},
}

_G.HasTheGorgeCookingPortMod = function() return false end

local moddish, loaded = {}, 0

for _, mod in ipairs(MODS) do
	local root  = WS .. "/" .. mod.id
	local probe = io.open(root .. "/modinfo.lua", "r")

	if probe == nil then
		print("  SKIP  " .. mod.name .. " (" .. mod.id .. ") is not installed")
	else
		probe:close()
		mod.root = root

		local added, e = Real.AddMod(mod)
		if added == nil then
			check("loading " .. mod.name, false, tostring(e))
		else
			loaded = loaded + 1
			local n = 0
			for name in pairs(added) do
				moddish[name] = mod.name
				n = n + 1
			end
			print(string.format("  --    %s: %d dishes", mod.name, n))
		end
	end
end

if loaded == 0 then
	skip("none of the three mods are in " .. WS)
end

-- ═══════════════════════════════════════════════════════════════════════════
--  A pantry a chef NPC would actually be looking at
-- ═══════════════════════════════════════════════════════════════════════════

local PANTRY =
{
	meat = 8, drumstick = 8, fish = 8, smallmeat = 8, monstermeat = 4,
	berries = 12, carrot = 10, corn = 10, pumpkin = 8, dragonfruit = 4,
	pomegranate = 6, onion = 8, garlic = 8, potato = 8, tomato = 8,
	asparagus = 6, watermelon = 6, honey = 10, ice = 20, twigs = 10,
	butter = 4, bird_egg = 8, red_cap = 6, blue_cap = 6, green_cap = 6,
	-- the two mods that add ingredients, in the amount a player would have
	htf_eyerose = 6, htf_blackmushroom = 6,
	coffeebeans = 8, coffee_ground = 8, coffee_filter = 8,
}

-- Every one of those must be something the game itself calls an ingredient,
-- because that is the test NPC Friends' own ScanIngredients applies before an
-- item ever reaches us.
local unknown = {}
for prefab in pairs(PANTRY) do
	if not cooking.IsCookingIngredient(prefab) then
		unknown[#unknown + 1] = prefab
	end
end
table.sort(unknown)
check("every pantry item is a cooking ingredient the game recognises",
	#unknown == 0, table.concat(unknown, ", "))

local function NewPool()
	local pool = {}
	for prefab, total in pairs(PANTRY) do
		pool[prefab] = { total = total, locations = { { container = { GUID = 1 }, slot = 1, count = total } } }
	end
	return pool
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Run the chef
-- ═══════════════════════════════════════════════════════════════════════════

package.loaded["cooking"] = cooking

local Core    = require("hofnpc_core")
local Search  = require("hofnpc_search")
local Variety = require("hofnpc_variety")

-- NPC Friends asks for "portablecookpot" when the chef is Warly and for the
-- pot's own prefab otherwise (npc_cooking_planner.lua: PlanCooking), so both
-- have to work. All three mods register on both.
local COOKER = "portablecookpot"

local total_mod = 0
for name in pairs(moddish) do
	if cooking.recipes[COOKER][name] then
		total_mod = total_mod + 1
	end
end
print(string.format("  --    %d mod dishes registered on %s", total_mod, COOKER))

local function Run(budget, passes)
	math.randomseed(20260915)
	Search.ResetCache()
	Search.ResetInterests()
	Variety.Reset()
	Core.ClearScoreCache()
	Core.Configure({ debug = false, variety = "medium", budget = budget, same_dish_max = 3 })
	Core.SetHost({})

	local pool, existing, cooked = NewPool(), {}, {}
	local worst = 0

	for _ = 1, passes do
		local t0 = os.clock()
		local chosen = Search.Choose(pool, existing, true, COOKER)
		worst = math.max(worst, (os.clock() - t0) * 1000)

		if chosen ~= nil then
			cooked[chosen.name] = true
			existing[chosen.name] = (existing[chosen.name] or 0) + 1
		end
	end

	local found, made, distinct = 0, 0, 0
	for _, entry in pairs(Search._cache) do
		for product in pairs(entry.map) do
			if moddish[product] then found = found + 1 end
		end
	end
	for product in pairs(cooked) do
		distinct = distinct + 1
		if moddish[product] then made = made + 1 end
	end

	return found, made, distinct, worst
end

print("")
for _, budget in ipairs({ "low", "medium", "high" }) do
	local found, made, distinct, worst = Run(budget, 60)
	print(string.format("  --    budget=%-6s  worked out %d/%d mod dishes, cooked %d of them, %d dishes in all, worst pass %.1f ms",
		budget, found, total_mod, made, distinct, worst))

	-- Before the recipe-directed pass existed these were 9, 15 and 25 found and
	-- 5, 9 and 15 cooked, and the medium pass cost 22 ms. The thresholds are
	-- set below what was measured so a slower machine or a mod update does not
	-- turn this red, but well above the old behaviour.
	check(budget .. ": most of the mod cookbook is reachable", found >= 24,
		found .. "/" .. total_mod)
	check(budget .. ": mod dishes actually get cooked", made >= 12, tostring(made))
	check(budget .. ": a planning pass stays well inside a server tick", worst < 25,
		string.format("%.1f ms", worst))
end

-- The ingredients the mods added must be the reason, not incidental: a chef
-- that never touches htf_eyerose cannot be cooking Halloween Theme Food.
local function UsesModIngredient()
	math.randomseed(20260915)
	Search.ResetCache(); Search.ResetInterests(); Variety.Reset(); Core.ClearScoreCache()
	Core.Configure({ variety = "medium", budget = "medium", same_dish_max = 3 })
	Core.SetHost({})

	local pool, existing, used = NewPool(), {}, {}
	for _ = 1, 60 do
		local chosen = Search.Choose(pool, existing, true, COOKER)
		if chosen ~= nil then
			existing[chosen.name] = (existing[chosen.name] or 0) + 1
			for _, ing in ipairs(chosen._selected_ingredients or {}) do
				used[ing.prefab] = true
			end
		end
	end
	return used
end

-- A non-Warly chef cooks at a plain Crock Pot, so that table has to work too.
do
	local before = COOKER
	COOKER = "cookpot"

	local total = 0
	for name in pairs(moddish) do
		if cooking.recipes.cookpot[name] then total = total + 1 end
	end

	local found, made = Run("medium", 60)
	print("")
	print(string.format("  --    a plain cookpot: worked out %d/%d mod dishes, cooked %d",
		found, total, made))
	check("a non-Warly chef at a plain Crock Pot reaches them too", found >= 20,
		found .. "/" .. total)

	COOKER = before
end

local used = UsesModIngredient()
local wanted = { "htf_eyerose", "htf_blackmushroom" }
local unused = {}
for _, prefab in ipairs(wanted) do
	if cooking.IsCookingIngredient(prefab) and not used[prefab] then
		unused[#unused + 1] = prefab
	end
end
print("")
check("the ingredients the mods added are put in the pot", #unused == 0,
	"never used: " .. table.concat(unused, ", "))

print("")
if failures == 0 then
	print("ALL CHECKS PASSED")
	os.exit(0)
else
	print(failures .. " CHECK(S) FAILED")
	os.exit(1)
end
