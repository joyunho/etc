-- test_cookware.lua
--
-- The station chooser: which thing the chef walks to with four ingredients.
--
--   lua5.1 tests/test_cookware.lua
--
-- The slot counts below are DST's own (scripts/containers.lua): a Crock Pot,
-- a Portable Crock Pot and an Archive Crock Pot have four slots, and Warly's
-- Portable Seasoning Station has two -- one for a cooked dish, one for a spice.
-- tests/test_realmods.lua checks those numbers against the real file when the
-- game is installed; this file is the logic.

local here = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = here .. "/?.lua;" .. here .. "/../npcfriends_hof_cooking/scripts/?.lua;" .. package.path

local Stub = require("dst_stub")
Stub.Register()

local Core     = require("hofnpc_core")
local Cookware = require("hofnpc_cookware")

local failures = 0
local function check(label, ok, detail)
	if ok then
		print("  PASS  " .. label)
	else
		failures = failures + 1
		print("  FAIL  " .. label .. (detail and ("  -- " .. detail) or ""))
	end
end

local guid = 0

local function Station(prefab, slots, state)
	guid = guid + 1
	local cooking, done = state == "cooking", state == "done"

	return
	{
		prefab  = prefab,
		GUID    = guid,
		IsValid = function() return true end,
		components =
		{
			stewer =
			{
				IsCooking = function() return cooking end,
				IsDone    = function() return done end,
			},
			container = slots ~= nil and
			{
				numslots    = slots,
				GetNumSlots = function(self) return self.numslots end,
			} or nil,
		},
	}
end

local function CookPot(state)  return Station("cookpot", 4, state) end
local function Portable(state) return Station("portablecookpot", 4, state) end
local function Archive(state)  return Station("archive_cookpot", 4, state) end
local function Spicer(state)   return Station("portablespicer", 2, state) end

Core.Configure({ enabled = true, spread_cookware = true, debug = false })

-- ═══════════════════════════════════════════════════════════════════════════
print("=== 1. the seasoning station is never cooked in ===")

Cookware.Reset()
local only_spicer = { Spicer("idle") }
check("a lone seasoning station is refused, not walked to",
	Cookware.FindAvailableCookpot(only_spicer) == nil)

Cookware.Reset()
-- The order that breaks NPC Friends' own chooser: the station it would take
-- first is the one that cannot hold the dish.
local spicer_first = { Spicer("idle"), CookPot("idle") }
local picked = Cookware.FindAvailableCookpot(spicer_first)
check("a seasoning station listed before the pot is skipped",
	picked ~= nil and picked.prefab == "cookpot",
	picked and picked.prefab or "nil")

Cookware.Reset()
check("... and a busy pot does not send the chef to the spicer instead",
	Cookware.FindAvailableCookpot({ Spicer("idle"), CookPot("cooking") }) == nil)

-- ═══════════════════════════════════════════════════════════════════════════
print("")
print("=== 2. four-slot stations are all fair game ===")

Cookware.Reset()
for _, station in ipairs({ CookPot("idle"), Portable("idle"), Archive("idle") }) do
	check(station.prefab .. " can take a four-ingredient dish", Cookware.CanTakeLoad(station))
end
check("portablespicer cannot", not Cookware.CanTakeLoad(Spicer("idle")))

-- A modded cooker we cannot read must be left exactly as it was.
local unreadable = Station("some_mod_pot", nil, "idle")
check("a station whose slots we cannot read is still used", Cookware.CanTakeLoad(unreadable))
Cookware.Reset()
check("... and is actually returned",
	Cookware.FindAvailableCookpot({ unreadable }) ~= nil)

-- ═══════════════════════════════════════════════════════════════════════════
print("")
print("=== 3. several pots get used, not the same one ===")

