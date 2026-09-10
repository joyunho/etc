-- hofnpc_diag.lua
--
-- 왈리 NPC 가 "요리를 못 하겠다"고 할 때, 왜 못 하는지 말해 주는 진단기.
--
-- Explains why the chef gave up. NPC Friends' PlanCooking bails out at five
-- different points and says nothing useful about which one, so a player with a
-- full pantry has no way to tell "the chef cannot see your chests" from "the
-- chest contents are not cooking ingredients" from "the pot is busy".
--
-- Only speaks when planning actually failed, and at most once per interval, so
-- it costs nothing in the normal case.

local cooking = require("cooking")

local Core  = require("hofnpc_core")
local Slots = require("hofnpc_slots")

local Diag = {}

local REPORT_INTERVAL = 60      -- 초. 같은 이야기를 반복하지 않기 위한 간격
local MAX_LISTED      = 6       -- 로그에 나열할 컨테이너 / 아이템 수

local last_report = {}

local function Now()
	local ok, t = pcall(GetTime)
	if ok and type(t) == "number" then
		return t
	end
	return 0
end

local function ShouldReport(key)
	local now  = Now()
	local last = last_report[key]

	if last ~= nil and now - last < REPORT_INTERVAL then
		return false
	end

	last_report[key] = now
	return true
end

local function CountFreeSlots(inst)
	local inv = inst and inst.components and inst.components.inventory
	if inv == nil then
		return nil
	end

	local free = 0
	for i = 1, inv.maxslots do
		if inv:GetItemInSlot(i) == nil then
			free = free + 1
		end
	end
	return free
end

local function DescribeCookpots(cookpots)
	if cookpots == nil or #cookpots == 0 then
		return 0, "없음 / none in range"
	end

	local idle, busy, done = 0, 0, 0
	for _, pot in ipairs(cookpots) do
		if pot ~= nil and pot:IsValid() and pot.components.stewer ~= nil then
			local stewer = pot.components.stewer
			if stewer:IsCooking() then
				busy = busy + 1
			elseif stewer:IsDone() then
				done = done + 1
			else
				idle = idle + 1
			end
		end
	end

	return #cookpots, string.format("비어있음 %d / 조리중 %d / 완성대기 %d", idle, busy, done)
end

