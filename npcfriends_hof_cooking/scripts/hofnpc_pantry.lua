-- hofnpc_pantry.lua
-- Getting mod food into the fridge in the first place.
--
-- The chef was never the problem. NPC Friends' ingredient scan asks the game
-- itself -- cooking.IsCookingIngredient(prefab) -- so anything a food mod
-- registers is accepted the moment it is in a container the chef can see.
--
-- Getting it there is the problem. Every NPC decides what to pick up, what to
-- put in the fridge and what to leave alone through one function,
-- npc/npc_item_classify.lua's GetCategory, and that function is a whitelist of
-- prefab names with one tag fallback:
--
--     ICEBOX[prefab]            -> icebox      (201 vanilla foods, by name)
--     item:HasTag("preparedfood")  -> icebox    (crock pot dishes)
--     item:HasTag("icebox_valid")  -> icebox    (heat stones, ham bats, eggs)
--     anything else                -> ignore    (not picked up, not stored)
--
-- A modded vegetable carries neither tag. Heap of Foods' Eyerose and Black
-- Mushroom are `cookable`, `edible` and `perishable`, and none of those is on
-- the list, so every NPC walked past them. That is why they "were not
-- recognised" by Warly and by Wormwood alike: not two bugs in two characters,
-- one list they were both reading.
--
-- The same hole swallows more than the two: eighteen kinds of ocean fish,
-- pond fish, eel, tallbird eggs, cut lichen, mole, wormlight, and every
-- ingredient of the coffee mod.
--
-- npc_item_classify.lua ends by exporting its tables by reference, with the
-- comment 导出表格引用（允许外部运行时扩展） -- "exported by reference, so they
-- can be extended at runtime". So this does not wrap or replace anything. It
-- fills in their table through the door they left open, which means GetCategory
-- and IsIceboxItem both pick it up, and so does every behaviour that calls
-- them: collecting from the ground, stocking the fridge, merging containers.

local Core = require("hofnpc_core")

local Pantry = {}

-- What the game calls a decoration is not food, whatever else is true of it.
-- Forget-me-lots and refined dust are cooking ingredients and belong in a
-- chest, not in the ice box.
local NOT_FOOD = { decoration = true, inedible = true }

-- Suffixes the game itself adds when it registers a raw ingredient with
-- cancook or candry, so `mandrake_cooked` can be traced back to `mandrake`.
local DERIVED = { "_cooked", "_dried" }

Pantry.added = {}
Pantry._seen = 0


local function Base(prefab)
	local name = prefab
	for _ = 1, 2 do
		for _, suffix in ipairs(DERIVED) do
			if #name > #suffix and name:sub(-#suffix) == suffix then
				name = name:sub(1, #name - #suffix)
				break
			end
		end
	end
	return name
end


-- Food, as opposed to something the cook pot merely accepts.
local function IsFood(entry)
	local tags = entry ~= nil and entry.tags or nil
	if type(tags) ~= "table" then
		return false
	end

	for tag, value in pairs(tags) do
		if (tonumber(value) or 0) > 0 and not NOT_FOOD[tag] then
			return true
		end
	end

	return false
end


-- Their own lists win, always. A prefab they put in CHEST is in CHEST because
-- they meant it there -- twigs are a cook pot ingredient and still belong in a
-- chest -- and a prefab they DELETE or IGNORE is not ours to resurrect.
local function AlreadyPlaced(classify, prefab)
	return (classify.DELETE and classify.DELETE[prefab])
		or (classify.GROUND and classify.GROUND[prefab])
		or (classify.CHEST and classify.CHEST[prefab])
		or (classify.ICEBOX and classify.ICEBOX[prefab])
		or (classify.IGNORE and classify.IGNORE[prefab])
		or false
end


-- Everything the game knows how to cook with, put where the NPCs will carry it.
--
-- Returns how many were added and how many were passed over, so the caller can
-- say something useful the first time and nothing at all afterwards.
function Pantry.Stock(classify, cooking, blacklist)
	if type(classify) ~= "table" or type(classify.ICEBOX) ~= "table" then
		return 0, 0
	end

	local ingredients = type(cooking) == "table" and cooking.ingredients or nil
	if type(ingredients) ~= "table" then
		return 0, 0
	end

	blacklist = type(blacklist) == "table" and blacklist or {}

	local added, passed = 0, 0

	for prefab, entry in pairs(ingredients) do
		if type(prefab) == "string" then
			if AlreadyPlaced(classify, prefab)
				or blacklist[prefab]
				or blacklist[Base(prefab)]
				or not IsFood(entry) then
				passed = passed + 1
			else
				classify.ICEBOX[prefab] = true
				Pantry.added[prefab] = true
				added = added + 1
			end
		end
	end

	return added, passed
end


local function CountIngredients(cooking)
	local n = 0
	for _ in pairs(type(cooking) == "table" and cooking.ingredients or {}) do
		n = n + 1
	end
	return n
end


-- Mods register their ingredients while the game loads, and there is no saying
-- whether ours runs before or after theirs. So this is cheap and repeatable:
-- it counts what the game knows and only walks the table when that number has
-- moved.
function Pantry.Refresh()
	if not Core.cfg.enabled or not Core.cfg.stock_mod_food then
		return 0
	end

	local ok, cooking = pcall(require, "cooking")
	if not ok or type(cooking) ~= "table" then
		return 0
	end

	local n = CountIngredients(cooking)
	if n == Pantry._seen then
		return 0
	end
	Pantry._seen = n

	local classify = nil
	local got, mod = pcall(require, "npc/npc_item_classify")
	if got and type(mod) == "table" then
		classify = mod
	end
	if classify == nil then
		return 0
	end

	local tuning = nil
	local hit, tune = pcall(require, "npc_tuning")
	if hit and type(tune) == "table" then
		tuning = tune.COOK_INGREDIENT_BLACKLIST
	end

	local added = Pantry.Stock(classify, cooking, tuning)

	if added > 0 then
		Core.Log(string.format(
			"%d ingredient(s) the NPCs were walking past are now fridge-worthy", added))
	end

	return added
end


function Pantry.Reset()
	Pantry.added = {}
	Pantry._seen = 0
end


-- Run before each cooking plan. It costs one table count unless a mod has
-- registered something since, which after the world is up never happens.
function Pantry.Attach(planner)
	if planner == nil or planner._hofnpc_pantry_attached then
		return false
	end

	local plan = planner.PlanCooking
	if type(plan) ~= "function" then
		return false
	end

	planner.PlanCooking = function(...)
		pcall(Pantry.Refresh)
		return plan(...)
	end

	planner._hofnpc_pantry_attached = true
	return true
end


return Pantry
