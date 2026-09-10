-- hofnpc_search.lua
-- The replacement for NPC Friends' CookingPlanner.FindBestRecipe.
--
-- NPC Friends decides what to cook by walking a hand written table of recipe
-- cards (scripts/npc/npc_cooking_recipes.lua). That table only lists vanilla
-- dishes plus a few manually added mod dishes, so the ~250 Crock Pot dishes
-- from Heap of Foods are invisible to the chef no matter how full the pantry
-- is.
--
-- Instead of hand writing 250 more cards, this module never names a dish at
-- all. It works out what the ingredients in reach could become by asking the
-- game's own recipe tables, so whatever any food mod registered through the
-- normal AddCookerRecipe/AddIngredientValues API is discovered for free.
--
-- Two ways in, in this order:
--
--   1. card_def. A recipe may carry
--        card_def = { ingredients = { {"honey", 1}, {"berries", 3} } }
--      which is the exact pot contents, machine readable. Every one of Heap of
--      Foods' 248 Crock Pot dishes has one (247 of them fill all four slots),
--      as do a few dozen vanilla dishes. Reading those is exact and costs one
--      table walk, so it is the primary path.
--
--   2. Combination search, for dishes with no card. Bounded by a budget so a
--      large pantry can never stall the server.
--
-- Both paths confirm a candidate the same way: by re-running the game's own
-- recipe `test` functions and keeping the top-priority tier, exactly as
-- cooking.lua's GetCandidateRecipes does.
--
-- What we deliberately do NOT use is cooking.CalculateRecipe. It ends in
--     local val = math.random() * total
-- to break ties between equal-priority recipes, so it is both non-repeatable
-- (the same four ingredients can answer differently twice) and a source of
-- world RNG churn -- unacceptable when called hundreds of times per planning
-- pass. Everything below is deterministic and touches no RNG except the small
-- deliberate jitter in the variety score.

local cooking  = require("cooking")

local Core     = require("hofnpc_core")
local Variety  = require("hofnpc_variety")

local Search = {}

local POT_SLOTS = 4

-- cooking.lua maps these three legacy names onto the real prefabs before
-- looking up ingredient values.
local PREFAB_ALIASES =
{
	cookedsmallmeat   = "smallmeat_cooked",
	cookedmonstermeat = "monstermeat_cooked",
	cookedmeat        = "meat_cooked",
}

-- Discovered combinations, keyed by cooker AND pantry:
--   _cache[cooker .. "|" .. signature] = { count = N, rotate = N,
--       map = { [product] = { combo, cost, cooktime, exclusive } } }
--
-- The signature is the set of ingredient types in reach. Keying on the cooker
-- alone looks tempting -- NPC Friends passes "portablecookpot" for every chef --
-- but the pantry is per NPC (each scans around its own cooking centre), so two
-- chefs at two bases would evict each other's entry on every pass and neither
-- would ever run warm.
Search._cache = {}

function Search.ResetCache()
	Search._cache = {}
end

-- ═══════════════════════════════════════════════════════════════════════════
--  The oracle: what would these four ingredients cook into?
-- ═══════════════════════════════════════════════════════════════════════════

-- Same aggregation cooking.lua's (file-local, unexported) GetIngredientValues
-- does: prefab -> count, and tag -> summed value. Tag values are fractional --
-- berries contribute fruit = 0.5 -- and a missing tag is nil, not zero.
local function IngredientValues(names)
	local tags, counts = {}, {}

	for _, raw in ipairs(names) do
		local prefab = PREFAB_ALIASES[raw] or raw
		counts[prefab] = (counts[prefab] or 0) + 1

		local data = cooking.ingredients[prefab]
		if data ~= nil and data.tags ~= nil then
			for tag, value in pairs(data.tags) do
				tags[tag] = (tags[tag] or 0) + value
			end
		end
	end

	return counts, tags
end

