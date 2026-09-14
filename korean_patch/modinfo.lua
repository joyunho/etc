name = "모드 한글 패치 (개인용)"
description = [[
설치된 모드의 화면 글자를 한국어로 바꿉니다.

다른 모드의 파일은 하나도 건드리지 않습니다. 게임이 이미 읽어 들인 STRINGS 에
한국어를 덮어쓸 뿐이라, 번역이 틀려도 글자가 이상해질 뿐 모드가 멈추지는
않습니다. 이 모드를 끄면 즉시 원래대로 돌아갑니다.

해당 모드가 실제로 켜져 있을 때만 그 모드의 글자를 덮어씁니다.
]]
author = "joyunho"
version = "1.0.0"
forumthread = ""

api_version = 10
dst_compatible = true
dont_starve_compatible = false
reign_of_giants_compatible = false

-- 다른 모드보다 먼저 올라가면 그 모드가 제 글자로 다시 덮어씁니다.
-- 우선순위를 낮춰서 마지막에 올라가게 합니다.
priority = -1000

all_clients_require_mod = false   -- 글자는 각자 화면의 문제입니다
client_only_mod = true

icon_atlas = ""
icon = ""

server_filter_tags = {}

configuration_options =
{
	{
		name = "enabled",
		label = "한글 패치",
		hover = "끄면 모든 글자가 원래 언어로 돌아갑니다.",
		options =
		{
			{ description = "켜기", data = true },
			{ description = "끄기", data = false },
		},
		default = true,
	},
}
