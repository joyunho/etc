-- test_pantry.lua
--
-- Whether a modded ingredient ever reaches a container the chef can see.
--
--   lua5.1 tests/test_pantry.lua
--
-- NPC Friends decides what every NPC picks up and where it puts it in one
-- place, npc/npc_item_classify.lua, and that place is a whitelist of prefab
-- names plus two tags. A modded vegetable matches none of it, so both Warly
-- and Wormwood walked past Heap of Foods' Eyerose and Black Mushroom. The
-- shapes below are that file's, and the rule under test is: food the game
-- knows how to cook with goes in the fridge, their own lists always win.

local here = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = here .. "/?.lua;" .. here .. "/../npcfriends_hof_cooking/scripts/?.lua;" .. package.path

local Stub = require("dst_stub")
Stub.Register()

local Core   = require("hofnpc_core")
local Pantry = require("hofnpc_pantry")

local failures = 0
local function check(label, ok, detail)
	if ok then
		print("  PASS  " .. label)
	else
		failures = failures + 1
		print("  FAIL  " .. label .. (detail and ("  -- " .. detail) or ""))
	end
end

-- npc_item_classify.lua exports these five by reference, with the comment that
-- they exist to be extended at runtime.
local function Classify()
	return {
		DELETE = { rot = true },
		GROUND = { seeds = true },
		CHEST  = { twigs = true },              -- a cook pot ingredient that is not food
		ICEBOX = { carrot = true, meat = true },
		IGNORE = { heatrock = true },
	}
end

local function Cooking()
	return {
		ingredients =
		{
			-- theirs, already placed
			carrot       = { tags = { veggie = 1 } },
			meat         = { tags = { meat = 1 } },
			twigs        = { tags = { inedible = 1 } },
			rot          = { tags = { veggie = 0.5 } },
			seeds        = { tags = { seed = 1 } },
			heatrock     = { tags = { inedible = 1 } },

			-- the two the player asked about, and their cooked forms
			htf_eyerose         = { tags = { veggie = 1 } },
			htf_eyerose_cooked  = { tags = { veggie = 1, precook = 1 } },
			htf_blackmushroom   = { tags = { veggie = 1 } },

			-- vanilla food the list simply never mentioned
			oceanfish_small_8_inv = { tags = { fish = 0.5, meat = 0.5 } },
			tallbirdegg           = { tags = { egg = 4 } },
			pondeel               = { tags = { fish = 1, meat = 0.5 } },

			-- the coffee mod
			coffeebeans  = { tags = { veggie = 1 } },
			coffee_ground = { tags = { coffee = 3 } },

			-- cooking ingredients that are not food
			forgetmelots = { tags = { decoration = 1 } },
			refined_dust = { tags = { decoration = 2 } },

			-- deliberately left alone by NPC Friends, and its cooked form
			mandrake        = { tags = { veggie = 1, magic = 1 } },
			mandrake_cooked = { tags = { veggie = 1, magic = 1, precook = 1 } },
			royal_jelly     = { tags = { sweetener = 3 } },
		},
	}
end

local BLACKLIST = { mandrake = true, royal_jelly = true, rot = true }

Core.Configure({ enabled = true, stock_mod_food = true, debug = false })

print("=== 1. the food the NPCs were walking past ===")

local classify, cooking = Classify(), Cooking()
local added = Pantry.Stock(classify, cooking, BLACKLIST)

check("the Eyerose is now fridge-worthy", classify.ICEBOX.htf_eyerose == true)
check("so is the Black Mushroom", classify.ICEBOX.htf_blackmushroom == true)
check("and the cooked Eyerose", classify.ICEBOX.htf_eyerose_cooked == true)
check("ocean fish too", classify.ICEBOX.oceanfish_small_8_inv == true)
check("and tallbird eggs, and eel",
	classify.ICEBOX.tallbirdegg == true and classify.ICEBOX.pondeel == true)
check("and the coffee mod's ingredients",
	classify.ICEBOX.coffeebeans == true and classify.ICEBOX.coffee_ground == true)
check("it says how many it placed", added == 8, tostring(added))

print("")
print("=== 2. their own lists always win ===")

check("twigs stay in the chest",
	classify.CHEST.twigs == true and classify.ICEBOX.twigs == nil)
check("rot stays deleted",
	classify.DELETE.rot == true and classify.ICEBOX.rot == nil)
check("seeds stay on the ground",
	classify.GROUND.seeds == true and classify.ICEBOX.seeds == nil)
check("an explicit ignore is not overruled",
	classify.IGNORE.heatrock == true and classify.ICEBOX.heatrock == nil)
check("what was already in the fridge is untouched",
	classify.ICEBOX.carrot == true and classify.ICEBOX.meat == true)

print("")
print("=== 3. a cooking ingredient is not always food ===")

check("forget-me-lots are a decoration, not a meal", classify.ICEBOX.forgetmelots == nil)
check("nor is refined dust", classify.ICEBOX.refined_dust == nil)

print("")
print("=== 4. what they left out on purpose stays out ===")

check("the mandrake they excluded is still excluded", classify.ICEBOX.mandrake == nil)
check("and so is the cooked mandrake, which is the same plant",
	classify.ICEBOX.mandrake_cooked == nil)
check("royal jelly is left for the jellybeans", classify.ICEBOX.royal_jelly == nil)

print("")
print("=== 5. it is safe to run again, and to run on nothing ===")

local again = Pantry.Stock(classify, cooking, BLACKLIST)
check("a second pass adds nothing", again == 0, tostring(again))
check("no classifier at all is survived", Pantry.Stock(nil, cooking, BLACKLIST) == 0)
check("no cooking table at all is survived", Pantry.Stock(Classify(), nil, BLACKLIST) == 0)
check("a classifier with no ICEBOX is survived",
	Pantry.Stock({ ICEBOX = nil }, cooking, BLACKLIST) == 0)
check("no blacklist is survived", select(1, Pantry.Stock(Classify(), Cooking(), nil)) > 0)

print("")
print("=== 6. switching it off, and running late ===")

do
	Core.Configure({ enabled = true, stock_mod_food = false, debug = false })
	Pantry.Reset()

	local late = Classify()
	package.loaded["cooking"] = Cooking()
	package.loaded["npc/npc_item_classify"] = late
	package.loaded["npc_tuning"] = { COOK_INGREDIENT_BLACKLIST = BLACKLIST }

	check("off means nothing moves", Pantry.Refresh() == 0)
	check("and the fridge list is untouched", late.ICEBOX.htf_eyerose == nil)

	Core.Configure({ enabled = true, stock_mod_food = true, debug = false })
	check("on means it fills in", Pantry.Refresh() == 8)
	check("the Eyerose made it", late.ICEBOX.htf_eyerose == true)

	-- a mod that registers its ingredients after we first looked
	check("nothing new means no second walk", Pantry.Refresh() == 0)
	package.loaded["cooking"].ingredients.latemod_turnip = { tags = { veggie = 1 } }
	check("a late mod is picked up on the next plan", Pantry.Refresh() == 1)
	check("and its turnip is fridge-worthy", late.ICEBOX.latemod_turnip == true)

	package.loaded["cooking"] = nil
	package.loaded["npc/npc_item_classify"] = nil
	package.loaded["npc_tuning"] = nil
end

print("")
if failures == 0 then
	print("ALL CHECKS PASSED")
	os.exit(0)
else
	print(failures .. " CHECK(S) FAILED")
	os.exit(1)
end
