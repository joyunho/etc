-- hofnpc_stations.lua
-- Makes the chef use the machines its own behaviour cannot: Warly's Portable
-- Seasoning Station, and drying racks.
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

local Stations = {}

local POT_SLOTS   = 4
local SPICE_SLOTS = 2

-- ── Drying racks ───────────────────────────────────────────────────────────
--
-- A rack is further from a Crock Pot than the seasoning station is. It has no
-- container at all -- one item goes straight onto it -- and its component
-- speaks a different language: CanDry/StartDrying/IsDrying where a pot says
-- CanCook/StartCooking/IsCooking. It also carries none of the tags NPC Friends
-- searches for, so it never even reaches the list of things to cook in.
--
-- So a rack is handed to the behaviour wrapped in a stand-in: a small table
-- that forwards position, validity and tags to the real rack, and answers
-- `components.stewer` with an adapter over the dryer. The stand-in exists only
-- inside the behaviour -- the rack in the world is never given a component it
-- does not have, so nothing else in the game, and no save file, ever sees it.
--
-- Loading is the vanilla DRY action, in the order actions.lua does it:
-- CanDry, then RemoveItem from the chef, then StartDrying -- which consumes
-- the item entity itself (dryer.lua: `dryable:Remove()`), so nothing is left
-- to clean up. Harvesting is the behaviour's own, through the same adapter.

-- Enough strikes and we stop offering that kind of station for this server
-- session. Counted per kind: a drying rack that will not take anything is no
-- reason to stop spicing, and with both switched on a shared counter would
-- have one machine's trouble shut the other one down.
local STRIKE_LIMIT = 3

Stations.attached  = false
Stations.strikes   = { spice = 0, dry = 0, brew = 0 }
Stations._orig     = {}

-- One chef on the surface and one in the caves plan independently, so the job
-- in hand is kept per NPC rather than in a single slot the two would fight
-- over. `pending` is what the station chooser may take this pass; `jobs` is
-- what a chef is actually carrying out.
Stations.pending = nil
Stations.npc     = nil
Stations.jobs    = {}
Stations.last    = {}   -- [guid] = true when that chef's last job was a spicing one

-- A name no prefab can have, used to pad the take list up to the four the
-- behaviour insists on. Our put function is the only thing that ever reads it.
local PAD = "\1hofnpc_stations_pad"

function Stations.Reset()
	Stations.strikes = { spice = 0, dry = 0, brew = 0 }
	Stations.pending = nil
	Stations.npc     = nil
	Stations.jobs    = {}
	Stations.last    = {}
end

local function Key(ent)
	return ent ~= nil and (ent.GUID or ent) or nil
end

function Stations.Take(npc)
	local key = Key(npc)
	return key ~= nil and Stations.jobs[key] or nil
end

