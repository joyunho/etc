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
OUT = HERE / "scripts" / "korean_strings.lua"

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
        body.append(f'if Apply("{mid}") then')
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
        body.append("end")

    header = f"""-- korean_strings.lua  --  자동 생성 파일. 직접 고치지 마세요.
--
-- 모드 {len(merged)}개, 문자열 {total}개.
-- 이 파일은 다른 모드의 파일을 건드리지 않습니다. STRINGS 에 한국어를 덮어쓸
-- 뿐이고, 그것도 해당 모드가 켜져 있을 때만 합니다.

local STRINGS = GLOBAL.STRINGS
local KnownMods = GLOBAL.KnownModIndex

-- 그 모드가 실제로 켜져 있을 때만 덮어씁니다. 안 쓰는 모드의 이름을
-- 미리 심어 두면 다른 모드와 부딪칠 수 있습니다.
local function Apply(id)
\tlocal ok, enabled = pcall(function()
\t\treturn KnownMods:IsModEnabled("workshop-" .. id)
\t\t\tor KnownMods:IsModForceEnabled("workshop-" .. id)
\tend)
\treturn ok and enabled or false
end

-- 한 번만 덮어쓰면 늦게 켜진 모드가 다시 영어로 되돌려 놓을 수 있습니다.
-- 그래서 함수로 감싸 두고, 모드가 전부 올라온 뒤 한 번 더 부릅니다.
local function ApplyAll()
"""

    footer = """
end

ApplyAll()
GLOBAL.KOREAN_PATCH_APPLY = ApplyAll
"""

    # every generated line sits inside ApplyAll(), so indent the body one step
    indented = "\n".join(("\t" + l) if l.strip() else l for l in body)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(header + indented + footer, encoding="utf-8")
    print(f"wrote {OUT}  ({len(merged)} mods, {total} strings)")


if __name__ == "__main__":
    main()