-- Every recipe whose test passes, narrowed to the highest priority tier --
-- which is a hard cut in cooking.lua, not a preference. The pot then picks
-- among that tier by weight, so a single survivor means a guaranteed dish.
local function TopCandidates(cooker_name, names)
	local recipes = cooking.recipes[cooker_name]
	if recipes == nil then
		return nil
	end

	local counts, tags = IngredientValues(names)

	local winners, best = nil, nil

	for name, recipe in pairs(recipes) do
		if type(recipe.test) == "function" then
			local ok, passes = pcall(recipe.test, cooker_name, counts, tags)
			if ok and passes then
				local priority = recipe.priority or 0

				if best == nil or priority > best then
					best    = priority
					winners = { name }
				elseif priority == best then
					winners[#winners + 1] = name
				end
			end
		end
	end

	return winners
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Ingredient pool
-- ═══════════════════════════════════════════════════════════════════════════

-- pool comes from NPC Friends' CookingPlanner.ScanIngredients and is shaped
--   pool[prefab] = { total = N, locations = { {container=, slot=, count=}, ... } }
-- Everything in it already passed cooking.IsCookingIngredient(), which is why
-- Heap of Foods ingredients are picked up correctly today -- it is only the
-- dish side that was broken.
local function BuildTypes(pool)
	local types, avail, names = {}, {}, {}
	local protect = Core.cfg.protect or {}

	for prefab, data in pairs(pool) do
		if not protect[prefab] and data.total and data.total > 0 then
			-- A pot never takes more than 4 of anything.
			local n = math.min(data.total, POT_SLOTS)
			types[#types + 1] = { prefab = prefab, avail = n, used = 0 }
			avail[prefab] = n
			names[#names + 1] = prefab
		end
	end

	table.sort(names)

	return types, avail, table.concat(names, ",")
end

local function Shuffle(t)
	for i = #t, 2, -1 do
		local j = math.random(i)
		t[i], t[j] = t[j], t[i]
	end
end

-- Trim the ingredient list down to something we can search exhaustively.
-- Plentiful ingredients come first (spending those wastes nothing), then a
-- random sample of the rest, so successive passes look at different corners of
-- the pantry.
-- `rotate` shifts the starting point every pass. Without it a warm pass walks
-- the same combinations in the same order and finds nothing new, however much
-- budget it is given.
local function Rotate(list, offset)
	local n = #list
	if n < 2 or offset % n == 0 then
		return list
	end

	local out = {}
	for i = 1, n do
		out[i] = list[((i - 1 + offset) % n) + 1]
	end
	return out
end

local function SelectTypes(types, max_types, rotate)
	if #types <= max_types then
		return Rotate(types, rotate)
	end

	table.sort(types, function(a, b)
		if a.avail ~= b.avail then
			return a.avail > b.avail
		end
		return a.prefab < b.prefab
	end)

	local head, kept = math.min(#types, math.ceil(max_types * 0.6)), {}
	for i = 1, head do
		kept[#kept + 1] = types[i]
	end

	local tail = {}
	for i = head + 1, #types do
		tail[#tail + 1] = types[i]
	end
	Shuffle(tail)

	for i = 1, math.min(#tail, max_types - head) do
		kept[#kept + 1] = tail[i]
	end

	return Rotate(kept, rotate)
end

local function ComboCost(combo, avail)
	local cost = 0
	for _, prefab in ipairs(combo) do
		cost = cost + 1 / (avail[prefab] or 1)
	end
	return cost
end

-- Record a combination under the dish it makes, keeping the cheapest one and
-- preferring a combination that can only make that dish.
local function Record(entry, product, combo, avail, cooktime, exclusive)
	local current = entry.map[product]
	local cost    = ComboCost(combo, avail)

	if current == nil then
		entry.count = entry.count + 1
		entry.map[product] =
		{
			combo     = { combo[1], combo[2], combo[3], combo[4] },
			cost      = cost,
			cooktime  = cooktime,
			exclusive = exclusive,
		}
		return
	end

	-- A guaranteed outcome beats a cheaper gamble.
	local better = (exclusive and not current.exclusive)
		or (exclusive == current.exclusive and cost < current.cost)

	if better then
		current.combo     = { combo[1], combo[2], combo[3], combo[4] }
		current.cost      = cost
		current.cooktime  = cooktime
		current.exclusive = exclusive
	end
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Path 1 -- recipes that state their own ingredients
-- ═══════════════════════════════════════════════════════════════════════════

-- Turns { {"honey",1}, {"berries",3} } into {"honey","berries","berries","berries"}
-- if and only if the pantry can cover it.
local function ComboFromCard(card, pool)
	local combo = {}

	for _, pair in ipairs(card.ingredients or {}) do
		local prefab, count = pair[1], pair[2] or 1

		if type(prefab) ~= "string" or count < 1 then
			return nil
		end

		local data = pool[prefab]
		if data == nil or (data.total or 0) < count then
			return nil
		end

		for _ = 1, count do
			combo[#combo + 1] = prefab
			if #combo > POT_SLOTS then
				return nil
			end
		end
	end

	if #combo == 0 then
		return nil
	end

	return combo
end

-- Almost every card fills all four slots. The rare short one needs padding,
-- and the padding must not change what comes out, so each candidate filler is
-- confirmed before it is accepted.
local function PadCombo(combo, product, cooker_name, types)
	local tries = 0

	while #combo < POT_SLOTS do
		local padded = false

		for _, t in ipairs(types) do
			if tries >= 24 then
				return nil
			end
			tries = tries + 1

			combo[#combo + 1] = t.prefab

			local winners = TopCandidates(cooker_name, combo)
			local hit = false
			for _, name in ipairs(winners or {}) do
				if name == product then hit = true break end
			end

			if hit then
				padded = true
				break
			end

			table.remove(combo)
		end

		if not padded then
			return nil
		end
	end

	return combo
end

local function DiscoverFromCards(pool, avail, types, cooker_name, entry)
	local recipes = cooking.recipes[cooker_name]
	if recipes == nil then
		return 0
	end

	local found = 0

	for product, recipe in pairs(recipes) do
		local card = recipe.card_def

		if type(card) == "table" and type(card.ingredients) == "table" then
			local combo = ComboFromCard(card, pool)

			if combo ~= nil and #combo < POT_SLOTS then
				combo = PadCombo(combo, product, cooker_name, types)
			end

			if combo ~= nil and #combo == POT_SLOTS then
				-- Confirm against the game's own tests: a card can be stale, or
				-- another mod may have changed the recipe out from under it.
				local winners = TopCandidates(cooker_name, combo)
				local hit = false

				for _, name in ipairs(winners or {}) do
					if name == product then hit = true break end
				end

				if hit then
					found = found + 1
					Record(entry, product, combo, avail, recipe.cooktime or 1, #winners == 1)
				end
			end
		end
	end

	return found
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Path 2 -- bounded search, for dishes that state nothing
-- ═══════════════════════════════════════════════════════════════════════════

local function DiscoverFromSearch(types, avail, cooker_name, max_evals, max_new, entry)
	local n = #types
	if n == 0 then
		return 0
	end

	for i = 1, n do
		types[i].used = 0
	end

	local recipes = cooking.recipes[cooker_name]
	local names, evals, added = {}, 0, 0

	-- The stop condition counts what THIS search added, not the total, so a
	-- pantry whose dishes were all found from cards does not silently disable
	-- the search for the dishes that carry no card.
	local function Exhausted()
		return evals >= max_evals or added >= max_new
	end

	local function Evaluate()
		evals = evals + 1

		local winners = TopCandidates(cooker_name, names)
		if winners == nil or #winners == 0 then
			return
		end

		local exclusive = #winners == 1

		for _, product in ipairs(winners) do
			if entry.map[product] == nil then
				added = added + 1
			end
			local recipe = recipes[product]
			Record(entry, product, names, avail, recipe and recipe.cooktime or 1, exclusive)
		end
	end

	local function Recurse(start, depth)
		if Exhausted() then
			return
		end

		if depth > POT_SLOTS then
			Evaluate()
			return
		end

		for i = start, n do
			local t = types[i]
			if t.used < t.avail then
				t.used = t.used + 1
				names[depth] = t.prefab

				Recurse(i, depth + 1)

				t.used = t.used - 1

				if Exhausted() then
					return
				end
			end
		end
	end

	Recurse(1, 1)

	return evals
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Turning a combination back into concrete container slots
-- ═══════════════════════════════════════════════════════════════════════════

local function CountCombo(combo)
	local needs = {}
	for _, prefab in ipairs(combo) do
		needs[prefab] = (needs[prefab] or 0) + 1
	end
	return needs
end

local function IsAffordable(combo, pool)
	for prefab, need in pairs(CountCombo(combo)) do
		local data = pool[prefab]
		if data == nil or (data.total or 0) < need then
			return false
		end
	end
	return true
end

-- Produces the exact shape NPC Friends' PlanCooking expects:
--   { { container = <ent>, slot = <n>, prefab = <name>, take_count = <n> }, ... }
local function Allocate(combo, pool)
	local selected = {}

	for prefab, need in pairs(CountCombo(combo)) do
		local data = pool[prefab]
		if data == nil or data.locations == nil then
			return nil
		end

		local remaining = need

		for _, loc in ipairs(data.locations) do
			if remaining <= 0 then
				break
			end

			local take = math.min(remaining, loc.count or 0)
			if take > 0 then
				selected[#selected + 1] =
				{
					container  = loc.container,
					slot       = loc.slot,
					prefab     = prefab,
					take_count = take,
				}
				remaining = remaining - take
			end
		end

		if remaining > 0 then
			return nil
		end
	end

	if #selected == 0 then
		return nil
	end

	return selected
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Entry point -- drop-in replacement for CookingPlanner.FindBestRecipe
-- ═══════════════════════════════════════════════════════════════════════════

-- Returns a recipe card table (name / score / cooktime / _selected_ingredients)
-- or nil to let the caller fall back to NPC Friends' original logic.
function Search.Choose(pool, existing_dishes, is_warly, cooker_name)
	if pool == nil or cooker_name == nil then
		return nil
	end

	existing_dishes = existing_dishes or {}

	-- The panel's "음식 최대 개수": stop entirely once the larder is that full.
	local total_max = Core.TotalDishMax()
	if total_max ~= nil then
		local stored = 0
		for _, n in pairs(existing_dishes) do
			stored = stored + n
		end
		if stored >= total_max then
			Core.Log(string.format("larder full: %d/%d dishes stored", stored, total_max))
			return nil
		end
	end

	if cooking.recipes == nil or cooking.recipes[cooker_name] == nil then
		Core.Log("no recipe table for cooker", cooker_name)
		return nil
	end

	local types, avail, signature = BuildTypes(pool)
	if #types == 0 then
		return nil
	end

	local budget = Core.Budget()

	local key   = cooker_name .. "|" .. signature
	local entry = Search._cache[key]

	if entry == nil then
		entry = { count = 0, rotate = 0, map = {}, carded = false }
		Search._cache[key] = entry
	end

	-- The card pass is exact and cheap, so it runs once per pantry change and
	-- covers every Heap of Foods dish on its own.
	local carded = 0
	if not entry.carded then
		carded = DiscoverFromCards(pool, avail, types, cooker_name, entry)
		entry.carded = true
	end

	-- The search only has to cover dishes that state no ingredients. A cold
	-- pantry pays the full budget once; later passes just top the list up. And
	-- when the cards already produced plenty to choose from -- which is the
	-- normal case with Heap of Foods installed -- the search runs short, since
	-- it would only be adding a few more vanilla dishes to an ample menu.
	local warm     = entry.count > 0 and carded == 0
	local max_eval = warm and budget.refresh_evals or budget.max_evals

	if carded >= 12 then
		max_eval = math.min(max_eval, budget.refresh_evals)
	end

	entry.rotate   = (entry.rotate or 0) + 1
	local searched = SelectTypes(types, budget.max_types, entry.rotate)
	local evals    = DiscoverFromSearch(searched, avail, cooker_name, max_eval,
		budget.max_candidates, entry)

	Core.Log(string.format(
		"cooker=%s types=%d from_cards=%d searched=%d evals=%d candidates=%d",
		cooker_name, #types, carded, #searched, evals, entry.count))

	-- ── Pick a dish ────────────────────────────────────────────────────────
	local same_max = Core.SameDishMax()
	local preset   = Core.Variety()

	local best_product, best_score, best_data = nil, nil, nil

	for product, data in pairs(entry.map) do
		local stored = existing_dishes[product] or 0

		if stored < same_max
			and Core.IsDishAllowed(cooker_name, product)
			and IsAffordable(data.combo, pool) then

			local score = Variety.Score(product, Core.BaseScore(cooker_name, product), stored, preset)

			-- A combination that can only produce this dish is worth a nudge
			-- over one that might roll into something else.
			if data.exclusive then
				score = score + 5
			end

			if best_score == nil or score > best_score then
				best_product, best_score, best_data = product, score, data
			end
		end
	end

	if best_product == nil then
		-- Everything we know about is either stocked to the cap or filtered
		-- out. Drop what we learned so the next pass starts cold rather than
		-- re-reading the same dead list forever.
		Core.Log("no dish passed the filters -- dropping the cache for", key)
		Search._cache[key] = nil
		return nil
	end

	local selected = Allocate(best_data.combo, pool)
	if selected == nil then
		Core.Log("could not allocate ingredients for", best_product)
		return nil
	end

	Variety.Record(best_product)

	Core.Log(string.format("chose %s (score %.1f%s) from %s",
		best_product, best_score, best_data.exclusive and ", guaranteed" or "",
		table.concat(best_data.combo, " + ")))

	-- A fresh table every time: NPC Friends mutates _selected_ingredients on
	-- the card it returns, and its cards are shared between NPCs.
	return
	{
		name                  = best_product,
		score                 = best_score,
		cooktime              = best_data.cooktime or 1,
		_selected_ingredients = selected,
		_hofnpc               = true,
	}
end

return Search
