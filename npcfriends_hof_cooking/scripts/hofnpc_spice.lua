-- hofnpc_spice.lua
-- Makes the chef use Warly's Portable Seasoning Station.
--
-- ── Why this needs its own file ────────────────────────────────────────────
--
-- Everything else in this patch changes what the chef decides. This changes
-- what it does, and the doing lives in NPC Friends' behaviour, which ships
-- obfuscated. Two things in there stand in the way of a seasoning station:
--
--   * the pickup phase refuses to walk to the station unless the chef is
--     carrying at least four items, and
--   * the put phase refuses to start cooking unless it placed four.
--
-- A station has two slots -- a cooked dish in the first, a spice in the second
-- (scripts/containers.lua, params.portablespicer) -- so a chef sent there with
-- four raw ingredients places none of them and the cook fails. That is why
-- hofnpc_cookware keeps the chef away from one by default.
--
-- ── What makes it possible anyway ──────────────────────────────────────────
--
-- The behaviour is obfuscated but it is not sealed. `NPCCookingBehavior` is a
-- plain global class, and the two steps that matter are methods on it:
--
--     NPCCookingBehavior:_MakeTakeActionFn(items, taken)  -> fn(npc, container)
--     NPCCookingBehavior:_MakePutActionFn(taken, plan, node) -> fn(npc, pot)
--
-- The first returns the function that moves items out of a chest and appends
-- their prefab names to `taken` -- and `taken` is the very list the four-item
-- gate counts. The second returns the function that loads the pot and starts
-- it. Wrapping those two is enough: nothing of theirs is copied, unpacked or
-- reimplemented, and both wrappers call straight through for an ordinary cook.
--
-- ── What the station actually needs ────────────────────────────────────────
--
-- Nothing clever. Every one of DST's 316 spiced recipes states its own two
-- ingredients (scripts/spicedfoods.lua):
--
--     name     = "meatballs_spice_garlic"
--     basename = "meatballs"
--     spice    = "SPICE_GARLIC"
--
-- so there is nothing to search for and nothing to guess: read basename and
-- spice, find one of each in the chests, and the pot is loaded. Spicing then
-- runs on the same ACTIONS.COOK and the same Stewer:StartCooking as a Crock
-- Pot, and Stewer:CanCook() is just container:IsFull(), which for two slots
-- means the dish and the spice.
--
-- ── If any of that stops being true ────────────────────────────────────────
--
-- Attach gives up and returns false, the station goes back to being excluded,
-- and the chef cooks exactly as it does today. A spice job that fails to start
-- counts a strike, and after a few the chef stops being offered the station,
-- so a mismatch costs a couple of wasted trips rather than a chef that never
-- cooks again.

local cooking = require("cooking")

local Core = require("hofnpc_core")

local Spice = {}

local POT_SLOTS   = 4
local SPICE_SLOTS = 2

-- Enough strikes and we stop offering the station for this server session.
local STRIKE_LIMIT = 3

Spice.attached  = false
Spice.strikes   = 0
Spice._orig     = {}

-- One chef on the surface and one in the caves plan independently, so the job
-- in hand is kept per NPC rather than in a single slot the two would fight
-- over. `pending` is what the station chooser may take this pass; `jobs` is
-- what a chef is actually carrying out.
Spice.pending = nil
Spice.npc     = nil
Spice.jobs    = {}
Spice.last    = {}   -- [guid] = true when that chef's last job was a spicing one

-- A name no prefab can have, used to pad the take list up to the four the
-- behaviour insists on. Our put function is the only thing that ever reads it.
local PAD = "\1hofnpc_spice_pad"

function Spice.Reset()
	Spice.strikes = 0
	Spice.pending = nil
	Spice.npc     = nil
	Spice.jobs    = {}
	Spice.last    = {}
end

local function Key(ent)
	return ent ~= nil and (ent.GUID or ent) or nil
end

function Spice.Take(npc)
	local key = Key(npc)
	return key ~= nil and Spice.jobs[key] or nil
end

function Spice.Claim(job)
	local key = Key(Spice.npc)
	if key ~= nil then
		Spice.jobs[key] = job
	end
	return job
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Reading the station
-- ═══════════════════════════════════════════════════════════════════════════

