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
local Spice = require("hofnpc_spice")

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

function Cookware.FindAvailableCookpot(cookpots)
	-- A seasoning station is normally excluded, because the chef cannot load
	-- one. When hofnpc_spice has a job lined up it can, so hand it over.
	if Spice.Wanted() then
		for _, pot in ipairs(cookpots or {}) do
			if Usable(pot) and Spice.IsStation(pot) then
				local stewer = pot.components.stewer
				if not stewer:IsCooking() and not stewer:IsDone() then
					Core.Log("spicing at", tostring(pot.prefab))
					Spice.Claim(Spice.pending)
					return pot
				end
			end
		end
	end

	local usable, skipped = {}, 0

	for _, pot in ipairs(cookpots or {}) do
		if Usable(pot) then
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