Cookware.Reset()
local three = { CookPot("idle"), Portable("idle"), Archive("idle") }
local seen, order = {}, {}
for _ = 1, 6 do
	local pot = Cookware.FindAvailableCookpot(three)
	seen[pot.GUID] = (seen[pot.GUID] or 0) + 1
	order[#order + 1] = pot.prefab
end

local distinct = 0
for _ in pairs(seen) do distinct = distinct + 1 end
check("three idle pots are all used", distinct == 3, "used " .. distinct)

local even = true
for _, n in pairs(seen) do
	if n ~= 2 then even = false end
end
check("and used evenly", even, table.concat(order, " -> "))

-- Rotation is per set of stations: a second chef at another base keeps its own
-- place, and neither knocks the other off its pot.
Cookware.Reset()
local base_a = { CookPot("idle"), Portable("idle") }
local base_b = { Archive("idle"), Archive("idle") }
local a1 = Cookware.FindAvailableCookpot(base_a)
local b1 = Cookware.FindAvailableCookpot(base_b)
local a2 = Cookware.FindAvailableCookpot(base_a)
check("two bases rotate independently",
	a1.GUID ~= a2.GUID and b1 ~= nil)

-- ═══════════════════════════════════════════════════════════════════════════
print("")
print("=== 4. busy and finished pots ===")

Cookware.Reset()
local busy_then_idle = { CookPot("cooking"), Portable("idle") }
check("a pot that is already cooking is passed over",
	Cookware.FindAvailableCookpot(busy_then_idle).prefab == "portablecookpot")

Cookware.Reset()
-- NPC Friends falls back to a finished pot so the chef goes and empties it.
-- That has to survive, or dishes sit in pots forever.
local done_only = { CookPot("done") }
check("a finished pot is still offered when nothing is idle",
	Cookware.FindAvailableCookpot(done_only) ~= nil)

Cookware.Reset()
check("an idle pot beats a finished one",
	Cookware.FindAvailableCookpot({ CookPot("done"), Portable("idle") }).prefab == "portablecookpot")

Cookware.Reset()
check("nothing at all means nothing", Cookware.FindAvailableCookpot({}) == nil)
check("and a nil list does not blow up", Cookware.FindAvailableCookpot(nil) == nil)

-- ═══════════════════════════════════════════════════════════════════════════
print("")
print("=== 5. it goes through the planner, and can be turned off ===")

local planner =
{
	FindAvailableCookpot = function(cookpots)
		-- NPC Friends' own: first station with a stewer, spicer or not.
		for _, pot in ipairs(cookpots) do
			if pot.components.stewer and not pot.components.stewer:IsCooking()
				and not pot.components.stewer:IsDone() then
				return pot
			end
		end
		return nil
	end,
}

Cookware.original = nil
check("Attach swaps the chooser in", Cookware.Attach(planner) == true)
check("Attach a second time is refused", Cookware.Attach(planner) == false)

Cookware.Reset()
local through = planner.FindAvailableCookpot({ Spicer("idle"), CookPot("idle") })
check("the planner now skips the seasoning station",
	through ~= nil and through.prefab == "cookpot",
	through and through.prefab or "nil")

Core.Configure({ spread_cookware = false })
local off = planner.FindAvailableCookpot({ Spicer("idle"), CookPot("idle") })
check("turning it off gives NPC Friends' behaviour back, spicer and all",
	off ~= nil and off.prefab == "portablespicer",
	off and off.prefab or "nil")

Core.Configure({ spread_cookware = true, enabled = false })
local disabled = planner.FindAvailableCookpot({ Spicer("idle"), CookPot("idle") })
check("so does disabling the patch outright",
	disabled ~= nil and disabled.prefab == "portablespicer")

Core.Configure({ enabled = true })

print("")
print("=== 6. Heap of Foods' own cookware ===")

-- Its grills, ovens and pot hangers carry `cookwarestewer`, not `stewer`, and
-- NPC Friends collects stations with FindEntities(..., {"stewer"}). So a base
-- lined with them looked, to the chef, like a base with no pots in it at all.
--
-- CookwareStewer is stewer-shaped already, so it can stand in for one. What it
-- must not do is take up residence on the real entity under the name `stewer`:
-- EntityScript's GetPersistData walks pairs(self.components) and calls OnSave
-- on each, so a component parked there would reach the save file.

local world = {}
_G.TheSim =
{
	FindEntities = function(_, _, _, _, _, _, _, musttags)
		local want = (musttags or {})[1]
		local out = {}
		for _, ent in ipairs(world) do
			if want == nil or ent:HasTag(want) then
				out[#out + 1] = ent
			end
		end
		return out
	end,
}

local function HofCookware(prefab, slots, state)
	guid = guid + 1
	local cooking, done = state == "cooking", state == "done"
	local harvested = false

	return
	{
		prefab      = prefab,
		GUID        = guid,
		IsValid     = function() return true end,
		GetPosition = function() return { x = 0, y = 0, z = 0 } end,
		HasTag      = function(_, tag) return tag == "cookwarestewer" end,
		components  =
		{
			cookwarestewer =
			{
				IsCooking    = function() return cooking end,
				IsDone       = function() return done end,
				CanCook      = function() return true end,
				StartCooking = function() cooking = true return true end,
				Harvest      = function() harvested = true done = false return true end,
			},
			container =
			{
				numslots    = slots,
				GetNumSlots = function(self) return self.numslots end,
			},
		},
		Harvested = function() return harvested end,
	}
end

local chef = { GetPosition = function() return { x = 0, y = 0, z = 0 } end }

do
	local grill = HofCookware("kyno_cookware_grill", 4)
	local small = HofCookware("kyno_cookware_small_grill", 3)
	world = { grill, small }

	local near = Cookware.Nearby(chef)

	check("the four-slot cookware is found", #near == 1, tostring(#near))
	check("and it is the grill, not the three-slot one",
		near[1] ~= nil and near[1].prefab == "kyno_cookware_grill",
		near[1] and near[1].prefab or "nil")

	local proxy = near[1]
	check("the chef is handed a stewer", proxy.components.stewer == grill.components.cookwarestewer)
	check("the real entity never grows one", grill.components.stewer == nil)
	check("the stand-in is recognised as one", Cookware.IsProxy(proxy))
	check("a plain pot is not", not Cookware.IsProxy(CookPot()))
	check("asking twice gives the same stand-in", Cookware.Proxy(grill) == proxy)

	check("it is offered as somewhere to cook", Cookware.FindAvailableCookpot({ proxy }) == proxy)

	proxy.components.stewer:StartCooking()
	check("a busy one is passed over", Cookware.FindAvailableCookpot({ proxy }) == nil)
end

do
	-- the behaviour's own station list is what the harvest step walks, so the
	-- cookware has to arrive there and not merely in the chooser
	local grill = HofCookware("kyno_cookware_oven_casserole", 4)
	world = { grill }

	local asked
	_G.NPCCookingBehavior =
	{
		_GetCookpots = function(self) asked = self return { CookPot() } end,
	}

	Cookware.behaviour_attached = false
	check("it hangs itself on the behaviour's list", Cookware.AttachBehaviour())
	check("a second time is refused", Cookware.AttachBehaviour())

	local pots = NPCCookingBehavior._GetCookpots({ inst = chef })
	check("their pots are still there", pots[1] ~= nil and pots[1].prefab == "cookpot")
	check("and the cookware is now with them",
		pots[2] ~= nil and pots[2].prefab == "kyno_cookware_oven_casserole", tostring(#pots))
	check("the same cookware is not added twice",
		#NPCCookingBehavior._GetCookpots({ inst = chef }) == 2)

	Core.Configure({ enabled = true, use_cookware = false, debug = false })
	check("switching it off leaves their list alone",
		#NPCCookingBehavior._GetCookpots({ inst = chef }) == 1)
	Core.Configure({ enabled = true, use_cookware = true, spread_cookware = true, debug = false })
end

print("")
if failures == 0 then
	print("ALL CHECKS PASSED")
	os.exit(0)
else
	print(failures .. " CHECK(S) FAILED")
	os.exit(1)
end