function Stations.Claim(job)
	local key = Key(Stations.npc)
	if key ~= nil then
		Stations.jobs[key] = job
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
function Stations.IsStation(ent)
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
function Stations.Scan(containers)
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
function Stations.Choose(station, pantry, existing_dishes)
	if station == nil or pantry == nil then
		return nil
	end

	local recipes = cooking.recipes[station.prefab]
	if recipes == nil then
		return nil
	end

	existing_dishes = existing_dishes or {}
	local same_max  = Core.SameDishMax()

	-- Stations prefab names are the lower case of the recipe's spice field:
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
				-- Stations what there is most of, so the chef works through a pile
				-- of the same dish instead of picking at the rare ones.
				local score = (dish_at.count or 1) * 2 + (spice_at.count or 1)

				if best_score == nil or score > best_score then
					best_score = score
					best =
					{
						kind     = "spice",
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
function Stations.Card(job)
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

	local items

	if job.kind == "dry" then
		items = { At(job.item) }
	elseif job.kind == "brew" then
		items = {}
		for _, want in ipairs(job.items) do
			-- One entry per unit: the pickup route takes them one at a time and
			-- the four-item gate counts what came back.
			for _ = 1, want.count do
				items[#items + 1] = At(want)
			end
		end
	else
		items = { At(job.dish), At(job.spice) }
	end

	return
	{
		name                  = job.product,
		score                 = 0,
		cooktime              = job.cooktime,
		_selected_ingredients = items,
		_hofnpc               = true,
		_hofnpc_side          = job.kind or "spice",
	}
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Drying racks
-- ═══════════════════════════════════════════════════════════════════════════

function Stations.IsDryer(ent)
	return ent ~= nil
		and ent.components ~= nil
		and ent.components.dryer ~= nil
end

function Stations.IsBrewer(ent)
	return ent ~= nil
		and ent.components ~= nil
		and ent.components.brewer ~= nil
		and ent.components.container ~= nil
end

Stations.proxies = setmetatable({}, { __mode = "k" })

-- Warly's kegs and jars (Heap of Foods) are a gentler case than a rack: the
-- `brewer` component already speaks a pot's language -- IsCooking, IsDone,
-- CanCook, StartCooking, Harvest, and CanCook is container:IsFull() just as a
-- pot's is. It is only the name that differs, and the tag, so NPC Friends
-- never finds one. A stand-in fixes both at once.
local function DryerAdapter(rack)
	local dryer = rack.components.dryer

	local adapter =
	{
		-- A pot's words, answered by the rack.
		IsCooking = function() return dryer:IsDrying() end,
		IsDone    = function() return dryer:IsDone() end,
		CanCook   = function() return dryer.product == nil and not dryer:IsDrying() end,

		-- Drying starts the moment the item lands, so there is nothing left to
		-- light. Saying yes keeps the behaviour's "did it start?" check happy.
		StartCooking = function() return true end,

		Harvest = function(_, harvester) return dryer:Harvest(harvester) end,
	}

	-- product is read by the harvest step to name what came out.
	return setmetatable(adapter, { __index = function(_, k)
		if k == "product" then return dryer.product end
		return nil
	end })
end

local function BrewerAdapter(machine)
	local brewer = machine.components.brewer

	local adapter =
	{
		IsCooking    = function() return brewer:IsCooking() end,
		IsDone       = function() return brewer:IsDone() end,
		CanCook      = function() return brewer:CanCook() end,
		StartCooking = function(_, doer) return brewer:StartCooking(doer) end,
		Harvest      = function(_, harvester) return brewer:Harvest(harvester) end,
	}

	return setmetatable(adapter, { __index = function(_, k)
		if k == "product" then return brewer.product end
		return nil
	end })
end

-- The stand-in. Only the behaviour ever holds one.
function Stations.Proxy(machine)
	local cached = Stations.proxies[machine]
	if cached ~= nil then
		return cached
	end

	local kind, adapter

	if Stations.IsDryer(machine) then
		kind, adapter = "dry", DryerAdapter(machine)
	elseif Stations.IsBrewer(machine) then
		kind, adapter = "brew", BrewerAdapter(machine)
	else
		return nil
	end

	local proxy =
	{
		prefab  = machine.prefab,
		GUID    = machine.GUID,
		Transform = machine.Transform,

		-- A rack has no container; a keg does, and the behaviour opens and
		-- closes it around the loading animation.
		components =
		{
			stewer    = adapter,
			container = machine.components.container,
		},

		IsValid     = function() return machine:IsValid() end,
		GetPosition = function() return machine:GetPosition() end,
		HasTag      = function(_, tag) return machine:HasTag(tag) end,

		_hofnpc_machine = machine,
		_hofnpc_kind    = kind,
	}

	Stations.proxies[machine] = proxy
	return proxy
end

function Stations.ProxyKind(ent)
	return ent ~= nil and ent._hofnpc_kind or nil
end

function Stations.IsProxy(ent)
	return ent ~= nil and ent._hofnpc_machine ~= nil
end

-- Any machine the chef can only work through this file.
function Stations.IsSideStation(ent)
	return Stations.IsProxy(ent) or Stations.IsStation(ent)
end

-- Items in the chests that a rack would take. Dryables are not cooking
-- ingredients either, so ScanIngredients never reports them.
function Stations.ScanDryables(containers)
	local found = {}

	for _, container in ipairs(containers or {}) do
		pcall(function()
			if not container:IsValid() or container.components == nil
				or container.components.container == nil then
				return
			end

			local cont = container.components.container

			for slot = 1, cont:GetNumSlots() do
				local item = cont:GetItemInSlot(slot)

				if item ~= nil and item:IsValid()
					and item.components ~= nil and item.components.dryable ~= nil
					and found[item.prefab] == nil then

					local ok, product = pcall(item.components.dryable.GetProduct, item.components.dryable)
					local ok2, time   = pcall(item.components.dryable.GetDryTime, item.components.dryable)

					if ok and type(product) == "string" then
						found[item.prefab] =
						{
							container = container,
							slot      = slot,
							count     = StackSize(item),
							product   = product,
							drytime   = ok2 and time or 1,
						}
					end
				end
			end
		end)
	end

	return found
end

-- Racks near the chef, the same way NPC Friends finds its pots: around the
-- cooking centre the player set, within the radius it uses for farm work.
local MACHINE_RADIUS = 17

function Stations.Machines(inst)
	local out = {}

	if inst == nil or rawget(_G, "TheSim") == nil then
		return out
	end

	local centre = inst._cooking_center
	local x, z

	if type(centre) == "table" and centre.x ~= nil then
		x, z = centre.x, centre.z
	elseif type(inst.GetPosition) == "function" then
		local pos = inst:GetPosition()
		x, z = pos.x, pos.z
	else
		return out
	end

	-- FindEntities' tag list is an OR, so one sweep finds racks and kegs
	-- together. The component check below is what actually decides.
	local ok, found = pcall(function()
		return TheSim:FindEntities(x, 0, z, MACHINE_RADIUS, nil, { "INLIMBO", "burnt" }, { "dryer", "brewer" })
	end)

	if not ok or type(found) ~= "table" then
		return out
	end

	local seen = {}

	for _, ent in ipairs(found) do
		if ent:IsValid() and not seen[ent]
			and (Stations.IsDryer(ent) or Stations.IsBrewer(ent)) then
			seen[ent] = true
			out[#out + 1] = ent
		end
	end

	return out
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Kegs and jars
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Heap of Foods brews in a second, parallel cooking system. `hof_brewing` is a
-- near copy of Klei's `cooking`: brewing.recipes[machine][product], a
-- brewingredients table of prefab -> tags, an IsBrewingIngredient, and a
-- CalculateBrewing that ends in math.random() exactly as CalculateRecipe does.
--
-- Two things make this the easy one. The recipes state their own ingredients --
--
--     wine_berries = { card_def = { ingredients = {{"berries", 2}, {"ice", 1}} } }
--
-- so there is nothing to search for; and Brewer:StartCooking reads the module
-- table through an upvalue (`local brewing = require("hof_brewing")`), so the
-- product can be forced by swapping one field on that table for the length of
-- the call -- which is what NPC Friends does to cooking.CalculateRecipe, for
-- the same reason.
--
-- A brew takes days rather than seconds, so a keg the chef fills is a keg that
-- looks after itself for a long while.

Stations._brewing = nil

-- nil, and cached as nil, when Heap of Foods is not installed.
function Stations.Brewing()
	if Stations._brewing ~= nil then
		return Stations._brewing ~= false and Stations._brewing or nil
	end

	local ok, mod = pcall(require, "hof_brewing")

	if ok and type(mod) == "table" and type(mod.recipes) == "table" then
		Stations._brewing = mod
		return mod
	end

	Stations._brewing = false
	return nil
end

-- Brewing has its own ingredient table, so a keg's ingredients are invisible
-- both to NPC Friends' scan and to the one hofnpc_search uses.
function Stations.ScanBrewables(containers)
	local brewing = Stations.Brewing()
	if brewing == nil then
		return {}
	end

	local found = {}

	for _, container in ipairs(containers or {}) do
		pcall(function()
			if not container:IsValid() or container.components == nil
				or container.components.container == nil then
				return
			end

			local cont = container.components.container

			for slot = 1, cont:GetNumSlots() do
				local item = cont:GetItemInSlot(slot)

				if item ~= nil and item:IsValid()
					and brewing.brewingredients[item.prefab] ~= nil then

					local at = found[item.prefab]
					if at == nil then
						found[item.prefab] =
						{
							container = container,
							slot      = slot,
							count     = StackSize(item),
						}
					else
						at.count = at.count + StackSize(item)
					end
				end
			end
		end)
	end

	return found
end

function Stations.ChooseBrew(proxy, brewables, existing_dishes)
	local brewing = Stations.Brewing()
	if brewing == nil or proxy == nil or brewables == nil then
		return nil
	end

	local machine = proxy._hofnpc_machine
	local recipes = machine ~= nil and brewing.recipes[machine.prefab] or nil
	if recipes == nil then
		return nil
	end

	-- StartCooking only fires when the container is full, so a recipe that does
	-- not fill it exactly can never be brewed by anyone.
	local slots = StationSlots(machine)
	if slots == nil then
		return nil
	end

	existing_dishes = existing_dishes or {}
	local same_max  = Core.SameDishMax()

	local best, best_score = nil, nil

	for product, recipe in pairs(recipes) do
		local card = recipe.card_def

		if type(card) == "table" and type(card.ingredients) == "table"
			and (existing_dishes[product] or 0) < same_max
			and Core.IsDishAllowed(machine.prefab, product) then

			local total, affordable, items = 0, true, {}

			for _, pair in ipairs(card.ingredients) do
				local prefab, count = pair[1], pair[2] or 1
				local at = brewables[prefab]

				if type(prefab) ~= "string" or at == nil or (at.count or 0) < count then
					affordable = false
					break
				end

				total = total + count
				items[#items + 1] = { prefab = prefab, at = at, count = count }
			end

			if affordable and total == slots then
				-- Brew the thing we have most spare of, so a rare berry is not
				-- spent on a keg when it could be dinner.
				local spare = nil
				for _, want in ipairs(items) do
					local left = (want.at.count or 0) - want.count
					if spare == nil or left < spare then
						spare = left
					end
				end

				if best_score == nil or spare > best_score then
					best_score = spare
					best =
					{
						kind     = "brew",
						product  = product,
						cooktime = recipe.cooktime or 1,
						items    = items,
					}
				end
			end
		end
	end

	return best
end

function Stations.ChooseDry(rack, dryables, existing_dishes)
	if rack == nil or dryables == nil then
		return nil
	end

	existing_dishes = existing_dishes or {}
	local same_max  = Core.SameDishMax()

	local best, best_score = nil, nil

	for prefab, at in pairs(dryables) do
		if (existing_dishes[at.product] or 0) < same_max then
			-- Dry what there is most of; a single mushroom is better eaten.
			local score = at.count or 1

			if best_score == nil or score > best_score then
				best_score = score
				best =
				{
					kind     = "dry",
					product  = at.product,
					cooktime = at.drytime or 1,
					item     = { prefab = prefab, at = at },
				}
			end
		end
	end

	return best
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Driving NPC Friends' behaviour
-- ═══════════════════════════════════════════════════════════════════════════

-- True when the plan in hand is a spice job, judged from the station itself
-- rather than from a flag: PlanCooking builds its own table and does not carry
-- our marker across.
local function PlanKind(plan)
	if plan == nil then
		return nil
	end

	local kind = Stations.ProxyKind(plan.cookpot)
	if kind ~= nil then
		return kind
	end

	if Stations.IsStation(plan.cookpot) then
		return "spice"
	end

	return nil
end

local function PlanIsSideJob(plan)
	return PlanKind(plan) ~= nil
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

	local job = Stations.Take(npc)
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

-- The vanilla DRY action, in actions.lua's order: check, detach from the chef,
-- then start. StartDrying removes the item entity itself when it succeeds
-- (dryer.lua: `dryable:Remove()`), and when it fails the item has to go back in
-- the bag or it is gone for good.
local function LoadDryer(npc, proxy, plan)
	local rack = proxy ~= nil and proxy._hofnpc_machine or nil
	if rack == nil or not rack:IsValid() or rack.components.dryer == nil then
		return false
	end

	local job = Stations.Take(npc)
	if job == nil or job.kind ~= "dry" then
		return false
	end

	local dryer     = rack.components.dryer
	local inventory = npc.components ~= nil and npc.components.inventory or nil
	if inventory == nil then
		return false
	end

	for slot = 1, (inventory.maxslots or 0) do
		local item = inventory:GetItemInSlot(slot)

		if item ~= nil and item:IsValid() and item.prefab == job.item.prefab then
			local one

			local stackable = item.components ~= nil and item.components.stackable or nil
			if stackable ~= nil and StackSize(item) > 1 then
				one = stackable:Get(1)
			else
				one = inventory:RemoveItem(item)
			end

			if one == nil then
				return false
			end

			if not dryer:CanDry(one) or not dryer:StartDrying(one) then
				inventory:GiveItem(one)
				return false
			end

			Core.Log("drying:", tostring(job.item.prefab), "->", tostring(job.product))
			return true
		end
	end

	return false
end

-- Fill the keg, then start it with the product the plan named. Forcing is the
-- same trick NPC Friends uses on cooking.CalculateRecipe, applied to brewing's
-- own: swap the field for the length of the call and put it back, so the
-- machine's own math.random() never gets a say and never moves the world seed.
local function LoadBrewer(npc, proxy, plan)
	local machine = proxy ~= nil and proxy._hofnpc_machine or nil
	if machine == nil or not machine:IsValid()
		or machine.components.brewer == nil or machine.components.container == nil then
		return false
	end

	local job = Stations.Take(npc)
	if job == nil or job.kind ~= "brew" then
		return false
	end

	local brewing = Stations.Brewing()
	if brewing == nil then
		return false
	end

	local container = machine.components.container
	local brewer    = machine.components.brewer
	local inventory = npc.components ~= nil and npc.components.inventory or nil

	if inventory == nil or brewer:IsCooking() or brewer:IsDone() then
		return false
	end

	local placed = 0

	for _, want in ipairs(job.items) do
		for _ = 1, want.count do
			for slot = 1, (inventory.maxslots or 0) do
				local item = inventory:GetItemInSlot(slot)

				if item ~= nil and item:IsValid() and item.prefab == want.prefab then
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
	end

	if not brewer:CanCook() then
		Core.Log(string.format("could not fill the keg (%d placed)", placed))
		return false
	end

	local original = brewing.CalculateBrewing
	brewing.CalculateBrewing = function()
		return plan.recipe_name or job.product, plan.cooktime or job.cooktime or 1
	end

	local ok, err = pcall(brewer.StartCooking, brewer, npc)

	brewing.CalculateBrewing = original

	if not ok then
		Core.Err("the keg would not start:", tostring(err))
		return false
	end

	Core.Log("brewing:", tostring(plan.recipe_name or job.product))
	return true
end

function Stations.Attach(planner)
	if Stations.attached then
		return true
	end

	local class = rawget(_G, "NPCCookingBehavior")
	if class == nil or type(class._MakeTakeActionFn) ~= "function"
		or type(class._MakePutActionFn) ~= "function" then
		return false
	end

	Stations._orig.take = class._MakeTakeActionFn
	Stations._orig.put  = class._MakePutActionFn

	-- A rack carries none of the tags NPC Friends searches for, so it never
	-- appears in the list of things to cook in. This is the list.
	if type(class._GetCookpots) == "function" then
		Stations._orig.pots = class._GetCookpots

		class._GetCookpots = function(self)
			local pots = Stations._orig.pots(self) or {}

			if Core.cfg.enabled and (Core.cfg.use_dryer or Core.cfg.use_brewer) then
				pcall(function()
					for _, machine in ipairs(Stations.Machines(self.inst)) do
						local proxy = Stations.Proxy(machine)
						if proxy ~= nil then
							pots[#pots + 1] = proxy
						end
					end
				end)
			end

			return pots
		end
	end

	-- Their gate counts this list, and the list holds prefab names, so padding
	-- it is enough to be let through to the station. The padding never reaches
	-- their loader: the put wrapper below takes over for a spice job.
	class._MakeTakeActionFn = function(self, items, taken)
		local inner = Stations._orig.take(self, items, taken)

		return function(npc, container)
			inner(npc, container)

			if PlanIsSideJob(self._plan) then
				while #taken < POT_SLOTS do
					taken[#taken + 1] = PAD
				end
			end
		end
	end

	class._MakePutActionFn = function(self, taken, plan, node)
		if not PlanIsSideJob(plan) then
			return Stations._orig.put(self, taken, plan, node)
		end

		local kind = PlanKind(plan)

		return function(npc, station)
			local load = (kind == "dry") and LoadDryer
				or (kind == "brew") and LoadBrewer
				or LoadStation
			local ok, started = pcall(load, npc, station, plan)

			if not ok then
				Core.Err("loading a " .. tostring(kind) .. " station failed:", tostring(started))
				started = false
			end

			local counted = kind or "spice"

			if started then
				Stations.strikes[counted] = 0
				if node ~= nil then
					node._cook_start_time = GetTime()
				end
			else
				Stations.strikes[counted] = (Stations.strikes[counted] or 0) + 1
				if Stations.strikes[counted] >= STRIKE_LIMIT then
					Core.Info(counted .. ": this kind of station is not taking orders -- leaving it alone from now on")
				end
			end

			local key = Key(npc)
			if key ~= nil then
				Stations.jobs[key] = nil
			end
		end
	end

	Stations.attached = true
	Core.Log("the chef can use a seasoning station")
	return true
end

-- Whether the chef should be sent to a station right now. Never twice running:
-- spicing is quick and a chef that only ever spices stops filling the larder.
function Stations.Wanted()
	if not Core.cfg.enabled then
		return false
	end

	if not Stations.attached or Stations.pending == nil then
		return false
	end

	-- Each kind of machine has its own switch and its own patience.
	local kind = Stations.pending.kind or "spice"

	if (Stations.strikes[kind] or 0) >= STRIKE_LIMIT then
		return false
	end

	if kind == "dry" then
		if not Core.cfg.use_dryer then return false end
	elseif kind == "brew" then
		if not Core.cfg.use_brewer then return false end
	elseif not Core.cfg.use_spicer then
		return false
	end

	local key = Key(Stations.npc)
	return key == nil or not Stations.last[key]
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Survey, run once per planning pass
-- ═══════════════════════════════════════════════════════════════════════════
--
-- PlanCooking picks the station before it scans anything, so the question
-- "is there a spice job waiting?" has to be answered before it starts. It
-- hands us the chef, its containers and its stations, which is everything the
-- answer needs.

function Stations.AttachPlanner(planner)
	if planner == nil or planner._hofnpc_stations_attached then
		return false
	end

	local plan_cooking = planner.PlanCooking
	if type(plan_cooking) ~= "function" then
		return false
	end

	planner._hofnpc_stations_attached = true

	planner.PlanCooking = function(inst, containers, cookpots, is_warly)
		Stations.pending = nil
		Stations.npc     = inst

		-- The behaviour class only exists once a chef's brain has been built,
		-- which is after this file is loaded, so attaching waits until here.
		if not Stations.attached and Core.cfg.use_spicer then
			pcall(Stations.Attach, planner)
		end

		if Stations.attached then
			pcall(function()
				local existing = {}
				if type(planner.CountExistingDishes) == "function" then
					local ok, counted = pcall(planner.CountExistingDishes, containers)
					if ok and type(counted) == "table" then
						existing = counted
					end
				end

				local function Idle(ent)
					local stewer = ent.components.stewer
					return not stewer:IsCooking() and not stewer:IsDone()
				end

				-- A seasoning station first: spicing something already cooked is
				-- worth more than drying something that could still be cooked.
				if Core.cfg.use_spicer and (Stations.strikes.spice or 0) < STRIKE_LIMIT then
					for _, ent in ipairs(cookpots or {}) do
						if ent ~= nil and ent:IsValid() and Stations.IsStation(ent) and Idle(ent) then
							Stations.pending = Stations.Choose(ent, Stations.Scan(containers), existing)
							break
						end
					end
				end

				-- A keg next: a brew takes days, so getting one started early is
				-- worth more than another rack of jerky.
				if Stations.pending == nil and Core.cfg.use_brewer
					and (Stations.strikes.brew or 0) < STRIKE_LIMIT then
					for _, ent in ipairs(cookpots or {}) do
						if ent ~= nil and ent:IsValid() and Stations.ProxyKind(ent) == "brew" and Idle(ent) then
							Stations.pending = Stations.ChooseBrew(ent, Stations.ScanBrewables(containers), existing)
							break
						end
					end
				end

				if Stations.pending == nil and Core.cfg.use_dryer
					and (Stations.strikes.dry or 0) < STRIKE_LIMIT then
					for _, ent in ipairs(cookpots or {}) do
						if ent ~= nil and ent:IsValid() and Stations.ProxyKind(ent) == "dry" and Idle(ent) then
							Stations.pending = Stations.ChooseDry(ent, Stations.ScanDryables(containers), existing)
							break
						end
					end
				end
			end)
		end
		local plan = plan_cooking(inst, containers, cookpots, is_warly)

		local key = Key(inst)
		if key ~= nil then
			if plan == nil then
				-- Nothing came of it, so nothing is being carried out.
				Stations.jobs[key] = nil
			else
				Stations.last[key] = PlanIsSideJob(plan)
			end
		end

		Stations.pending = nil
		Stations.npc     = nil

		return plan
	end

	return true
end

return Stations
