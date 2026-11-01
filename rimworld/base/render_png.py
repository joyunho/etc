"""Render plan.json to a PNG for the README.

Usage: python -I render_png.py <plan.json> <out.png> [max_phase]
"""
import json
import sys

from PIL import Image, ImageDraw, ImageFont

FONT_CANDIDATES = [
    "C:/Windows/Fonts/malgun.ttf",                      # Windows: 맑은 고딕
    "/System/Library/Fonts/AppleSDGothicNeo.ttc",       # macOS
    "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",     # Linux
    "/usr/share/fonts/truetype/nanum/NanumGothic.ttf",
]


def korean_font(size):
    for path in FONT_CANDIDATES:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()
TILE = 12

GROUND = (214, 199, 168)
WALL = (74, 78, 84)
DOOR = (214, 150, 44)
GATE = (190, 74, 52)
CORRIDOR = (233, 229, 219)
KIND = {
    "hall": (236, 205, 140), "kitchen": (204, 223, 186), "freezer": (176, 212, 228),
    "butcher": (226, 186, 176), "prison": (196, 188, 206), "lab": (190, 214, 236),
    "school": (240, 214, 196), "mech": (200, 204, 210), "power": (228, 222, 160),
    "hospital": (236, 236, 244), "storage": (214, 204, 180), "workshop": (220, 196, 160),
    "bedroom": (226, 210, 228), "corridor": CORRIDOR,
}
FEATURE = {
    "field": (128, 168, 86), "sandbags": (176, 150, 104), "turret": (172, 46, 40),
    "solar": (92, 120, 150), "graves": (140, 132, 120), "wastepack": (166, 178, 60),
    "gravship": (150, 156, 164), "engine": (60, 190, 210), "console": (40, 80, 120),
    "tank": (200, 120, 40), "thruster": (90, 90, 96), "exhaust": (232, 214, 186),
    "kbwall": (74, 78, 84), "anchor": (120, 90, 160), "centrepiece": (150, 110, 60),
}


def main(plan_path, out_path, max_phase=5):
    plan = json.load(open(plan_path, encoding="utf-8"))
    w, h = plan["width"], plan["height"]
    x0, y0 = plan["origin"]
    kinds = {r["key"]: r["kind"] for r in plan["rooms"]}
    img = Image.new("RGB", (w * TILE, h * TILE), GROUND)
    d = ImageDraw.Draw(img)

    def box(i, j, color, inset=0):
        d.rectangle([i * TILE + inset, j * TILE + inset, (i + 1) * TILE - 1 - inset, (j + 1) * TILE - 1 - inset], fill=color)

    for f in plan["features"]:
        if f["phase"] > max_phase:
            continue
        color = FEATURE[f["kind"]]
        for dx, dy in f["cells"]:
            i, j = dx - x0, dy - y0
            if not (0 <= i < w and 0 <= j < h):
                continue
            if f["kind"] == "turret":
                d.ellipse([i * TILE + 1, j * TILE + 1, (i + 1) * TILE - 2, (j + 1) * TILE - 2], fill=color)
            elif f["kind"] == "field":
                box(i, j, color)
                if (dx + dy) % 2 == 0:
                    d.line([i * TILE + 2, j * TILE + TILE // 2, (i + 1) * TILE - 3, j * TILE + TILE // 2], fill=(100, 140, 66))
            elif f["kind"] == "exhaust":
                d.line([i * TILE, j * TILE, (i + 1) * TILE, (j + 1) * TILE], fill=(190, 150, 110))
            else:
                box(i, j, color, 0 if f["kind"] in ("gravship", "solar", "graves", "kbwall") else 1)

    for j, row in enumerate(plan["cells"]):
        for i, (t, room, ph) in enumerate(row):
            if t == "ground" or ph > max_phase:
                continue
            if t == "wall":
                box(i, j, WALL)
            elif t == "door":
                box(i, j, WALL)
                box(i, j, DOOR, 2)
            elif t == "gate":
                box(i, j, GATE)
            elif t == "floor":
                box(i, j, KIND.get(kinds.get(room), CORRIDOR))

    font = korean_font(13)
    small = korean_font(11)
    for r in plan["rooms"]:
        if r["phase"] > max_phase or r["kind"] == "corridor":
            continue
        cx, cy = r["center"]
        i, j = cx - x0, cy - y0
        name = r["name"].split("(")[0]
        if r["kind"] == "bedroom":
            name = name.replace("침실 ", "")
            fnt = small
        else:
            fnt = font
        px, py = i * TILE + TILE // 2, j * TILE + TILE // 2
        tw = d.textlength(name, font=fnt)
        d.text((px - tw / 2, py - 7), name, font=fnt, fill=(40, 36, 30))
    labels = [("남문(정문)", 0, 25), ("서문(밭)", -26, -1), ("동문", 25, -3), ("북문", 0, -25),
              ("밭", -28, 8), ("중력부양선 갑판", 31, -10), ("발전기 띠", 12, -28), ("폐기물 창고", 21, 25),
              ("킬박스", 0, 30)]
    for text, dx, dy in labels:
        i, j = dx - x0, dy - y0
        if 0 <= i < w and 0 <= j < h:
            tw = d.textlength(text, font=small)
            d.text((i * TILE - tw / 2, j * TILE - 6), text, font=small, fill=(60, 50, 40))
    img.save(out_path, optimize=True)
    print("saved", out_path, img.size)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 5)