local function StationSlots(ent)
	local container = ent ~= nil and ent.components ~= nil and ent.components.container or nil
	if container == nil then
		return nil
	end

	if type(container.GetNumSlots) == "function" then
		local ok, n = pcall(container.GetNumSlots, container)
		if ok and type(n) == "number" and n > 0 then
			return n
		end
	end

	if type(container.numslots) == "number" and container.numslots > 0 then
		return container.numslots
	end

	return nil
end

-- A seasoning station: something that cooks, has room for exactly the dish and
-- the spice, and has spiced recipes registered against its prefab. The last
-- part is what keeps this off a modded two-slot cooker that means something
-- else entirely.
function Spice.IsStation(ent)
	if ent == nil or ent.components == nil or ent.components.stewer == nil then
		return false
	end

	local slots = StationSlots(ent)
	if slots == nil or slots < SPICE_SLOTS or slots >= POT_SLOTS then
		return false
	end

	local recipes = cooking.recipes ~= nil and cooking.recipes[ent.prefab] or nil
	if recipes == nil then
		return false
	end

	for _, recipe in pairs(recipes) do
		if recipe.basename ~= nil and recipe.spice ~= nil then
			return true
		end
	end

	return false
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Reading the chests
-- ═══════════════════════════════════════════════════════════════════════════

local function StackSize(item)
	local stackable = item.components ~= nil and item.components.stackable or nil
	if stackable ~= nil and type(stackable.StackSize) == "function" then
		local ok, n = pcall(stackable.StackSize, stackable)
		if ok and type(n) == "number" and n > 0 then
			return n
		end
	end
	return 1
end

local function HasTag(item, tag)
	if type(item.HasTag) ~= "function" then
		return false
	end
	local ok, has = pcall(item.HasTag, item, tag)
	return ok and has == true
end

-- Walks the chef's containers once and notes every cooked dish that has not
-- been spiced yet, and every spice. Neither is a cooking ingredient, so NPC
-- Friends' own ScanIngredients never sees them.
function Spice.Scan(containers)
	local dishes, spices = {}, {}

	for _, container in ipairs(containers or {}) do
		local ok = pcall(function()
			if not container:IsValid() or container.components == nil
				or container.components.container == nil then
				return
			end

			local cont  = container.components.container
			local slots = cont:GetNumSlots()

			for slot = 1, slots do
				local item = cont:GetItemInSlot(slot)

				if item ~= nil and item:IsValid() then
					local where =
					{
						container = container,
						slot      = slot,
						count     = StackSize(item),
					}

					if HasTag(item, "spice") then
						spices[item.prefab] = spices[item.prefab] or where
					elseif HasTag(item, "preparedfood") and not HasTag(item, "spicedfood") then
						dishes[item.prefab] = dishes[item.prefab] or where
					end
				end
			end
		end)

		if not ok then
			-- A container we cannot read is simply not part of the pantry.
			Core.Log("could not read a container while looking for spices")
		end
	end

	return { dishes = dishes, spices = spices }
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Choosing what to spice
-- ═══════════════════════════════════════════════════════════════════════════

-- The spiced dish is worth making when we hold the dish, hold the spice, the
-- station knows the recipe, and the larder is not already full of the result.
function Spice.Choose(station, pantry, existing_dishes)
	if station == nil or pantry == nil then
		return nil
	end

	local recipes = cooking.recipes[station.prefab]
	if recipes == nil then
		return nil
	end

	existing_dishes = existing_dishes or {}
	local same_max  = Core.SameDishMax()

	-- Spice prefab names are the lower case of the recipe's spice field:
	-- SPICE_GARLIC -> spice_garlic (scripts/spicedfoods.lua).
	local best, best_score = nil, nil

	for product, recipe in pairs(recipes) do
		local base  = recipe.basename
		local spice = recipe.spice

		if base ~= nil and spice ~= nil and (existing_dishes[product] or 0) < same_max
			and Core.IsDishAllowed(station.prefab, product) then

			local dish_at  = pantry.dishes[base]
			local spice_at = pantry.spices[string.lower(spice)]

			if dish_at ~= nil and spice_at ~= nil then
				-- Spice what there is most of, so the chef works through a pile
				-- of the same dish instead of picking at the rare ones.
				local score = (dish_at.count or 1) * 2 + (spice_at.count or 1)

				if best_score == nil or score > best_score then
					best_score = score
					best =
					{
						product  = product,
						cooktime = recipe.cooktime or 1,
						dish     = { prefab = base, at = dish_at },
						spice    = { prefab = string.lower(spice), at = spice_at },
					}
				end
			end
		end
	end

	return best