-- Walks the containers the chef was actually handed and reports, per container,
-- how many of its items the game accepts as cooking ingredients.
local function DescribeContainers(containers)
	local listed, ingredient_kinds, rejected = {}, {}, {}
	local total_items = 0

	for _, container in ipairs(containers or {}) do
		if container ~= nil and container:IsValid() and container.components.container ~= nil then
			local usable = 0

			-- Slots.Read, not a GetNumSlots loop: a closed modded chest reports
			-- zero slots and would otherwise be counted as empty.
			for _, item in pairs(Slots.Read(container)) do
				if item ~= nil and item:IsValid() then
					total_items = total_items + 1
					if cooking.IsCookingIngredient(item.prefab) then
						usable = usable + 1
						ingredient_kinds[item.prefab] = true
					elseif #rejected < MAX_LISTED and not rejected[item.prefab] then
						rejected[#rejected + 1] = item.prefab
						rejected[item.prefab] = true
					end
				end
			end

			if #listed < MAX_LISTED then
				listed[#listed + 1] = string.format("%s(재료 %d)", tostring(container.prefab), usable)
			end
		end
	end

	local kinds = 0
	for _ in pairs(ingredient_kinds) do
		kinds = kinds + 1
	end

	return kinds, total_items, table.concat(listed, ", "), table.concat(rejected, ", ")
end

-- 로그만 보면 못 보시는 분이 많으니, 왈리가 직접 말하게 합니다.
local function Say(inst, text)
	if inst == nil or inst.components == nil or inst.components.talker == nil then
		return
	end
	pcall(function() inst.components.talker:Say(text) end)
end

-- Called when PlanCooking returned nil. Works out which of its five bail-outs
-- fired and prints something a player can act on.
function Diag.ExplainFailure(inst, containers, cookpots, is_warly)
	if not ShouldReport(inst ~= nil and inst.GUID or "?") then
		return
	end

	local n_containers = containers ~= nil and #containers or 0
	local n_pots, pot_state = DescribeCookpots(cookpots)
	local free_slots = CountFreeSlots(inst)
	local kinds, items, listed, rejected = DescribeContainers(containers)

	Core.Info("―― 왈리가 요리를 못 하는 이유 / why the chef gave up ――")
	Core.Info(string.format("  컨테이너 %d개, 그 안의 물건 %d개, 요리 재료로 인정되는 종류 %d종",
		n_containers, items, kinds))

	if listed ~= "" then
		Core.Info("  본 컨테이너: " .. listed)
	end

	if n_pots == 0 then
		Core.Info("  냄비: " .. pot_state)
		Core.Info("  >> 요리 범위 안에 냄비가 없습니다. 왈리에게 '여기서 요리'를 다시 지정해 보세요.")
		Say(inst, "요리 지점 근처에 냄비가 없어요.")
		return
	end

	Core.Info(string.format("  냄비 %d개 - %s", n_pots, pot_state))

	if free_slots ~= nil and free_slots < 4 then
		Core.Info(string.format("  왈리 가방 빈칸: %d (4칸 필요)", free_slots))
		Core.Info("  >> 왈리 가방이 꽉 찼습니다. 물건을 빼 주세요.")
		Say(inst, "가방이 꽉 차서 재료를 못 들어요.")
		return
	end

	if n_containers == 0 then
		Core.Info("  >> 요리 지점 반경 안에서 상자/아이스박스를 하나도 못 찾았습니다.")
		Core.Info("     왈리는 '여기서 요리'로 지정한 지점 주변만 봅니다. 그 근처에 상자를 두세요.")
		Say(inst, "요리 지점 근처에 상자가 없어요.")
		return
	end

	if kinds == 0 then
		Core.Info("  >> 상자는 찾았지만, 그 안에 요리 재료로 쓸 수 있는 물건이 하나도 없습니다.")
		if rejected ~= "" then
			Core.Info("     재료가 아닌 것으로 판정된 물건: " .. rejected)
		end
		Core.Info("     채소나 고기가 든 상자가 '여기서 요리' 지점 근처에 있는지 확인해 주세요.")
		Core.Info("     왈리가 직접 지은 아이스박스/상자에 재료를 넣어 주는 것이 가장 확실합니다.")
		Say(inst, string.format("상자 %d개를 봤는데 요리 재료가 없어요. 제 상자에 넣어 주세요.", n_containers))
		return
	end

	local total_max = Core.TotalDishMax()
	if total_max ~= nil then
		Core.Info(string.format("  '음식 최대 개수' 설정: %d개", total_max))
		Core.Info("     저장된 요리가 이 개수에 닿으면 왈리는 요리를 아예 멈춥니다.")
		Core.Info("     패널에서 이 값을 올리거나 0(제한 없음)으로 바꿔 보세요.")
		Say(inst, string.format("요리를 %d개까지만 만들라고 하셨어요.", total_max))
		return
	end

	Core.Info(string.format("  >> 재료는 %d종 있는데 만들 수 있는 요리를 못 찾았습니다.", kinds))
	Core.Info("     '같은 요리 최대 개수'가 낮으면 이미 다 채워서 못 만들 수 있습니다. 값을 올려 보세요.")
	Core.Info("     그래도 계속 이러면 USER_SETTINGS 의 budget 을 \"high\" 로 바꿔 보세요.")
	Say(inst, string.format("재료는 %d종 있는데 만들 수 있는 요리가 없어요.", kinds))
end

-- Wraps CookingPlanner.PlanCooking so a nil result explains itself.
function Diag.Attach(CookingPlanner)
	if CookingPlanner == nil or type(CookingPlanner.PlanCooking) ~= "function" then
		return false
	end

	if CookingPlanner._hofnpc_diag_attached then
		return true
	end

	local original = CookingPlanner.PlanCooking

	CookingPlanner.PlanCooking = function(inst, containers, cookpots, is_warly)
		local plan = original(inst, containers, cookpots, is_warly)

		if plan == nil and Core.cfg.explain then
			pcall(Diag.ExplainFailure, inst, containers, cookpots, is_warly)
		end

		return plan
	end

	CookingPlanner._hofnpc_diag_attached = true
	return true
end

return Diag
