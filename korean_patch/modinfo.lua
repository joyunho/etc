name = "모드 한글 패치 (개인용)"
description = [[
설치된 모드의 화면 글자를 한국어로 바꿉니다.

다른 모드의 파일은 하나도 건드리지 않습니다. 게임이 이미 읽어 들인 STRINGS 에
한국어를 덮어쓸 뿐이고, 그 작업 전체가 pcall 로 감싸여 있어 무슨 일이 있어도
게임이 켜지는 것을 막지 않습니다. 이 모드를 끄면 즉시 원래대로 돌아갑니다.
]]
author = "joyunho"
version = "1.0.1"
forumthread = ""

api_version = 10
dst_compatible = true
dont_starve_compatible = false
reign_of_giants_compatible = false

-- 다른 모드보다 먼저 올라가면 그 모드가 제 글자로 다시 덮어씁니다.
-- 우선순위를 낮춰서 나중에 올라가게 합니다. 정렬에만 쓰이는 값입니다.
priority = -10

client_only_mod = true
all_clients_require_mod = false

server_filter_tags = {}
