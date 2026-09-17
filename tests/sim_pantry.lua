-- sim_pantry.lua
--
-- End to end, on the real files: an Eyerose lying on the ground, and whether it
-- ever becomes dinner.
--
--   lua5.1 tests/sim_pantry.lua <dst-scripts> <workshop-content-322330>
--
-- Nothing here is a stand-in for the thing being tested. It runs NPC Friends'
-- own npc/npc_item_classify.lua -- the real file, not a copy of its tables --
-- over Don't Starve Together's own cooking.lua with the player's food mods
-- loaded on top, and then asks the shipped chef what it would cook.
--
-- npc_item_classify.lua wants two things from npc_tuning: a debug flag and
-- IsNPCTool. Those are supplied; its cooking blacklist is read out of the real
-- npc_tuning.lua, which itself needs the game's globals to run.

local here = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = here .. "/?.lua;" .. here .. "/../npcfriends_hof_cooking/scripts/?.lua;" .. package.path

local DST = arg[1] or os.getenv("DSTSCRIPTS")
local WS  = arg[2] or os.getenv("DSTWORKSHOP")

local function bail(why)
	print("  SKIP  tests/sim_pantry.lua -- " .. why)
	os.exit(0)
end

if DST == nil or WS == nil then
	bail("pass <dst-scripts> <workshop-content-322330>")
end

-- lua5.1 has no utf8 library; this walks the bytes of UTF-8 well enough to
-- know which characters take two cells.
function utf8_codes_compat(text)
	local i = 1
	return function()
		if i > #text then return nil end
		local c = text:byte(i)
		local len = (c < 0x80 and 1) or (c < 0xE0 and 2) or (c < 0xF0 and 3) or 4
		local code = c
		if len == 2 then code = ((c - 0xC0) * 64) + (text:byte(i + 1) - 0x80)
		elseif len == 3 then code = ((c - 0xE0) * 4096) + ((text:byte(i + 1) - 0x80) * 64) + (text:byte(i + 2) - 0x80)
		elseif len == 4 then code = 0x10000 end
		local at = i
		i = i + len
		return at, code
	end
end

local Real = require("dst_real")
local cooking, err = Real.Load(DST)
if cooking == nil then
	bail(tostring(err))
end

local NPCFRIENDS = WS .. "/3684000581"
if io.open(NPCFRIENDS .. "/scripts/npc/npc_item_classify.lua", "r") == nil then
	bail("NPC Friends (3684000581) is not installed")
end

-- ═══════════════════════════════════════════════════════════════════════════
--  The player's food mods
-- ═══════════════════════════════════════════════════════════════════════════

-- Copied verbatim from tests/test_realmods.lua, which describes each mod
-- exactly as its own modmain.lua registers it.
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

local moddish = {}
for _, mod in ipairs(MODS) do
	mod.root = WS .. "/" .. mod.id
	if io.open(mod.root .. "/modinfo.lua", "r") ~= nil then
		local added = Real.AddMod(mod)
		if added then
			for name in pairs(added) do moddish[name] = mod.name end
		end
	end
end
package.loaded["cooking"] = cooking

-- ═══════════════════════════════════════════════════════════════════════════
--  NPC Friends' real classifier
-- ═══════════════════════════════════════════════════════════════════════════

local blacklist = {}
do
	local f = io.open(NPCFRIENDS .. "/scripts/npc_tuning.lua", "r")
	if f ~= nil then
		local text = f:read("*a")
		f:close()
		local body = text:match("COOK_INGREDIENT_BLACKLIST%s*=%s*{(.-)}")
		for name in (body or ""):gmatch("([%w_]+)%s*=%s*true") do
			blacklist[name] = true
		end
	end
end

package.loaded["npc_tuning"] =
{
	DEBUG_BEHAVIOR = false,
	DEBUG_COOKING  = false,
	IsNPCTool      = function() return false end,
	COOK_INGREDIENT_BLACKLIST = blacklist,
}

