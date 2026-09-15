#!/usr/bin/env python3
"""Build the Korean string-override mod from the per-mod translation files.

The mod never edits another mod. It only assigns STRINGS.<path> = "<korean>"
after everything else has loaded, so a wrong translation can make a label read
oddly but cannot stop a mod -- or the server -- from running.
"""
import json
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
TRANS = HERE / "translations"
OUT = HERE / "modmain.lua"

# Mod ids to human names, for the generated comments and the load report.
NAMES = {
    "2087177552": "Large Chest (HD)",
    "3569101848": "Winona's Porta-base V2",
    "2873533916": "ActionQueue RB3",
    "3466003439": "Shadow Field Exciter",
    "2812783478": "[API] Modded Skins",
    "2981932326": "DST Coffee and More",
    "3675508496": "Pond OceanTree",
    "3597024951": "JingXi Furniture",
    "3461374558": "[AnL] In-game Guide",
}

# STRINGS paths we accept. Anything else is a bug in the extractor, not a
# translation, and must not reach the game.
PATH_OK = re.compile(r'^(\.[A-Za-z_]\w*)+$')

# A lua module name another mod requires, e.g. "constants/guide_data".
MODULE_OK = re.compile(r'^[A-Za-z_][\w/]*$')

# Sections a mod's entry may carry besides its plain STRINGS paths.
#
#   _tuning   paths under GLOBAL.TUNING rather than GLOBAL.STRINGS. Some mods
#             keep their display text there -- [AnL] In-game Guide puts its
#             achievement hints in TUNING.CHASNI_CONFIG.ACHIEVEMENT_GUIDE and
#             Achievement & Level reads them back out to show them.
#
#   _module   a table returned by another mod's lua module, reached with
#             require(). The guide's tab labels live in the table
#             constants/guide_data returns, not in STRINGS at all.
#
# Both are written with Replace, never Set: a key that is not already a string
# is left alone, so a mod that is not installed, or that changed shape in an
# update, costs nothing.
SECTIONS = ("_tuning", "_module")


def lua_quote(s: str) -> str:
    """Quote a Korean string as a Lua literal.

    Only the four sequences that can end or confuse the literal are escaped.
    Korean stays as raw UTF-8, which is what DST reads.
    """
    out = s.replace("\\", "\\\\").replace('"', '\\"')
    out = out.replace("\n", "\\n").replace("\r", "\\r")
    return '"' + out + '"'


def lua_call(path: str, value: str) -> str:
    """.UI.RARITY.Modded -> Set("모드 - ", "UI", "RARITY", "Modded")

    Every key is passed as a quoted argument, so a key that is a Lua keyword,
    starts with a digit, or contains anything unusual cannot turn into a
    syntax error or reach the wrong table.
    """
    parts = ", ".join(f'"{p}"' for p in path.lstrip(".").split("."))
    return f"Set({lua_quote(value)}, {parts})"


def lua_replace(root: str, path: str, value: str) -> str:
    """.CHASNI_CONFIG.X -> Replace(GLOBAL.TUNING, "한국어", "CHASNI_CONFIG", "X")"""
    parts = ", ".join(f'"{p}"' for p in path.lstrip(".").split("."))
    return f"Replace({root}, {lua_quote(value)}, {parts})"


