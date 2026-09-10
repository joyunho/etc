-- hofnpc_patch.lua
-- Finds NPC Friends' cooking modules at runtime and swaps in our recipe
-- chooser.
--
-- Why it is done this way:
--
--  * NPC Friends ships its behaviour files obfuscated, but the modules those
--    files call into -- npc/npc_cooking_planner, npc/npc_cooking_recipes and
--    npc_tuning -- are plain Lua tables. The obfuscated code looks its
--    functions up on those tables at call time, so replacing a field on the
--    table is enough. We never touch, unpack or ship any of their code.
--
--  * Those modules are require()d lazily, when the first NPC spawns and its
--    brain is built -- not during modmain. So we hook the npcfriend prefab and
--    look the modules up out of package.loaded once they exist.

local Core    = require("hofnpc_core")
local Search  = require("hofnpc_search")
local Variety = require("hofnpc_variety")

local Patch = {}

Patch.applied  = false
Patch.disabled = false

Patch._polling = false
Patch._task    = nil
Patch._tries   = 0
Patch._errors  = 0
Patch._orig    = nil

local POLL_PERIOD  = 3
local POLL_MAX     = 100  -- ~5 minutes
local ERROR_LIMIT  = 3

local MODULE_PLANNER = "npc/npc_cooking_planner"
local MODULE_RECIPES = "npc/npc_cooking_recipes"
local MODULE_TUNING  = "npc_tuning"

-- ═══════════════════════════════════════════════════════════════════════════
--  Module lookup
-- ═══════════════════════════════════════════════════════════════════════════

local function GetLoadedModule(name)
	local pkg = rawget(_G, "package")
	if pkg == nil or pkg.loaded == nil then
		return nil
	end

	local mod = rawget(pkg.loaded, name)
	if type(mod) == "table" then
		return mod
	end

	return nil
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Applying the patch
-- ═══════════════════════════════════════════════════════════════════════════

function Patch.TryApply()
	if Patch.applied then
		return true
	end

	local planner = GetLoadedModule(MODULE_PLANNER)
	if planner == nil or type(planner.FindBestRecipe) ~= "function" then
		return false
	end

	Core.SetHost(
	{
		planner = planner,
		recipes = GetLoadedModule(MODULE_RECIPES),
		tuning  = GetLoadedModule(MODULE_TUNING),
	})

	Patch._orig = planner.FindBestRecipe

	planner.FindBestRecipe = function(pool, existing_dishes, is_warly, cooker_name)
		local function Original()
			return Patch._orig(pool, existing_dishes, is_warly, cooker_name)
		end

		if Patch.disabled or not Core.cfg.enabled then
			return Original()
		end

		local ok, chosen = pcall(Search.Choose, pool, existing_dishes, is_warly, cooker_name)

		if not ok then
			Patch._errors = Patch._errors + 1
			Core.Err("recipe search failed:", tostring(chosen))

			if Patch._errors >= ERROR_LIMIT then
				Patch.disabled = true
				Core.Err(string.format(
					"disabling the patch after %d errors -- NPC Friends' own cooking logic will be used from now on",
					ERROR_LIMIT))
			end

			return Original()
		end

		if chosen == nil then
			-- Nothing cookable was found (empty pantry, everything already
			-- stocked, every candidate filtered out). Let NPC Friends try.
			return Original()
		end

		return chosen
	end

	Patch.applied = true

	Core.Info(string.format(
		"patched NPC Friends' recipe chooser (variety=%s, search=%s) -- the chef can now cook every modded Crock Pot dish",
		tostring(Core.cfg.variety), tostring(Core.cfg.budget)))

	return true
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Scheduling
-- ═══════════════════════════════════════════════════════════════════════════

local function StopPolling()
	if Patch._task ~= nil then
		Patch._task:Cancel()
		Patch._task = nil
	end
	Patch._polling = false
end

-- Called when an npcfriend entity appears, i.e. when NPC Friends is definitely
-- installed. Usually succeeds on the first try, because building the NPC's
-- brain is what loads the cooking modules in the first place.
function Patch.Start()
	if Patch.applied or Patch._polling then
		return
	end

	if Patch.TryApply() then
		return
	end

	local world = rawget(_G, "TheWorld")
	if world == nil then
		return
	end

	Patch._polling = true
	Patch._tries   = 0

	Patch._task = world:DoPeriodicTask(POLL_PERIOD, function()
		Patch._tries = Patch._tries + 1

		if Patch.TryApply() then
			StopPolling()
			return
		end

		if Patch._tries >= POLL_MAX then
			StopPolling()
			Core.Info("could not find NPC Friends' cooking modules -- nothing was changed")
		end
	end)
end

-- A fresh world means a fresh pantry and a fresh cooking history.
function Patch.OnWorldStart()
	Search.ResetCache()
	Variety.Reset()
	Core.ClearScoreCache()
end

return Patch
