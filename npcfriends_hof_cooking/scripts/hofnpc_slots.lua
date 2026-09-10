-- hofnpc_slots.lua
--
-- 닫힌 상자 안을 제대로 읽기.
--
-- Reading a container without trusting GetNumSlots().
--
-- Container:GetNumSlots() returns self.numslots, which is filled in by
-- WidgetSetup from the container's widget parameters. Several popular
-- container mods (upgradeable / expandable chests, the ones that add
-- Sort / Lock / Collect buttons) only realise those parameters when the
-- container is actually opened. Until someone opens it, GetNumSlots() answers
-- 0 -- so the usual
--
--     for slot = 1, cont:GetNumSlots() do
--
-- never runs a single iteration and the chest reads as empty, even though the
-- items are sitting right there in cont.slots. That is why the chef can look
-- straight at a full fridge, report "no ingredients", and then start cooking
-- the moment a player opens that fridge.
--
-- So: walk cont.slots directly, and only fall back to the slot-count loop and
-- then the replica if that table is unavailable.

local cooking = require("cooking")

local Core = require("hofnpc_core")

local Slots = {}

-- Returns a slot -> item table. Never trusts a slot count.
function Slots.Read(container)
	local out = {}

	if container == nil or container.components == nil then
		return out
	end

	local cont = container.components.container
	if cont == nil then
		return out
	end

	-- 1) The authoritative table, whatever the widget thinks the size is.
	if type(cont.slots) == "table" then
		for slot, item in pairs(cont.slots) do
			if item ~= nil then
				out[slot] = item
			end
		end
	end

	-- 2) The ordinary way, in case a container keeps its items elsewhere.
	if next(out) == nil and cont.GetNumSlots ~= nil and cont.GetItemInSlot ~= nil then
		local ok, count = pcall(cont.GetNumSlots, cont)
		if ok and type(count) == "number" then
			for slot = 1, count do
				local got, item = pcall(cont.GetItemInSlot, cont, slot)
				if got and item ~= nil then
					out[slot] = item
				end
			end
		end
	end

	-- 3) The replica, as a last resort.
	if next(out) == nil and container.replica ~= nil and container.replica.container ~= nil then
		local rep = container.replica.container
		if rep.GetNumSlots ~= nil and rep.GetItemInSlot ~= nil then
			local ok, count = pcall(rep.GetNumSlots, rep)
			if ok and type(count) == "number" then
				for slot = 1, count do
					local got, item = pcall(rep.GetItemInSlot, rep, slot)
					if got and item ~= nil then
						out[slot] = item
					end
				end
			end
		end
	end

	return out
end

function Slots.StackSize(item)
	if item ~= nil and item.components ~= nil and item.components.stackable ~= nil then
		local ok, size = pcall(item.components.stackable.StackSize, item.components.stackable)
		if ok and type(size) == "number" then
			return size
		end
	end
	return 1
end

-- Counts how many items across these containers a slot-count loop would miss.
-- Used only to decide whether the robust scan is worth substituting.
function Slots.CountItems(containers)
	local total = 0

	for _, container in ipairs(containers or {}) do
		if container ~= nil and container.IsValid ~= nil and container:IsValid() then
			for _, item in pairs(Slots.Read(container)) do
				if item ~= nil and item.IsValid ~= nil and item:IsValid() then
					total = total + 1
				end
			end
		end
	end

	return total
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Substituting a robust scan when the ordinary one comes back empty
-- ═══════════════════════════════════════════════════════════════════════════

-- Same shape ScanIngredients produces:
--   pool[prefab] = { total = N, locations = { {container=, slot=, count=}, ... } }
local function BuildPool(containers)
	local pool = {}

	local tuning    = Core.host.tuning
	local blacklist = (tuning ~= nil and tuning.COOK_INGREDIENT_BLACKLIST) or {}

	for _, container in ipairs(containers or {}) do
		if container ~= nil and container.IsValid ~= nil and container:IsValid() then
			for slot, item in pairs(Slots.Read(container)) do
				if item ~= nil and item.IsValid ~= nil and item:IsValid()
					and not blacklist[item.prefab]
					and cooking.IsCookingIngredient(item.prefab) then

					local count = Slots.StackSize(item)

					if pool[item.prefab] == nil then
						pool[item.prefab] = { total = 0, locations = {} }
					end

					pool[item.prefab].total = pool[item.prefab].total + count
					table.insert(pool[item.prefab].locations,
						{ container = container, slot = slot, count = count })
				end
			end
		end
	end

	return pool
end

local function CountDishes(containers)
	local counts  = {}
	local recipes = Core.host.recipes

	for _, container in ipairs(containers or {}) do
		if container ~= nil and container.IsValid ~= nil and container:IsValid() then
			for _, item in pairs(Slots.Read(container)) do
				if item ~= nil and item.IsValid ~= nil and item:IsValid() then
					local is_dish = item.HasTag ~= nil and item:HasTag("preparedfood")

					if not is_dish and recipes ~= nil and type(recipes.GetRecipeByName) == "function" then
						local ok, card = pcall(recipes.GetRecipeByName, item.prefab)
						is_dish = ok and card ~= nil
					end

					if is_dish then
						counts[item.prefab] = (counts[item.prefab] or 0) + Slots.StackSize(item)
					end
				end
			end
		end
	end

	return counts
end

local function IsEmpty(t)
	return next(t or {}) == nil
end

-- Wraps NPC Friends' two container readers. The originals are left in charge;
-- we only step in when they come back empty and a slot-count-free read finds
-- something, which is exactly the closed-modded-chest case.
function Slots.Attach(CookingPlanner)
	if CookingPlanner == nil or CookingPlanner._hofnpc_slots_attached then
		return false
	end

	local scan = CookingPlanner.ScanIngredients
	if type(scan) == "function" then
		CookingPlanner.ScanIngredients = function(containers)
			local pool = scan(containers)

			if IsEmpty(pool) then
				local ok, robust = pcall(BuildPool, containers)
				if ok and not IsEmpty(robust) then
					local kinds = 0
					for _ in pairs(robust) do kinds = kinds + 1 end
					Core.Info(string.format(
						"닫힌 상자 안을 다시 읽어 재료 %d종을 찾았습니다 / recovered %d ingredient types from containers that reported themselves empty",
						kinds, kinds))
					return robust
				end
			end

			return pool
		end
	end

	local count = CookingPlanner.CountExistingDishes
	if type(count) == "function" then
		CookingPlanner.CountExistingDishes = function(containers)
			local counts = count(containers)

			if IsEmpty(counts) then
				local ok, robust = pcall(CountDishes, containers)
				if ok and not IsEmpty(robust) then
					return robust
				end
			end

			return counts
		end
	end

	CookingPlanner._hofnpc_slots_attached = true
	return true
end

return Slots
