-- ═══════════════════════════════════════════════════════════════════════════
--  설치 / Install
-- ═══════════════════════════════════════════════════════════════════════════
--
--  npc_cooking_planner.lua 마지막의 아래 한 줄이 이 함수를 부릅니다.
--      pcall(function() require("npc/npc_hof_cooking").Install(CookingPlanner) end)
--
--  This is called by the single line appended to npc_cooking_planner.lua.

local function SafeRequire(name)
	local ok, mod = pcall(require, name)
	if ok and type(mod) == "table" then
		return mod
	end
	return nil
end

local Install = {}

Install.applied  = false
Install.disabled = false

local ERROR_LIMIT = 3
local errors      = 0

function Install.Install(CookingPlanner)
	if Install.applied then
		return true
	end

	if CookingPlanner == nil or type(CookingPlanner.FindBestRecipe) ~= "function" then
		Core.Err("CookingPlanner.FindBestRecipe 를 찾지 못했습니다 / not found -- nothing changed")
		return false
	end

	Core.Configure(USER_SETTINGS)

	Core.SetHost
	{
		planner = CookingPlanner,
		recipes = SafeRequire("npc/npc_cooking_recipes"),
		tuning  = SafeRequire("npc_tuning"),
	}

	local original = CookingPlanner.FindBestRecipe

	CookingPlanner.FindBestRecipe = function(pool, existing_dishes, is_warly, cooker_name)
		local function Original()
			return original(pool, existing_dishes, is_warly, cooker_name)
		end

		if Install.disabled or not Core.cfg.enabled then
			return Original()
		end

		local ok, chosen = pcall(Search.Choose, pool, existing_dishes, is_warly, cooker_name)

		if not ok then
			errors = errors + 1
			Core.Err("레시피 탐색 실패 / recipe search failed:", tostring(chosen))

			if errors >= ERROR_LIMIT then
				Install.disabled = true
				Core.Err("오류가 반복되어 패치를 끕니다. 원래 로직으로 동작합니다. / "
					.. "too many errors, falling back to the original logic permanently")
			end

			return Original()
		end

		-- 만들 수 있는 요리가 없으면(창고가 비었거나 전부 상한선 도달) 원래 로직에 맡깁니다.
		if chosen == nil then
			return Original()
		end

		return chosen
	end

	Install.applied = true

	Core.Info(string.format(
		"적용 완료 / patched -- variety=%s, search=%s. 모드 요리 전체를 만들 수 있습니다.",
		tostring(Core.cfg.variety), tostring(Core.cfg.budget)))

	return true
end

return Install
