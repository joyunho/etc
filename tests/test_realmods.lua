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
			{ module = "ko_foodspicer",        cookers = { "portablespicer" } },
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
			{ module = "htf_foodspicer",  cookers = { "portablespicer" } },
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
	local worst, times = 0, {}

	for _ = 1, passes do
		local t0 = os.clock()
		local chosen = Search.Choose(pool, existing, true, COOKER)
		local ms = (os.clock() - t0) * 1000
		worst = math.max(worst, ms)
		times[#times + 1] = ms

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

	table.sort(times)
	local typical = #times > 0 and times[math.ceil(#times / 2)] or 0
	return found, made, distinct, worst, typical
end

print("")
for _, budget in ipairs({ "low", "medium", "high" }) do
	local found, made, distinct, worst, typical = Run(budget, 60)
	print(string.format("  --    budget=%-6s  worked out %d/%d mod dishes, cooked %d of them, %d dishes in all, typical pass %.1f ms, worst %.1f ms",
		budget, found, total_mod, made, distinct, typical, worst))

	-- Before the recipe-directed pass existed these were 9, 15 and 25 found and
	-- 5, 9 and 15 cooked, and the medium pass cost 22 ms. The thresholds are
	-- set below what was measured so a slower machine or a mod update does not
	-- turn this red, but well above the old behaviour.
	check(budget .. ": most of the mod cookbook is reachable", found >= 24,
		found .. "/" .. total_mod)
	check(budget .. ": mod dishes actually get cooked", made >= 12, tostring(made))

	-- Two separate claims, because the worst of sixty passes on a shared
	-- machine is mostly a measure of how busy the machine was. What the game
	-- needs is that the ordinary pass is cheap and that even a bad one still
	-- fits the 33 ms of a server tick.
	check(budget .. ": the ordinary planning pass is cheap", typical < 15,
		string.format("%.1f ms", typical))
	check(budget .. ": even the worst pass fits a server tick", worst < 33,
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

-- ═══════════════════════════════════════════════════════════════════════════
--  The station the chef walks to
-- ═══════════════════════════════════════════════════════════════════════════
--
-- hofnpc_cookware refuses any station too small to hold a four-ingredient dish.
-- The number that makes that right is DST's own, so read it from DST.

local Cookware = require("hofnpc_cookware")

local containers, cerr = Real.Containers()
if containers == nil then
	print("  SKIP  containers.lua did not load -- " .. tostring(cerr))
else
	local function Slots(prefab)
		local params = containers.params[prefab]
		return params and params.widget and params.widget.slotpos and #params.widget.slotpos or nil
	end

	local function Station(prefab)
		local n = Slots(prefab)
		return
		{
			prefab = prefab, GUID = 1,
			IsValid = function() return true end,
			components =
			{
				stewer = { IsCooking = function() return false end, IsDone = function() return false end },
				container = n and { numslots = n, GetNumSlots = function(self) return self.numslots end } or nil,
			},
		}
	end

	print("")
	for _, prefab in ipairs({ "cookpot", "portablecookpot", "archive_cookpot", "portablespicer" }) do
		print(string.format("  --    %-18s %s slots (from DST's containers.lua)", prefab, tostring(Slots(prefab))))
	end

	check("DST says a Crock Pot has four slots", Slots("cookpot") == 4, tostring(Slots("cookpot")))
	check("DST says Warly's seasoning station has two", Slots("portablespicer") == 2,
		tostring(Slots("portablespicer")))

	for _, prefab in ipairs({ "cookpot", "portablecookpot", "archive_cookpot" }) do
		check(prefab .. " is accepted as a place to cook", Cookware.CanTakeLoad(Station(prefab)))
	end
	check("the seasoning station is not", not Cookware.CanTakeLoad(Station("portablespicer")))

	-- And the thing that actually goes wrong in a Warly base: the station is in
	-- the list, listed first, and the chef must still find the pot.
	Cookware.Reset()
	Core.Configure({ enabled = true, spread_cookware = true })
	local chosen = Cookware.FindAvailableCookpot({ Station("portablespicer"), Station("cookpot") })
	check("a seasoning station next to the pot does not stall the chef",
		chosen ~= nil and chosen.prefab == "cookpot", chosen and chosen.prefab or "nil")
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Things the player makes by hand
-- ═══════════════════════════════════════════════════════════════════════════
--
-- The Mealing Stone is a prototyper -- a crafting bench -- so the chef cannot
-- work it, and nothing here tries to. What matters is the other half: when the
-- player grinds a bag of flour and drops it in a chest, the chef has to know
-- what to do with it.
--
-- It does, and for a reason worth pinning down rather than assuming. NPC
-- Friends decides what is an ingredient with exactly one test --
-- cooking.IsCookingIngredient(prefab), in ScanIngredients -- and Heap of Foods
-- registers all seven of the Mealing Stone's products through the ordinary
-- AddIngredientValues. So the answer is yes for the same reason it is yes for
-- a carrot. This checks that the answer really is yes, against Heap of Foods'
-- own registration rather than a list copied out of it.

do
	local hof = WS .. "/2334209327"
	local ok, err = Real.LoadHeapOfFoods(hof)
	local stopped = err

	if not ok then
		print("")
		print("  SKIP  Heap of Foods is not installed -- " .. tostring(err))
	else
		-- The seven things a Mealing Stone makes (hof_recipes.lua, the recipes
		-- whose actionstr is MEALGRINDER; the _w entries are Warly's versions
		-- of the same recipes and produce the same seven).
		local GROUND =
		{
			"kyno_flour", "kyno_spotspice", "kyno_salt", "kyno_bacon",
			"kyno_oil", "kyno_sugar", "kyno_opalpreciouspowder",
		}

		local missing, known = {}, 0
		for _, prefab in ipairs(GROUND) do
			if cooking.IsCookingIngredient(prefab) then
				known = known + 1
			else
				missing[#missing + 1] = prefab
			end
		end

		print("")
		if known == 0 then
			print("  SKIP  hof_cooking.lua registered nothing -- " .. tostring(stopped))
		else
			for _, prefab in ipairs(GROUND) do
				local data = cooking.ingredients[prefab]
				local tags = {}
				for tag, value in pairs(data ~= nil and data.tags or {}) do
					tags[#tags + 1] = tag .. "=" .. tostring(value)
				end
				table.sort(tags)
				print(string.format("  --    %-26s %s", prefab,
					#tags > 0 and table.concat(tags, ", ") or "(no tags)"))
			end

			check("everything the Mealing Stone makes is a cooking ingredient",
				#missing == 0, table.concat(missing, ", "))

			-- And that it survives the chef's own pantry test, which is the one
			-- NPC Friends applies before an item ever reaches this patch.
			local ground_pool = {}
			for _, prefab in ipairs(GROUND) do
				if cooking.IsCookingIngredient(prefab) then
					ground_pool[prefab] = { total = 4,
						locations = { { container = { GUID = 7 }, slot = 1, count = 4 } } }
				end
			end

			Core.Configure({ enabled = true, variety = "medium", budget = "medium" })
			Core.SetHost({})
			Search.ResetCache(); Search.ResetInterests()

			local seen = {}
			for prefab in pairs(ground_pool) do
				seen[#seen + 1] = prefab
			end
			check("a chest of ground ingredients is a pantry, not an empty room",
				#seen == #GROUND, #seen .. "/" .. #GROUND)
		end
	end
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Spicing, against DST's own 316 spiced recipes
-- ═══════════════════════════════════════════════════════════════════════════
--
-- hofnpc_stations reads a spiced recipe's own basename and spice rather than
-- searching for anything. That only works if every spiced recipe really does
-- carry them, so count them in the live table.

local Stations = require("hofnpc_stations")

do
	local spicer = cooking.recipes.portablespicer or {}
	local total, stated = 0, 0
	for _, recipe in pairs(spicer) do
		total = total + 1
		if recipe.basename ~= nil and recipe.spice ~= nil then stated = stated + 1 end
	end

	print("")
	print(string.format("  --    %d spiced recipes registered, %d state their own dish and spice",
		total, stated))
	check("every spiced recipe states what it is made of", total > 0 and stated == total,
		stated .. "/" .. total)

	-- And the mods' own spiced dishes are in there: both run DST's
	-- GenerateSpicedFoods over their food tables.
	local modspiced = 0
	for name, recipe in pairs(spicer) do
		if recipe.basename ~= nil and moddish[recipe.basename] ~= nil then modspiced = modspiced + 1 end
	end
	print(string.format("  --    %d of them are spiced versions of the food mods' dishes", modspiced))
	check("the food mods' dishes can be spiced too", modspiced > 0, tostring(modspiced))

	-- Pick a job the way the chef would, from a real station and a real chest.
	local held = {}
	local function Item(prefab, tags, stack)
		local set = {}
		for _, tag in ipairs(tags) do set[tag] = true end
		return { prefab = prefab, IsValid = function() return true end,
			HasTag = function(_, tag) return set[tag] == true end,
			components = stack and { stackable = { StackSize = function() return stack end } } or {} }
	end
	held[1] = Item("meatballs", { "preparedfood" }, 3)
	held[2] = Item("spice_garlic", { "spice" }, 2)

	local chest =
	{
		IsValid = function() return true end,
		components = { container = {
			GetNumSlots   = function() return 9 end,
			GetItemInSlot = function(_, slot) return held[slot] end,
		} },
	}

	local station =
	{
		prefab = "portablespicer", GUID = 1, IsValid = function() return true end,
		components =
		{
			container = { numslots = 2, GetNumSlots = function() return 2 end },
			stewer = { IsCooking = function() return false end, IsDone = function() return false end },
		},
	}

	check("a real seasoning station is recognised", Stations.IsStation(station))

	Core.Configure({ enabled = true, use_spicer = true, same_dish_max = 3, allow_negative = true })
	local job = Stations.Choose(station, Stations.Scan({ chest }), {})
	check("a job is picked from the real recipe table",
		job ~= nil and job.product == "meatballs_spice_garlic", job and job.product or "nil")

	-- The forced product has to exist in the station's table, because
	-- Stewer:StartCooking indexes cooking.GetRecipe(prefab, product).perishtime
	-- straight after, with no nil check.
	check("the dish it names is a recipe the station knows",
		job ~= nil and cooking.recipes.portablespicer[job.product] ~= nil)
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Coffee, which only gets made when negative dishes are allowed
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Every DST Coffee and More dish costs 5 sanity, on purpose. The shipped
-- default now allows that; with it off not one of them can ever be cooked.

local COFFEE = { "espresso", "black_coffee", "cappuccino", "latte", "caramel_macchiato", "coffeeham" }

local function CoffeeMade(allow_negative)
	math.randomseed(20260915)
	Search.ResetCache(); Search.ResetInterests(); Variety.Reset(); Core.ClearScoreCache()
	Core.Configure({ variety = "medium", budget = "medium", same_dish_max = 3,
		allow_negative = allow_negative })
	Core.SetHost({})

	local pool, existing, made = NewPool(), {}, {}
	for _ = 1, 80 do
		local chosen = Search.Choose(pool, existing, true, COOKER)
		if chosen ~= nil then
			existing[chosen.name] = (existing[chosen.name] or 0) + 1
			made[chosen.name] = true
		end
	end

	local n = {}
	for _, name in ipairs(COFFEE) do
		if made[name] then n[#n + 1] = name end
	end
	return n
end

print("")
if cooking.recipes[COOKER].espresso == nil then
	print("  SKIP  DST Coffee and More is not installed")
else
	local with    = CoffeeMade(true)
	local without = CoffeeMade(false)
	print("  --    allow_negative = true  -> " .. (#with > 0 and table.concat(with, ", ") or "none"))
	print("  --    allow_negative = false -> " .. (#without > 0 and table.concat(without, ", ") or "none"))
	check("coffee gets brewed once negative dishes are allowed", #with > 0)
	check("and never gets brewed while they are not", #without == 0,
		table.concat(without, ", "))
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
