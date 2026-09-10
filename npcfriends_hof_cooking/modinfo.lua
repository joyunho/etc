-- modinfo.lua
-- NPC Friends x Heap of Foods -- cooking compatibility patch

local _ko = (locale == "ko")

name = _ko
	and "NPC 왈리 × Heap of Foods 요리 호환 패치"
	or  "NPC Friends x Heap of Foods - Cooking Patch"

description = _ko and [[
NPC Friends 모드의 왈리 NPC가 Heap of Foods(그리고 다른 음식 모드)의 요리를
제대로 인식하고, 여러 가지 요리를 돌아가며 만들도록 고쳐 줍니다.

■ 무엇이 문제였나
NPC Friends는 "왈리가 만들 수 있는 요리" 목록을 모드 안에 직접 적어 두었습니다.
그 목록에는 바닐라 요리와 일부 모드 요리만 들어 있어서, Heap of Foods가 추가한
200종이 넘는 요리는 창고에 재료가 가득해도 아예 후보에 오르지 않습니다.
게다가 창고에 미트볼이 없으면 무조건 미트볼부터 만들게 되어 있어서,
같은 요리만 반복해서 나옵니다.

■ 어떻게 고치나
요리 목록을 새로 적는 대신, 왈리가 쓸 수 있는 재료로 조합을 만들어 보고
게임 자체의 요리 판정 함수에 "이 조합은 무슨 요리가 되나?" 하고 직접 물어봅니다.
따라서 정상적인 방식으로 등록된 음식 모드라면 무엇이든 자동으로 인식됩니다.
여기에 "최근에 만든 요리 / 이미 창고에 쌓인 요리"에 감점을 주어
같은 요리만 반복하지 않도록 합니다.

■ 필요한 모드
NPC Friends (필수) · Heap of Foods (권장)

서버에만 설치하면 됩니다. 다른 모드의 파일은 전혀 건드리지 않습니다.
]] or [[
Makes the Warly companion from NPC Friends recognise and cook the dishes added
by Heap of Foods (and any other food mod), and rotate through them instead of
repeating one dish forever.

WHAT WAS WRONG
NPC Friends decides what to cook from a recipe list written by hand inside the
mod. That list only covers vanilla dishes plus a handful of manually added mod
dishes, so the 200+ dishes from Heap of Foods never become candidates no matter
how full the pantry is. On top of that the chef is hardcoded to cook Meatballs
first whenever none are in storage, which is why the same dish keeps appearing.

WHAT THIS DOES
Rather than writing out another 200 recipes, it builds combinations from the
ingredients the chef can actually reach and asks the game's own recipe resolver
what each combination would produce. Any food mod registered the normal way is
therefore picked up automatically. Dishes that were cooked recently, or that are
already stacked in storage, are penalised so the menu keeps changing.

REQUIRES
NPC Friends (required) - Heap of Foods (recommended)

Server side only. No file from either mod is modified or redistributed.
]]

author  = "joyunho"
version = "1.0.0"

forumthread = ""

api_version = 10

dst_compatible             = true
dont_starve_compatible     = false
reign_of_giants_compatible = false
shipwrecked_compatible     = false

all_clients_require_mod = false
client_only_mod         = false

server_filter_tags = { "npc friends", "heap of foods", "cooking" }

-- Load after everything else, so the recipe tables of every food mod are
-- already registered by the time we look at them.
priority = -100

local function opt(desc, data)
	return { description = desc, data = data }
end

configuration_options =
{
	{
		name    = "enabled",
		label   = _ko and "패치 사용" or "Enable patch",
		hover   = _ko and "끄면 NPC Friends 원래 요리 로직을 그대로 씁니다."
		              or  "Off leaves NPC Friends' own cooking logic untouched.",
		options =
		{
			opt(_ko and "켜기" or "On",  true),
			opt(_ko and "끄기" or "Off", false),
		},
		default = true,
	},

	{
		name    = "variety",
		label   = _ko and "요리 다양성" or "Dish variety",
		hover   = _ko and "높을수록 최근에 만든 요리를 피하고 새로운 요리를 시도합니다."
		              or  "Higher settings avoid recently cooked dishes and try new ones.",
		options =
		{
			opt(_ko and "끔 (가장 좋은 요리만)" or "Off (best dish only)", "off"),
			opt(_ko and "낮음"                  or "Low",                  "low"),
			opt(_ko and "보통"                  or "Medium",               "medium"),
			opt(_ko and "높음"                  or "High",                 "high"),
		},
		default = "medium",
	},

	{
		name    = "budget",
		label   = _ko and "레시피 탐색량" or "Recipe search effort",
		hover   = _ko and "높을수록 더 많은 요리를 찾아내지만 서버 부하가 늘어납니다."
		              or  "Higher finds more dishes but costs more server time.",
		options =
		{
			opt(_ko and "낮음 (가벼움)"   or "Low (light)",     "low"),
			opt(_ko and "보통"            or "Medium",          "medium"),
			opt(_ko and "높음 (무거움)"   or "High (heavy)",    "high"),
		},
		default = "medium",
	},

	{
		name    = "same_dish_max",
		label   = _ko and "같은 요리 최대 보관량" or "Max of one dish in storage",
		hover   = _ko and "창고에 이 개수만큼 쌓이면 그 요리는 더 만들지 않습니다."
		              or  "Once this many are stored the chef stops making that dish.",
		options =
		{
			opt(_ko and "NPC Friends 설정 따름" or "Follow NPC Friends", 0),
			opt("1",  1),
			opt("2",  2),
			opt("3",  3),
			opt("5",  5),
			opt("8",  8),
			opt("10", 10),
		},
		default = 0,
	},

	{
		name    = "allow_negative",
		label   = _ko and "해로운 요리 허용" or "Allow harmful dishes",
		hover   = _ko and "체력이나 정신력이 깎이는 요리도 만들게 합니다."
		              or  "Lets the chef cook dishes that cost health or sanity.",
		options =
		{
			opt(_ko and "안 함" or "No",  false),
			opt(_ko and "허용"  or "Yes", true),
		},
		default = false,
	},

	{
		name    = "debug",
		label   = _ko and "디버그 로그" or "Debug log",
		hover   = _ko and "서버 로그에 어떤 요리를 왜 골랐는지 출력합니다."
		              or  "Prints which dish was chosen and why to the server log.",
		options =
		{
			opt(_ko and "끄기" or "Off", false),
			opt(_ko and "켜기" or "On",  true),
		},
		default = false,
	},
}