local old_path = package.path
package.path = NPCFRIENDS .. "/scripts/?.lua;" .. package.path
local ok, ItemClassify = pcall(require, "npc/npc_item_classify")
package.path = old_path

if not ok or type(ItemClassify) ~= "table" then
	bail("could not load their classifier: " .. tostring(ItemClassify))
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Things lying on the ground
-- ═══════════════════════════════════════════════════════════════════════════

-- Hangul is double width in a terminal, so padding by bytes lines nothing up.
local function Pad(text, width)
	local cells = 0
	for _, code in utf8_codes_compat(text) do
		cells = cells + ((code > 0x1100) and 2 or 1)
	end
	return text .. string.rep(" ", math.max(0, width - cells))
end


local function Item(prefab, tags)
	local have = {}
	for _, t in ipairs(tags or {}) do have[t] = true end
	return
	{
		prefab  = prefab,
		IsValid = function() return true end,
		HasTag  = function(_, tag) return have[tag] == true end,
		components = {},
	}
end

-- Tags taken from the mods' own prefab files: htf_veggies.lua gives its
-- vegetables cookable / deployedplant and an edible component, and nothing
-- else. No preparedfood, no icebox_valid.
local GROUND =
{
	{ Item("htf_eyerose",          { "cookable", "deployedplant", "deployedfarmplant" }), "눈알장미" },
	{ Item("htf_blackmushroom",    { "cookable", "weighable_OVERSIZEDVEGGIES" }),         "검은버섯" },
	{ Item("oceanfish_small_8_inv", { "fish", "weighable_OCEANFISH" }),                   "이글거리는 해복치" },
	{ Item("coffeebeans",          { "cookable" }),                                       "커피콩" },
	{ Item("carrot",               { "cookable" }),                                       "당근 (바닐라, 원래 되던 것)" },
	{ Item("meatballs",            { "preparedfood" }),                                   "미트볼 (완성 요리)" },
	{ Item("twigs",                {}),                                                   "나뭇가지 (상자 행이어야 함)" },
	{ Item("rot",                  {}),                                                   "부패물 (지워져야 함)" },
	{ Item("mandrake",             { "cookable" }),                                       "맨드레이크 (그들이 상자로 정함)" },
}

local chef = { GUID = 1, components = {} }

print("═══ 1. 바닥에 떨어진 것들을 NPC 가 어떻게 보는가 ═══")
print("")
print("   " .. Pad("프리팹", 24) .. Pad("이름", 34) .. Pad("패치 전", 12) .. "패치 후")

local STOCK =
{
	htf_eyerose = 10, htf_blackmushroom = 10, coffeebeans = 8, coffee_ground = 6,
	coffee_filter = 6, oceanfish_small_8_inv = 6, berries = 20, carrot = 20,
	meat = 10, smallmeat = 10, twigs = 10, ice = 20, bird_egg = 6, honey = 8,
}

local before = {}
for _, row in ipairs(GROUND) do
	before[row[1].prefab] = ItemClassify.GetCategory(row[1], chef)
end
for prefab in pairs(STOCK) do
	before[prefab] = before[prefab] or ItemClassify.GetCategory(Item(prefab, {}), chef)
end

-- the patch
local Core   = require("hofnpc_core")
Core.Configure({ enabled = true, stock_mod_food = true, debug = false })
local Pantry = require("hofnpc_pantry")
local added  = Pantry.Stock(ItemClassify, cooking, blacklist)

local changed, kept = 0, 0
for _, row in ipairs(GROUND) do
	local item, label = row[1], row[2]
	local now = ItemClassify.GetCategory(item, chef)
	local was = before[item.prefab]
	if now ~= was then changed = changed + 1 else kept = kept + 1 end
	print("   " .. Pad(item.prefab, 24) .. Pad(label, 34) .. Pad(was, 12) .. now
		.. (now ~= was and "   <- 바뀜" or ""))
end

