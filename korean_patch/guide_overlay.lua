-- ─── [AnL] In-game Guide 본문 한글 덮어쓰기 ────────────────────────────────
--
-- 이 가이드의 120쪽은 글자가 아니라 이미 영어로 그려진 그림입니다.
-- (chasni_guide.lua 가 main_page:SetTexture("images/chasniclient/guide/...") 로
--  통째로 한 장씩 붙입니다.) 그래서 STRINGS 를 바꾸는 방법으로는 닿지 않습니다.
--
-- 대신 영어가 있던 자리에 그 페이지 자신의 색으로 사각형을 덮고, 같은 자리에
-- 한국어를 올립니다. 그림(캐릭터, 몹, 아이콘, 스크린샷)은 건드리지 않습니다.
--
-- 좌표는 1428x894 그림 위의 픽셀입니다. 위젯이 자기 닫기 버튼을 (705, 350) 에
-- 두는 것으로 위젯 단위 1 = 픽셀 1 인 것이 확인되므로, 원점만 가운데로 옮깁니다.
local GUIDE_W, GUIDE_H = 714, 447

local function InstallGuideOverlay()
	local DATA = Module("korean_patch_guide_data")
	if DATA == nil then
		return
	end

	local ok, Guide = pcall(GLOBAL.require, "widgets/chasni_guide")
	if not ok or type(Guide) ~= "table" or type(Guide.RefreshPage) ~= "function" then
		return          -- 가이드 모드가 없거나 모양이 바뀌었습니다
	end

	local Widget = GLOBAL.require("widgets/widget")
	local Image = GLOBAL.require("widgets/image")
	local Text = GLOBAL.require("widgets/text")
	local FONT = GLOBAL.CHATFONT      -- 외곽선 없는 대체글꼴 계열. 한글이 나옵니다.
	local ANCHOR_LEFT, ANCHOR_TOP = GLOBAL.ANCHOR_LEFT, GLOBAL.ANCHOR_TOP

	-- 글이 칸을 넘치면 아래 그림을 밟습니다. 한국어는 Klei 가 자동 축소를
	-- 꺼 두었기 때문에(loc.lua 의 shrink_to_fit_word = false) 직접 줄입니다.
	local function Fit(label, str, w, avail, size)
		for _ = 1, 10 do
			label:SetSize(size)
			label:SetMultilineTruncatedString(str, 40, w, nil, false, false)
			local _, h = label:GetRegionSize()
			if h == nil or h <= avail + 2 or size <= 9 then
				break
			end
			size = size - 1
		end
		label:SetRegionSize(w, avail)
	end

	local function Draw(self)
		local root = self.main_guide and self.main_guide.main_page
		if root == nil then
			return
		end

		if root._korean ~= nil then
			root._korean:Kill()
			root._korean = nil
		end

		local page = DATA[tostring(self.tab_name) .. "_" .. tostring(self.page_id)]
		if page == nil then
			return
		end

		local holder = root:AddChild(Widget("korean_guide"))
		holder:SetPosition(0, 0, 0)
		root._korean = holder

		-- 먼저 영어를 전부 덮고, 그 다음에 글자를 올립니다. 순서가 바뀌면
		-- 사각형이 자기보다 먼저 올라간 글자를 가립니다.
		for _, b in ipairs(page) do
			for _, c in ipairs(b.cover) do
				local box = holder:AddChild(Image("images/global.xml", "square.tex"))
				box:SetSize(c[3] - c[1] + 5, c[4] - c[2] + 5)
				box:SetPosition((c[1] + c[3]) * 0.5 - GUIDE_W,
					GUIDE_H - (c[2] + c[4]) * 0.5, 0)
				box:SetTint(b.bg[1] / 255, b.bg[2] / 255, b.bg[3] / 255, 1)
			end
		end

		for _, b in ipairs(page) do
			if b.ko ~= nil and b.ko ~= "" then
				local label = holder:AddChild(Text(FONT, b.size, "",
					{ b.fg[1] / 255, b.fg[2] / 255, b.fg[3] / 255, 1 }))
				label:SetHAlign(ANCHOR_LEFT)
				label:SetVAlign(ANCHOR_TOP)
				Fit(label, b.ko, b.w, b.avail, b.size)
				label:SetPosition(b.x + b.w * 0.5 - GUIDE_W,
					GUIDE_H - b.y - b.avail * 0.5, 0)
			end
		end
	end

	local original = Guide.RefreshPage
	Guide.RefreshPage = function(self, ...)
		original(self, ...)
		pcall(Draw, self)
	end
end

pcall(InstallGuideOverlay)
