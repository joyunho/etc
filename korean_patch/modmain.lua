-- 모드 한글 패치
--
-- 하는 일은 하나뿐입니다: 다른 모드가 STRINGS 에 넣어 둔 영어/중국어 글자를
-- 한국어로 덮어씁니다. 남의 파일을 고치지 않으므로 모드가 깨질 수 없고,
-- 이 모드를 끄면 아무 흔적도 남지 않습니다.

local enabled = GetModConfigData("enabled")
if enabled == false then
	return
end

-- 번역표를 읽어 바로 한 번 적용합니다.
local ok, err = pcall(function()
	modimport("scripts/korean_strings.lua")
end)

if not ok then
	print("[한글패치] 번역을 적용하지 못했습니다: " .. tostring(err))
	return
end

-- 우선순위를 낮춰 두었지만, 그래도 우리보다 늦게 글자를 넣는 모드가 있을 수
-- 있습니다. 월드가 다 올라온 뒤 한 번 더 덮어씁니다. 같은 값을 다시 넣는
-- 것이라 두 번 해도 문제가 없습니다.
AddSimPostInit(function()
	if GLOBAL.KOREAN_PATCH_APPLY ~= nil then
		pcall(GLOBAL.KOREAN_PATCH_APPLY)
	end
end)
