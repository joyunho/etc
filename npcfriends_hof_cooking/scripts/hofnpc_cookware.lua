-- hofnpc_cookware.lua
-- Which cooking station the chef walks to.
--
-- NPC Friends collects stations with
--     TheSim:FindEntities(centre.x, 0, centre.z, radius, {"stewer"})
-- and the "stewer" tag is added by the stewer component itself
-- (scripts/components/stewer.lua), so that list is everything in reach that
-- cooks -- which includes Warly's Portable Seasoning Station.
--
-- The seasoning station has two slots, and its container takes a cooked dish in
-- the first and a spice in the second (scripts/containers.lua,
-- params.portablespicer.itemtestfn). It will not accept a raw ingredient at
-- all. The chef, meanwhile, only ever plans a four-ingredient Crock Pot dish,
-- and its behaviour gives up unless it is carrying four items when it reaches
-- the station.
--
-- So a chef that picks the seasoning station walks over with four raw
-- ingredients, cannot place a single one, and the cook fails. Put one next to
-- the pot -- which is exactly where a Warly player puts it -- and the chef
-- stalls on it instead of cooking.
--
-- This module replaces the station chooser with one that
--   1. skips any station that cannot take a four-ingredient load, and
--   2. rotates through the ones that can, so several pots get used rather than
--      the first one in the list every time.
--
-- Harvesting is untouched: the behaviour's pre-harvest step walks the station
-- list itself rather than going through this function, so a finished seasoning
-- station still gets emptied.

local Core  = require("hofnpc_core")
local Stations = require("hofnpc_stations")

local Cookware = {}

local POT_SLOTS = 4

Cookware.original = nil

-- Where the next search starts, per set of stations. Keyed by the stations
-- themselves so two chefs at two bases keep their own place in the rotation.
Cookware._turn = {}

function Cookware.Reset()
	Cookware._turn = {}
end

-- How many slots a station has, or nil when we cannot tell. nil means "leave it
-- alone": we only ever exclude a station on positive evidence, so a modded
-- cooker we cannot read is still used exactly as it was before.
function Cookware.Slots(pot)
	local components = pot ~= nil and pot.components or nil
	local container  = components ~= nil and components.container or nil

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

function Cookware.CanTakeLoad(pot)
	local slots = Cookware.Slots(pot)
	return slots == nil or slots >= POT_SLOTS
end

local function Usable(pot)
	return pot ~= nil
		and pot.IsValid ~= nil
		and pot:IsValid()
		and pot.components ~= nil
		and pot.components.stewer ~= nil
end