print("")
print(string.format("   재료 %d개가 새로 냉장고행이 되었습니다. 표시된 %d개 중 %d개가 바뀌고 %d개는 그대로입니다.",
	added, #GROUND, changed, kept))

-- ═══════════════════════════════════════════════════════════════════════════
--  Now the chef
-- ═══════════════════════════════════════════════════════════════════════════

print("")
print("═══ 2. 냉장고에 들어간 재료로 셰프가 무엇을 만드는가 ═══")

local Search  = require("hofnpc_search")
local Variety = require("hofnpc_variety")
local COOKER  = "portablecookpot"

-- Only what an NPC would actually have carried in: every prefab goes through
-- their classifier, and only what it sends to the ice box is in the fridge.
local function Fridge(verdict)
	local pool, left_out = {}, {}
	for prefab, count in pairs(STOCK) do
		if verdict(prefab) == "icebox" then
			pool[prefab] = { total = count,
				locations = { { container = { GUID = 2 }, slot = 1, count = count } } }
		else
			left_out[#left_out + 1] = prefab
		end
	end
	table.sort(left_out)
	return pool, left_out
end

local was_pool, was_out = Fridge(function(p) return before[p] end)
local fridge, rejected  = Fridge(function(p) return ItemClassify.GetCategory(Item(p, {}), chef) end)

print("   패치 전 냉장고에 못 들어가던 것: " .. table.concat(was_out, ", "))
print("   패치 후 못 들어가는 것:          " .. table.concat(rejected, ", "))

local function Cook(pool, passes)
	math.randomseed(20260917)
	Search.ResetCache(); Search.ResetInterests(); Variety.Reset(); Core.ClearScoreCache()
	Core.Configure({ enabled = true, stock_mod_food = true, debug = false,
		variety = "medium", budget = "medium", allow_negative = true, taste_everything = true })
	Core.SetHost({})

	local existing, made, uses = {}, {}, {}
	for _ = 1, passes do
		local chosen = Search.Choose(pool, existing, true, COOKER)
		if chosen == nil then break end
		made[#made + 1] = chosen.name
		existing[chosen.name] = (existing[chosen.name] or 0) + 1
		Variety.Record(chosen.name)
		for _, prefab in ipairs(chosen.ingredients or chosen._selected_ingredients or {}) do
			local name = type(prefab) == "table" and prefab.prefab or prefab
			uses[name] = (uses[name] or 0) + 1
		end
	end
	return made, uses
end

local was_made = Cook(was_pool, 40)
local made, uses = Cook(fridge, 40)

print("")
print("   40번 요리한 결과 (* = 모드 요리):")
local line = {}
for i, name in ipairs(made) do
	line[#line + 1] = (moddish[name] and "*" or "") .. name
	if i % 4 == 0 or i == #made then
		print("      " .. table.concat(line, ", "))
		line = {}
	end
end

local function Tally(list)
	local seen, distinct, mods = {}, 0, 0
	for _, name in ipairs(list) do
		if not seen[name] then seen[name] = true; distinct = distinct + 1 end
		if moddish[name] then mods = mods + 1 end
	end
	return distinct, mods
end

local was_distinct, was_mods = Tally(was_made)
local distinct, modcount     = Tally(made)

print("")
print(string.format("   패치 전: 서로 다른 요리 %d가지, 모드 요리 %d번", was_distinct, was_mods))
print(string.format("   패치 후: 서로 다른 요리 %d가지, 모드 요리 %d번", distinct, modcount))

print("")
print("   패치로 들어가게 된 재료가 실제로 쓰였는가:")
for _, prefab in ipairs({ "htf_eyerose", "htf_blackmushroom", "oceanfish_small_8_inv",
	"coffeebeans", "coffee_ground", "coffee_filter" }) do
	print("      " .. Pad(prefab, 26)
		.. (uses[prefab] and (tostring(uses[prefab]) .. "번 냄비에 들어감") or "한 번도 안 쓰임"))
end

print("")