end

-- The card NPC Friends' PlanCooking expects back from FindBestRecipe. Only two
-- ingredients: the walk and the pickup are theirs, the loading is ours.
function Spice.Card(job)
	if job == nil then
		return nil
	end

	local function At(part)
		return
		{
			container  = part.at.container,
			slot       = part.at.slot,
			prefab     = part.prefab,
			take_count = 1,
		}
	end

	return
	{
		name                  = job.product,
		score                 = 0,
		cooktime              = job.cooktime,
		_selected_ingredients = { At(job.dish), At(job.spice) },
		_hofnpc               = true,
		_hofnpc_spice         = true,
	}
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Driving NPC Friends' behaviour
-- ═══════════════════════════════════════════════════════════════════════════

-- True when the plan in hand is a spice job, judged from the station itself
-- rather than from a flag: PlanCooking builds its own table and does not carry
-- our marker across.
local function PlanIsSpice(plan)
	return plan ~= nil and Spice.IsStation(plan.cookpot)
end

local function LoadStation(npc, station, plan)
	local container = station.components.container
	local stewer    = station.components.stewer
	local inventory = npc.components ~= nil and npc.components.inventory or nil

	if container == nil or stewer == nil or inventory == nil then
		return false
	end

	if stewer:IsDone() then
		-- Something is still sitting in it. Leave it for the harvest step.
		return false
	end

	local job = Spice.Take(npc)
	if job == nil then
		return false
	end

	-- Take the dish and the spice out of the chef's bag by name. The four-item
	-- gate was satisfied with padding, not with real items, so the bag holds
	-- exactly these two -- but a chef that picked something up elsewhere would
	-- not confuse this.
	local placed = 0

	for _, prefab in ipairs({ job.dish.prefab, job.spice.prefab }) do
		for slot = 1, (inventory.maxslots or 0) do
			local item = inventory:GetItemInSlot(slot)

			if item ~= nil and item:IsValid() and item.prefab == prefab then
				local one

				local stackable = item.components ~= nil and item.components.stackable or nil
				if stackable ~= nil and StackSize(item) > 1 then
					one = stackable:Get(1)
				else
					one = inventory:RemoveItem(item)
				end

				if one ~= nil then
					one.prevcontainer = nil
					one.prevslot      = nil
					container:GiveItem(one)
					placed = placed + 1
				end
				break
			end
		end
	end

	if placed < SPICE_SLOTS or not stewer:CanCook() then
		Core.Log(string.format("could not load the seasoning station (%d of %d placed)",
			placed, SPICE_SLOTS))
		return false
	end

	-- Same forcing NPC Friends uses for a pot, and for the same reason: the
	-- station is about to ask cooking.CalculateRecipe what it made, and the
	-- answer has to be the dish the plan named.
	local planner = Core.host.planner
	local forced  = planner ~= nil and planner.WithForcedProduct or nil

	local function Start()
		stewer:StartCooking(npc)
	end

	if type(forced) == "function" then
		forced(plan.recipe_name or job.product, plan.cooktime or job.cooktime or 1, Start)
	else
		Start()
	end

	Core.Log("spicing:", tostring(plan.recipe_name or job.product))
	return true
end