local function TurnKey(pots)
	local ids = {}
	for _, pot in ipairs(pots) do
		ids[#ids + 1] = tostring(pot.GUID or pot)
	end
	table.sort(ids)
	return table.concat(ids, ",")
end

-- Same two tiers as NPC Friends' own chooser -- an idle station first, a
-- finished one second -- but starting from wherever the last pass stopped.
local function PickFrom(pots, key, want_done)
	local n = #pots
	if n == 0 then
		return nil
	end

	local start = Cookware._turn[key] or 0

	for step = 1, n do
		local index = ((start + step - 1) % n) + 1
		local pot   = pots[index]
		local stew  = pot.components.stewer

		local done = stew:IsDone()
		local idle = not stew:IsCooking() and not done

		if (want_done and done) or (not want_done and idle) then
			Cookware._turn[key] = index
			return pot
		end
	end

	return nil
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Heap of Foods' own cookware
-- ═══════════════════════════════════════════════════════════════════════════
--
-- A grill, an oven, a pot hanger. They cook exactly what a Crock Pot cooks --
-- hof_cooking.lua registers the common, seasonal and item recipes on every one
-- of them -- so they add throughput and a kitchen that looks like a kitchen,
-- not new dishes.
--
-- The chef never saw them. They carry `cookwarestewer`, and NPC Friends
-- collects stations with FindEntities(..., {"stewer"}), a tag only the vanilla
-- stewer component adds. So a base lined with HoF cookware looked, to the chef,
-- like a base with no pots in it at all.
--
-- CookwareStewer is stewer-shaped already: IsCooking, IsDone, CanCook (its own
-- container:IsFull), StartCooking(doer), Harvest(harvester). So the component
-- itself can stand in for a stewer with no translation. What must not happen is
-- putting it on the real entity under the name `stewer`: EntityScript's
-- GetPersistData walks pairs(self.components) and calls OnSave on each, so a
-- component parked there reaches the save file and every other mod. The chef
-- gets a stand-in table instead, and the real entity keeps its own shape.
--
-- Only the four-slot cookware is offered. The small variants hold three, and a
-- chef that plans four ingredients can never fill them -- the same trap the
-- seasoning station sets, and skipped for the same reason.

local COOKWARE_RADIUS = 17

Cookware._proxies = setmetatable({}, { __mode = "k" })

function Cookware.IsCookware(ent)
	return ent ~= nil
		and ent.components ~= nil
		and ent.components.cookwarestewer ~= nil
end

function Cookware.Proxy(machine)
	local cached = Cookware._proxies[machine]
	if cached ~= nil then
		return cached
	end

	local proxy =
	{
		prefab    = machine.prefab,
		GUID      = machine.GUID,
		Transform = machine.Transform,

		components =
		{
			stewer    = machine.components.cookwarestewer,
			container = machine.components.container,
		},

		IsValid     = function() return machine:IsValid() end,
		GetPosition = function() return machine:GetPosition() end,
		HasTag      = function(_, tag) return machine:HasTag(tag) end,

		_hofnpc_cookware = machine,
	}

	Cookware._proxies[machine] = proxy
	return proxy
end

function Cookware.IsProxy(ent)
	return ent ~= nil and ent._hofnpc_cookware ~= nil
end

-- Everything with a cookwarestewer within reach of the chef, as stand-ins.
function Cookware.Nearby(inst)
	local out = {}

	if not Core.cfg.use_cookware or inst == nil or rawget(_G, "TheSim") == nil then
		return out
	end

	local centre, x, z = inst._cooking_center, nil, nil

	if type(centre) == "table" and centre.x ~= nil then
		x, z = centre.x, centre.z
	elseif type(inst.GetPosition) == "function" then
		local pos = inst:GetPosition()
		x, z = pos.x, pos.z
	else
		return out
	end

	local ok, found = pcall(function()
		return TheSim:FindEntities(x, 0, z, COOKWARE_RADIUS, nil,
			{ "INLIMBO", "burnt" }, { "cookwarestewer" })
	end)

	if not ok or type(found) ~= "table" then
		return out
	end

	for _, ent in ipairs(found) do
		if ent:IsValid() and Cookware.IsCookware(ent) then
			local proxy = Cookware.Proxy(ent)
			if proxy ~= nil and Cookware.CanTakeLoad(proxy) then
				out[#out + 1] = proxy
			end
		end
	end

	return out
end

function Cookware.FindAvailableCookpot(cookpots)
	-- A seasoning station or a drying rack is normally kept out of the chef's
	-- way, because its own behaviour cannot load either. When hofnpc_stations
	-- has a job lined up it can, so hand the machine over.
	local job = Stations.Wanted() and Stations.pending or nil

	if job ~= nil then
		local kind = job.kind or "spice"

		for _, pot in ipairs(cookpots or {}) do
			local right = (kind == "spice")
				and Stations.IsStation(pot)
				or (Stations.ProxyKind(pot) == kind)

			if Usable(pot) and right then
				local stewer = pot.components.stewer
				if not stewer:IsCooking() and not stewer:IsDone() then
					Core.Log(kind, "at", tostring(pot.prefab))
					Stations.Claim(job)
					return pot
				end
			end
		end
	end

	local usable, skipped = {}, 0

	for _, pot in ipairs(cookpots or {}) do
		-- Machines only hofnpc_stations can work are never ordinary pots, and a
		-- drying rack has no container at all, so the slot test would wave it
		-- through as if it were one.
		if Usable(pot) and not Stations.IsSideStation(pot) then
			if Cookware.CanTakeLoad(pot) then
				usable[#usable + 1] = pot
			else
				skipped = skipped + 1
			end
		end
	end

	if skipped > 0 then
		Core.Log(string.format("skipped %d station(s) too small for a %d-ingredient dish",
			skipped, POT_SLOTS))
	end

	if #usable == 0 then
		-- Nothing we can cook in. Say so once rather than letting the chef look
		-- like it is idling for no reason.
		if skipped > 0 then
			Core.Log("every station in reach is too small -- a seasoning station cannot take raw ingredients")
		end
		return nil
	end

	local key = TurnKey(usable)

	local pot = PickFrom(usable, key, false) or PickFrom(usable, key, true)

	if pot ~= nil then
		Core.Log("cooking at", tostring(pot.prefab))
	end

	return pot
end

-- The cookware has to reach the behaviour's own station list, not just the
-- chooser: the pre-harvest step walks that list itself, so a pot added anywhere
-- else would be cooked in and then never emptied.
--
-- hofnpc_stations wraps the same method for its racks and kegs. This wrapper
-- goes on top of that one rather than inside it, because the merged file is one
-- chunk in module order and stations is written before cookware.
Cookware.behaviour_attached = false

function Cookware.AttachBehaviour()
	if Cookware.behaviour_attached then
		return true
	end

	local class = rawget(_G, "NPCCookingBehavior")
	if class == nil or type(class._GetCookpots) ~= "function" then
		return false
	end

	local original = class._GetCookpots

	class._GetCookpots = function(self)
		local pots = original(self) or {}

		if Core.cfg.enabled and Core.cfg.use_cookware then
			pcall(function()
				local seen = {}
				for _, pot in ipairs(pots) do
					local real = Cookware.IsProxy(pot) and pot._hofnpc_cookware or pot
					seen[real] = true
				end

				for _, proxy in ipairs(Cookware.Nearby(self.inst)) do
					if not seen[proxy._hofnpc_cookware] then
						seen[proxy._hofnpc_cookware] = true
						pots[#pots + 1] = proxy
					end
				end
			end)
		end

		return pots
	end

	Cookware.behaviour_attached = true
	return true
end

-- Swap ours in, keeping theirs so `enabled = false` still gives their behaviour.
function Cookware.Attach(planner)
	if planner == nil or Cookware.original ~= nil then
		return false
	end

	if type(planner.FindAvailableCookpot) ~= "function" then
		return false
	end

	Cookware.original = planner.FindAvailableCookpot

	planner.FindAvailableCookpot = function(cookpots)
		if not Core.cfg.enabled or not Core.cfg.spread_cookware then
			return Cookware.original(cookpots)
		end

		local ok, pot = pcall(Cookware.FindAvailableCookpot, cookpots)
		if not ok then
			Core.Err("choosing a station failed:", tostring(pot))
			return Cookware.original(cookpots)
		end

		return pot
	end

	return true
end

return Cookware
