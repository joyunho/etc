-- hofnpc_search.lua
-- The replacement for NPC Friends' CookingPlanner.FindBestRecipe.
--
-- NPC Friends decides what to cook by walking a hand written table of recipe
-- cards (scripts/npc/npc_cooking_recipes.lua). That table only lists vanilla
-- dishes plus a few manually added mod dishes, so the ~200 Crock Pot dishes
-- from Heap of Foods are invisible to the chef no matter how full the pantry
-- is.
--
-- Instead of hand writing 200 more cards, this module never names a dish at
-- all. It takes the ingredients the NPC can actually reach, tries combinations
-- of four, and asks the GAME'S OWN resolver -- cooking.CalculateRecipe -- what
-- each combination would produce. Whatever any food mod registered through the
-- normal AddCookerRecipe/AddIngredientValues API is therefore discovered for
-- free, with no per-mod knowledge and nothing to keep in sync.

local cooking  = require("cooking")

local Core     = require("hofnpc_core")
local Variety  = require("hofnpc_variety")

local Search = {}

local POT_SLOTS = 4

-- Discovered combinations, keyed by cooker name.
--   _cache[cooker] = { sig = "...", count = N, map = { [product] = {combo, cost, cooktime} } }
-- The signature is the set of ingredient types in reach; it only changes when
-- something genuinely new appears in (or disappears from) the pantry, so a
-- warm cache survives across cooking cycles and the search stays cheap.
Search._cache = {}

function Search.ResetCache()
	Search._cache = {}
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
	local types = {}
	local avail = {}
	local names = {}

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
-- random sample of the rest. The random tail is deliberate: successive
-- planning passes look at different corners of the pantry, which is a second,
-- cheap source of dish variety.
local function SelectTypes(types, max_types)
	if #types <= max_types then
		return types
	end

	table.sort(types, function(a, b)
		if a.avail ~= b.avail then
			return a.avail > b.avail
		end
		return a.prefab < b.prefab
	end)

	local head = math.min(#types, math.ceil(max_types * 0.6))
	local kept = {}

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

	return kept
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Combination search
-- ═══════════════════════════════════════════════════════════════════════════

-- Enumerate multisets of POT_SLOTS ingredients and record what each one cooks
-- into. Bounded by max_evals and by the candidate cap so a large pantry can
-- never turn one planning pass into a server hitch.
local function Discover(types, avail, cooker_name, max_evals, max_candidates, entry)
	local n = #types
	if n == 0 then
		return 0
	end

	for i = 1, n do
		types[i].used = 0
	end

	local map    = entry.map
	local names  = {}
	local evals  = 0

	local function Evaluate()
		evals = evals + 1

		local product, cooktime = cooking.CalculateRecipe(cooker_name, names)
		if product == nil then
			return
		end

		-- Prefer the combination that leans on the most plentiful ingredients,
		-- so the chef does not burn the last of something rare.
		local cost = 0
		for i = 1, POT_SLOTS do
			cost = cost + 1 / (avail[names[i]] or 1)
		end

		local current = map[product]
		if current == nil then
			entry.count = entry.count + 1
			map[product] =
			{
				combo    = { names[1], names[2], names[3], names[4] },
				cost     = cost,
				cooktime = cooktime,
			}
		elseif cost < current.cost then
			current.combo    = { names[1], names[2], names[3], names[4] }
			current.cost     = cost
			current.cooktime = cooktime
		end
	end

	local function Exhausted()
		return evals >= max_evals or entry.count >= max_candidates
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

	if cooking.recipes == nil or cooking.recipes[cooker_name] == nil then
		Core.Log("no recipe table for cooker", cooker_name)
		return nil
	end

	local types, avail, signature = BuildTypes(pool)
	if #types == 0 then
		return nil
	end

	local budget = Core.Budget()

	local entry = Search._cache[cooker_name]
	if entry == nil or entry.sig ~= signature then
		entry = { sig = signature, count = 0, map = {} }
		Search._cache[cooker_name] = entry
	end

	-- A cold cache pays the full budget once; afterwards each pass only tops
	-- the candidate list up, which keeps discovering new dishes over time
	-- without re-running the whole search every couple of seconds.
	local warm     = entry.count > 0
	local max_eval = warm and budget.refresh_evals or budget.max_evals

	local searched = SelectTypes(types, budget.max_types)
	local evals    = Discover(searched, avail, cooker_name, max_eval, budget.max_candidates, entry)

	Core.Log(string.format(
		"cooker=%s types=%d searched=%d evals=%d candidates=%d (%s)",
		cooker_name, #types, #searched, evals, entry.count, warm and "warm" or "cold"))

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

			if best_score == nil or score > best_score then
				best_product, best_score, best_data = product, score, data
			end
		end
	end

	if best_product == nil then
		Core.Log("no dish passed the filters")
		return nil
	end

	local selected = Allocate(best_data.combo, pool)
	if selected == nil then
		Core.Log("could not allocate ingredients for", best_product)
		return nil
	end

	Variety.Record(best_product)

	Core.Log(string.format("chose %s (score %.1f) from %s",
		best_product, best_score, table.concat(best_data.combo, " + ")))

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