def main() -> None:
    merged: dict[str, dict[str, str]] = {}
    for f in sorted(TRANS.glob("*.json")):
        for mid, entries in json.loads(f.read_text(encoding="utf-8")).items():
            merged.setdefault(mid, {}).update(entries)

    def count(entries: dict) -> int:
        n = sum(1 for k in entries if k not in SECTIONS)
        n += len(entries.get("_tuning", {}))
        for paths in entries.get("_module", {}).values():
            n += len(paths)
        return n

    body: list[str] = []
    total = 0
    for mid in sorted(merged, key=lambda m: -count(merged[m])):
        entries = merged[mid]
        body.append("")
        body.append(f"-- {NAMES.get(mid, mid)}  (workshop-{mid})  {count(entries)}개")
        body.append(f'pcall(function() if Apply("{mid}") then')

        for path in sorted(k for k in entries if k not in SECTIONS):
            if not PATH_OK.match(path):
                raise SystemExit(f"거부: 이상한 경로 {mid} {path}")
            body.append("\t" + lua_call(path, entries[path]))
            total += 1

        for path in sorted(entries.get("_tuning", {})):
            if not PATH_OK.match(path):
                raise SystemExit(f"거부: 이상한 TUNING 경로 {mid} {path}")
            body.append("\t" + lua_replace("GLOBAL.TUNING", path, entries["_tuning"][path]))
            total += 1

        for module in sorted(entries.get("_module", {})):
            if not MODULE_OK.match(module):
                raise SystemExit(f"거부: 이상한 모듈 이름 {mid} {module}")
            paths = entries["_module"][module]
            var = "_m" + str(abs(hash(module)) % 10000)
            body.append(f'\tlocal {var} = Module("{module}")')
            for path in sorted(paths):
                if not PATH_OK.match(path):
                    raise SystemExit(f"거부: 이상한 모듈 경로 {mid} {module} {path}")
                body.append("\t" + lua_replace(var, path, paths[path]))
                total += 1

        body.append("end end)")

    header = f"""-- modmain.lua  --  자동 생성 파일. 직접 고치지 마세요.
--
-- 모드 {len(merged)}개, 문자열 {total}개.
--
-- 이 파일이 지켜야 할 것은 하나입니다: 무슨 일이 있어도 게임이 켜지는 것을
-- 막지 않는다. 글자를 바꾸는 일이 게임을 못 켜게 만들면 아무 의미가 없습니다.
-- 그래서
--   * 다른 파일을 부르지 않습니다 (modimport 실패할 일이 없음)
--   * 전역 변수를 새로 만들지 않습니다 (strict.lua 에 걸릴 일이 없음)
--   * 설정을 읽지 않습니다 (설정이 없을 때 터질 일이 없음)
--   * 모드 한 개씩 pcall 로 감쌉니다 (하나가 실패해도 나머지는 적용됨)
--   * 전체를 다시 pcall 로 감쌉니다 (그래도 실패하면 조용히 아무것도 안 함)

-- DST 의 모드 환경(mods.lua 의 CreateEnvironment)은 메타테이블이 없는 평평한
-- 표입니다. 그 표에 든 이름만 보입니다: pairs, ipairs, print, math, table,
-- type, string, tostring, require, Class, TUNING, GLOBAL, modname, MODROOT.
-- pcall 도 select 도 error 도 거기 없습니다. 그냥 쓰면 nil 을 부르게 되고
-- 그 자리에서 모드가 죽습니다. 그래서 GLOBAL 에서 직접 꺼내 씁니다.
local pcall = GLOBAL.pcall
local select = GLOBAL.select
local type = GLOBAL.type

local function Translate()
	local STRINGS = GLOBAL.STRINGS
	local Index = GLOBAL.KnownModIndex

	-- 그 모드가 실제로 켜져 있을 때만 덮어씁니다. 안 쓰는 모드의 이름을
	-- 미리 심어 두면 다른 모드와 부딪칠 수 있습니다.
	local function Apply(id)
		local ok, enabled = pcall(function()
			return Index:IsModEnabled("workshop-" .. id)
				or Index:IsModForceEnabled("workshop-" .. id)
		end)
		return ok and enabled or false
	end

	-- 글자 하나를 제자리에 넣습니다.
	--
	-- 중간 칸이 이미 "문자열"인 경우를 반드시 따로 다뤄야 합니다. DST 는
	-- STRINGS.ACTIONS.PICK 처럼 동작 문구를 그냥 문자열로 둡니다. 거기에
	-- 대상별 문구를 붙이려면 표로 바꾸고 원래 문자열을 GENERIC 으로 옮기는
	-- 것이 DST 의 규칙입니다. 이 과정을 건너뛰고 문자열에 [...] 로 대입하면
	-- "attempt to index a string value" 로 그 자리에서 터집니다.
	local function Set(value, ...)
		local node = STRINGS
		local n = select("#", ...)

		for i = 1, n - 1 do
			local key = select(i, ...)
			local nxt = node[key]

			if nxt == nil then
				nxt = {{}}
				node[key] = nxt
			elseif type(nxt) == "string" then
				nxt = {{ GENERIC = nxt }}
				node[key] = nxt
			elseif type(nxt) ~= "table" then
				return      -- 표도 문자열도 아니면 건드리지 않습니다
			end

			node = nxt
		end

		node[select(n, ...)] = value
	end

	-- 남의 표를 고칠 때 씁니다.
	--
	-- Set 과 다르게 표를 만들지 않고 없는 칸을 새로 만들지도 않습니다.
	-- 이미 문자열이 들어 있는 자리만 바꿉니다. 그 모드가 안 깔려 있거나,
	-- 업데이트로 모양이 바뀌었으면 아무 일도 일어나지 않습니다.
	-- 우리 것이 아닌 표에는 그게 맞는 답입니다.
	local function Replace(root, value, ...)
		if type(root) ~= "table" then
			return
		end

		local node = root
		local n = select("#", ...)

		for i = 1, n - 1 do
			node = node[select(i, ...)]
			if type(node) ~= "table" then
				return
			end
		end

		local key = select(n, ...)
		if type(node[key]) == "string" then
			node[key] = value
		end
	end

	-- 다른 모드의 lua 모듈을 가져옵니다. 없으면 nil 입니다.
	local function Module(name)
		local ok, mod = pcall(require, name)
		if ok and type(mod) == "table" then
			return mod
		end
		return nil
	end

"""
    footer = """
end

-- 한 번만 덮어쓰면 늦게 올라온 모드가 다시 제 글자로 되돌려 놓을 수 있습니다.
-- 그래서 월드가 다 뜬 뒤 한 번 더 부릅니다. 같은 값을 다시 넣는 것이라
-- 두 번 해도 문제가 없습니다.
local ok, err = pcall(Translate)
if not ok then
	print("[한글패치] 적용하지 못했습니다: " .. tostring(err))
	return
end

AddSimPostInit(function()
	pcall(Translate)
end)
"""

    # every generated line sits inside ApplyAll(), so indent the body one step
    indented = "\n".join(("\t" + l) if l.strip() else l for l in body)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(header + indented + footer, encoding="utf-8")
    print(f"wrote {OUT}  ({len(merged)} mods, {total} strings)")


if __name__ == "__main__":
    main()
