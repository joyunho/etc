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
}

# STRINGS paths we accept. Anything else is a bug in the extractor, not a
# translation, and must not reach the game.
PATH_OK = re.compile(r'^(\.[A-Za-z_]\w*)+$')


def lua_quote(s: str) -> str:
    """Quote a Korean string as a Lua literal.

    Only the four sequences that can end or confuse the literal are escaped.
    Korean stays as raw UTF-8, which is what DST reads.
    """
    out = s.replace("\\", "\\\\").replace('"', '\\"')
    out = out.replace("\n", "\\n").replace("\r", "\\r")
    return '"' + out + '"'


def lua_path(path: str) -> str:
    """.UI.RARITY.Modded -> STRINGS.UI.RARITY["Modded"]

    The last step is written as a bracket lookup so that keys which are Lua
    keywords, or start with a digit, cannot produce a syntax error.
    """
    parts = path.lstrip(".").split(".")
    head = "STRINGS." + ".".join(parts[:-1]) if len(parts) > 1 else "STRINGS"
    return f'{head}["{parts[-1]}"]'


def ensure_path(path: str) -> str:
    """Lua to create the parent tables if the mod has not made them yet."""
    parts = path.lstrip(".").split(".")[:-1]
    lines = []
    cur = "STRINGS"
    for p in parts:
        nxt = f'{cur}["{p}"]'
        lines.append(f"if {nxt} == nil then {nxt} = {{}} end")
        cur = nxt
    return lines


def main() -> None:
    merged: dict[str, dict[str, str]] = {}
    for f in sorted(TRANS.glob("*.json")):
        for mid, entries in json.loads(f.read_text(encoding="utf-8")).items():
            merged.setdefault(mid, {}).update(entries)

    body: list[str] = []
    total = 0
    for mid in sorted(merged, key=lambda m: -len(merged[m])):
        entries = merged[mid]
        body.append("")
        body.append(f"-- {NAMES.get(mid, mid)}  (workshop-{mid})  {len(entries)}개")
        body.append(f'pcall(function() if Apply("{mid}") then')
        seen_parents: set[str] = set()
        for path in sorted(entries):
            if not PATH_OK.match(path):
                raise SystemExit(f"거부: 이상한 경로 {mid} {path}")
            for line in ensure_path(path):
                if line not in seen_parents:
                    seen_parents.add(line)
                    body.append("\t" + line)
            body.append(f"\t{lua_path(path)} = {lua_quote(entries[path])}")
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