function Spice.Attach(planner)
	if Spice.attached then
		return true
	end

	local class = rawget(_G, "NPCCookingBehavior")
	if class == nil or type(class._MakeTakeActionFn) ~= "function"
		or type(class._MakePutActionFn) ~= "function" then
		return false
	end

	Spice._orig.take = class._MakeTakeActionFn
	Spice._orig.put  = class._MakePutActionFn

	-- Their gate counts this list, and the list holds prefab names, so padding
	-- it is enough to be let through to the station. The padding never reaches
	-- their loader: the put wrapper below takes over for a spice job.
	class._MakeTakeActionFn = function(self, items, taken)
		local inner = Spice._orig.take(self, items, taken)

		return function(npc, container)
			inner(npc, container)

			if PlanIsSpice(self._plan) then
				while #taken < POT_SLOTS do
					taken[#taken + 1] = PAD
				end
			end
		end
	end

	class._MakePutActionFn = function(self, taken, plan, node)
		if not PlanIsSpice(plan) then
			return Spice._orig.put(self, taken, plan, node)
		end

		return function(npc, station)
			local ok, started = pcall(LoadStation, npc, station, plan)

			if not ok then
				Core.Err("loading the seasoning station failed:", tostring(started))
				started = false
			end

			if started then
				Spice.strikes = 0
				if node ~= nil then
					node._cook_start_time = GetTime()
				end
			else
				Spice.strikes = Spice.strikes + 1
				if Spice.strikes >= STRIKE_LIMIT then
					Core.Info("the seasoning station is not taking orders -- leaving it alone from now on")
				end
			end

			local key = Key(npc)
			if key ~= nil then
				Spice.jobs[key] = nil
			end
		end
	end

	Spice.attached = true
	Core.Log("the chef can use a seasoning station")
	return true
end

-- Whether the chef should be sent to a station right now. Never twice running:
-- spicing is quick and a chef that only ever spices stops filling the larder.
function Spice.Wanted()
	if not Core.cfg.enabled or not Core.cfg.use_spicer then
		return false
	end

	if not Spice.attached or Spice.strikes >= STRIKE_LIMIT or Spice.pending == nil then
		return false
	end

	local key = Key(Spice.npc)
	return key == nil or not Spice.last[key]
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Survey, run once per planning pass
-- ═══════════════════════════════════════════════════════════════════════════
--
-- PlanCooking picks the station before it scans anything, so the question
-- "is there a spice job waiting?" has to be answered before it starts. It
-- hands us the chef, its containers and its stations, which is everything the
-- answer needs.

function Spice.AttachPlanner(planner)
	if planner == nil or planner._hofnpc_spice_attached then
		return false
	end

	local plan_cooking = planner.PlanCooking
	if type(plan_cooking) ~= "function" then
		return false
	end

	planner._hofnpc_spice_attached = true

	planner.PlanCooking = function(inst, containers, cookpots, is_warly)
		Spice.pending = nil
		Spice.npc     = inst

		-- The behaviour class only exists once a chef's brain has been built,
		-- which is after this file is loaded, so attaching waits until here.
		if not Spice.attached and Core.cfg.use_spicer then
			pcall(Spice.Attach, planner)
		end

		if Spice.attached and Core.cfg.use_spicer and Spice.strikes < STRIKE_LIMIT then
			pcall(function()
				local station = nil
				for _, ent in ipairs(cookpots or {}) do
					if ent ~= nil and ent:IsValid() and Spice.IsStation(ent) then
						local stewer = ent.components.stewer
						if not stewer:IsCooking() and not stewer:IsDone() then
							station = ent
							break
						end
					end
				end

				if station ~= nil then
					local existing = {}
					if type(planner.CountExistingDishes) == "function" then
						local ok, counted = pcall(planner.CountExistingDishes, containers)
						if ok and type(counted) == "table" then
							existing = counted
						end
					end

					Spice.pending = Spice.Choose(station, Spice.Scan(containers), existing)
				end
			end)
		end

		local plan = plan_cooking(inst, containers, cookpots, is_warly)

		local key = Key(inst)
		if key ~= nil then
			if plan == nil then
				-- Nothing came of it, so nothing is being carried out.
				Spice.jobs[key] = nil
			else
				Spice.last[key] = PlanIsSpice(plan)
			end
		end

		Spice.pending = nil
		Spice.npc     = nil

		return plan
	end

	return true
end

return Spice
