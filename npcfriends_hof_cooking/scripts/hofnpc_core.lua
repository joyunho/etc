-- hofnpc_core.lua
-- Shared config, logging and scoring helpers for the
-- "NPC Friends x Heap of Foods" cooking compatibility patch.
--
-- This file is loaded through the game's own require(), so it sees the plain
-- game globals (no GLOBAL. prefix here -- that is only needed in modmain.lua).

local cooking = require("cooking")

local Core = {}

Core.PREFIX = "[NPCF-HOF]"

-- ═══════════════════════════════════════════════════════════════════════════
--  Configuration (overwritten from modmain.lua via Core.Configure)
-- ═══════════════════════════════════════════════════════════════════════════

Core.cfg =
{
	enabled        = true,
	variety        = "medium",  -- off | low | medium | high
	budget         = "medium",  -- low | medium | high
	same_dish_max  = nil,       -- nil -> follow NPC Friends' COOK_SAME_DISH_MAX
	allow_negative = false,     -- allow dishes with negative health/sanity
	explain        = true,      -- say in the log why the chef gave up
	debug          = false,
	protect        = {},        -- [prefab] = true, never spent as an ingredient
	spread_cookware = true,     -- skip stations too small to cook in, rotate the rest
	use_cookware   = true,      -- cook in Heap of Foods' own grills, ovens and pot hangers
	taste_everything = true,    -- make one of each before making a second of anything
	use_spicer      = true,     -- also use Warly's Portable Seasoning Station
	use_dryer       = true,     -- also hang meat and mushrooms on drying racks
	use_brewer      = true,     -- also fill Heap of Foods' kegs and jars
	use_milker      = true,     -- also milk beefalo, koalefant and lightning goats
}

-- Variety weights. The dish the NPC picks is chosen by
--   score = food_value - repeat_penalty*already_stored - recency_penalty + novelty + jitter
-- so raising these makes the NPC rotate through the cookbook instead of
-- cooking the single highest-value dish forever.
Core.VARIETY_PRESETS =
{
	off    = { repeat_penalty = 0,  recency_penalty = 0,  novelty_bonus = 0,  jitter = 0  },
	low    = { repeat_penalty = 6,  recency_penalty = 12, novelty_bonus = 8,  jitter = 3  },
	medium = { repeat_penalty = 14, recency_penalty = 28, novelty_bonus = 20, jitter = 8  },
	high   = { repeat_penalty = 28, recency_penalty = 60, novelty_bonus = 45, jitter = 16 },
}

-- Search budgets. max_evals bounds how many combinations a single planning
-- pass may try, so a pantry full of Heap of Foods ingredients can never stall
-- the server. refresh_evals is the cheaper top-up used when the candidate
-- cache is already warm.
--
-- These numbers are lower than they were before the recipe-directed pass
-- existed, and the search still finds more: asking a dish what it needs costs
-- a few dozen combinations, guessing at it costs thousands. Measured against
-- a 30-type pantry with three food mods installed, the medium preset went from
-- 14 mod dishes found for 22 ms of first-pass work to 31 found for 12 ms.
-- targeted_evals and targeted_dishes bound the recipe-directed pass (path 3),
-- which is the one that finds a food mod's dishes. Both are spent only on
-- dishes nobody has worked out yet, and the cursor carries over between
-- passes, so a cold pantry is covered across a handful of passes rather than
-- in one long tick, and a warm one spends almost none of it.
--
-- targeted_dishes is the one that keeps the cost flat: without it a pass over
-- a 250-dish cookbook costs four times what the same pass costs over a 70-dish
-- one, because cheap dishes are solved in a few combinations each and the eval
-- budget stretches across dozens of them -- each still paying to read its
-- requirements. Capping the dishes per pass makes a pass cost the same whether
-- the player has one food mod installed or six.
Core.BUDGET_PRESETS =
{
	low    = { max_types = 10, max_evals = 100, refresh_evals = 60, max_candidates = 24, targeted_evals = 600,  targeted_dishes = 12 },
	medium = { max_types = 13, max_evals = 150, refresh_evals = 100, max_candidates = 40, targeted_evals = 1200, targeted_dishes = 24 },
	high   = { max_types = 16, max_evals = 250, refresh_evals = 160, max_candidates = 64, targeted_evals = 2400, targeted_dishes = 40 },
}

