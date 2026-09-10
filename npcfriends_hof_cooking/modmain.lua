-- NPC Friends x Heap of Foods -- cooking compatibility patch
--
-- Teaches the NPC Friends chef (Warly) to recognise and cook every Crock Pot
-- dish registered by any food mod -- Heap of Foods above all -- and to rotate
-- through them instead of repeating one dish forever.
--
-- Server side only. Nothing here runs on a client, and no file from either
-- other mod is modified, copied or redistributed.

local G = GLOBAL

-- ═══════════════════════════════════════════════════════════════════════════
--  Configuration
-- ═══════════════════════════════════════════════════════════════════════════

local function Cfg(name, fallback)
	local ok, value = pcall(GetModConfigData, name)
	if ok and value ~= nil then
		return value
	end
	return fallback
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Load our own modules
-- ═══════════════════════════════════════════════════════════════════════════

local ok_core,  Core  = pcall(require, "hofnpc_core")
local ok_patch, Patch = pcall(require, "hofnpc_patch")

if not ok_core or not ok_patch then
	print("[NPCF-HOF] [ERROR] failed to load the patch modules:",
		tostring(ok_core and Patch or Core))
	return
end

Core.Configure(
{
	enabled        = Cfg("enabled", true) ~= false,
	variety        = Cfg("variety", "medium"),
	budget         = Cfg("budget", "medium"),
	same_dish_max  = tonumber(Cfg("same_dish_max", 0)) or 0,
	allow_negative = Cfg("allow_negative", false) == true,
	explain        = Cfg("explain", true) ~= false,
	debug          = Cfg("debug", false) == true,
})

if not Core.cfg.enabled then
	Core.Info("disabled in the mod configuration -- nothing will be changed")
	return
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Hooks
-- ═══════════════════════════════════════════════════════════════════════════

local function IsMasterSim()
	return G.TheWorld ~= nil and G.TheWorld.ismastersim
end

-- NPC Friends spawns every one of its companions from a single "npcfriend"
-- prefab, and building that prefab's brain is what loads the cooking modules
-- we need to patch. So this is both the earliest and the most reliable moment
-- to act -- and it never fires at all if NPC Friends is not installed.
AddPrefabPostInit("npcfriend", function(inst)
	if not IsMasterSim() then
		return
	end

	Patch.Start()
end)

AddSimPostInit(function()
	if not IsMasterSim() then
		return
	end

	-- Fresh world, fresh pantry: drop any cached search results and the
	-- "recently cooked" memory from a previous session.
	Patch.OnWorldStart()

	-- Harmless if the modules are not loaded yet; the prefab hook above will
	-- catch them when the first NPC appears.
	Patch.TryApply()
end)