function Core.Configure(cfg)
	for k, v in pairs(cfg or {}) do
		Core.cfg[k] = v
	end
end

function Core.Variety()
	return Core.VARIETY_PRESETS[Core.cfg.variety] or Core.VARIETY_PRESETS.medium
end

function Core.Budget()
	return Core.BUDGET_PRESETS[Core.cfg.budget] or Core.BUDGET_PRESETS.medium
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Host mod references (filled in by hofnpc_patch once NPC Friends has loaded)
-- ═══════════════════════════════════════════════════════════════════════════

Core.host =
{
	tuning  = nil,  -- npc_tuning
	recipes = nil,  -- npc/npc_cooking_recipes
	planner = nil,  -- npc/npc_cooking_planner
}

function Core.SetHost(host)
	for k, v in pairs(host or {}) do
		Core.host[k] = v
	end
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Logging
-- ═══════════════════════════════════════════════════════════════════════════

function Core.Log(...)
	if Core.cfg.debug then
		print(Core.PREFIX, ...)
	end
end

function Core.Info(...)
	print(Core.PREFIX, ...)
end

function Core.Err(...)
	print(Core.PREFIX, "[ERROR]", ...)
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Dish value
-- ═══════════════════════════════════════════════════════════════════════════

-- NPC Friends rates its hand written recipe cards with
--   score = health * 1.0 + hunger * 0.4 + sanity * 0.8
-- We reuse the same formula, but read the numbers straight off the live recipe
-- table, so a Heap of Foods dish is rated on exactly the same scale as a
-- vanilla one without anybody hand-writing a card for it.
local _score_cache = {}

function Core.GetRecipe(cooker_name, product)
	local byCooker = cooking.recipes and cooking.recipes[cooker_name]
	return byCooker and byCooker[product] or nil
end

function Core.BaseScore(cooker_name, product)
	local key = cooker_name .. "/" .. product
	local cached = _score_cache[key]
	if cached ~= nil then
		return cached
	end

	local recipe = Core.GetRecipe(cooker_name, product)
	local score = 0

	if recipe ~= nil then
		score = (recipe.health or 0) * 1.0
			+ (recipe.hunger or 0) * 0.4
			+ (recipe.sanity or 0) * 0.8
	end

	_score_cache[key] = score
	return score
end

function Core.ClearScoreCache()
	_score_cache = {}
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Dish filtering
-- ═══════════════════════════════════════════════════════════════════════════

-- A dish the NPC must never plan: the failure dish, anything NPC Friends
-- already blacklists, and (unless the player opts in) anything that costs the
-- eater health or sanity.
function Core.IsDishAllowed(cooker_name, product)
	if product == nil or product == "wetgoop" then
		return false
	end

	local recipes = Core.host.recipes
	if recipes ~= nil and type(recipes.IsExcluded) == "function" then
		local ok, excluded = pcall(recipes.IsExcluded, product)
		if ok and excluded then
			return false
		end
	end

	local tuning = Core.host.tuning
	if tuning ~= nil and tuning.COOK_RECIPE_BLACKLIST ~= nil
		and tuning.COOK_RECIPE_BLACKLIST[product] then
		return false
	end

	if not Core.cfg.allow_negative then
		local recipe = Core.GetRecipe(cooker_name, product)
		if recipe ~= nil then
			if (recipe.health or 0) < 0 or (recipe.sanity or 0) < 0 then
				return false
			end
		end
	end

	return true
end

-- The panel's "음식 최대 개수" button. NPC Friends stops cooking altogether once
-- this many dishes are stored; 0 means no limit. We replace the function that
-- enforced it, so we have to enforce it ourselves or the button goes dead.
function Core.TotalDishMax()
	local tuning = Core.host.tuning
	if tuning ~= nil and type(tuning.COOK_MAX_TOTAL) == "number" and tuning.COOK_MAX_TOTAL > 0 then
		return tuning.COOK_MAX_TOTAL
	end
	return nil
end

function Core.SameDishMax()
	if Core.cfg.same_dish_max ~= nil and Core.cfg.same_dish_max > 0 then
		return Core.cfg.same_dish_max
	end

	local tuning = Core.host.tuning
	if tuning ~= nil and tuning.COOK_SAME_DISH_MAX ~= nil then
		return tuning.COOK_SAME_DISH_MAX
	end

	return 3
end

return Core
