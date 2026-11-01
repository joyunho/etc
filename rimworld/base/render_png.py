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
HARD_LABELS = [("문루 · 구멍", 6, 24, 2), ("옹성 마당", 0, 34, 3), ("바깥 성문", 0, 38, 4), ("뱀길 입구", 30, 47, 5),
               ("뱀길", -15, 53, 5), ("쪽문", -37, -2, 4), ("쪽문", 37, -2, 4), ("쪽문", 0, -36, 4),
               ("밭", -30, 9, 1), ("발전기 띠", 9, -31, 3), ("무덤", 23, -19, 3), ("폐기물 창고", 22, 24, 4),
               ("중력부양선 갑판", 29, -14, 6), ("뜰", -18, -27, 2)]
# names too long for their wedge of the picture
SHORT = {"메카노이드 정비실": "정비실", "어린이방·학교": "어린이방", "문루(남쪽 큰길 끝)": ""}

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
    "kbwall": (74, 78, 84), "anchor": (120, 90, 160), "centrepiece": (150, 110, 60), "generator": (120, 84, 50),
    # max-difficulty variant
    "court": (234, 206, 158), "band": (199, 186, 156), "lane": (229, 219, 193), "maint": (196, 207, 219),
    "store": (196, 207, 219), "trap": (150, 38, 38), "fence": (128, 96, 56), "hole": (190, 74, 52),
    "blocker": (200, 56, 48), "shooter": (46, 88, 160), "gategap": (190, 74, 52), "postern": (214, 150, 44),
    "entry": (190, 74, 52),
}
# drawn after the walls so they stay visible on floor tiles
OVERLAY = {"hole", "blocker", "shooter", "gategap", "entry"}
TINTS = {"court", "band", "lane", "maint", "store"}


def main(plan_path, out_path, max_phase=5):
    plan = json.load(open(plan_path, encoding="utf-8"))
    w, h = plan["width"], plan["height"]
    x0, y0 = plan["origin"]
    kinds = {r["key"]: r["kind"] for r in plan["rooms"]}
    img = Image.new("RGB", (w * TILE, h * TILE), GROUND)
    d = ImageDraw.Draw(img)

    def box(i, j, color, inset=0):
        d.rectangle([i * TILE + inset, j * TILE + inset, (i + 1) * TILE - 1 - inset, (j + 1) * TILE - 1 - inset], fill=color)

    def draw_feature(f):
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
            elif f["kind"] == "trap":
                d.line([i * TILE + 2, j * TILE + 2, (i + 1) * TILE - 3, (j + 1) * TILE - 3], fill=color, width=2)
                d.line([i * TILE + 2, (j + 1) * TILE - 3, (i + 1) * TILE - 3, j * TILE + 2], fill=color, width=2)
            elif f["kind"] == "fence":
                d.rectangle([i * TILE + 2, j * TILE + TILE // 2 - 1, (i + 1) * TILE - 3, j * TILE + TILE // 2], fill=color)
                d.rectangle([i * TILE + TILE // 2 - 1, j * TILE + 2, i * TILE + TILE // 2, (j + 1) * TILE - 3], fill=color)
            elif f["kind"] in ("hole", "gategap", "entry"):
                d.rectangle([i * TILE + 1, j * TILE + 1, (i + 1) * TILE - 2, (j + 1) * TILE - 2], outline=color, width=2)
            elif f["kind"] == "blocker":
                d.rectangle([i * TILE + 2, j * TILE + 2, (i + 1) * TILE - 3, (j + 1) * TILE - 3], fill=color)
            elif f["kind"] == "shooter":
                d.ellipse([i * TILE + 3, j * TILE + 3, (i + 1) * TILE - 4, (j + 1) * TILE - 4], fill=color)
            elif f["kind"] == "postern":
                continue
            else:
                box(i, j, color, 0 if f["kind"] in {"gravship", "solar", "graves", "kbwall"} | TINTS else 1)

    visible = [f for f in plan["features"] if f["phase"] <= max_phase]
    for f in sorted((f for f in visible if f["kind"] in TINTS), key=lambda f: f["kind"] != "band"):
        draw_feature(f)
    for f in visible:
        if f["kind"] not in TINTS and f["kind"] not in OVERLAY:
            draw_feature(f)

    for j, row in enumerate(plan["cells"]):
        for i, (t, room, ph, door_ph) in enumerate(row):
            if t == "ground" or ph > max_phase:
                continue
            if t == "wall" or (t == "door" and door_ph > max_phase):
                box(i, j, WALL)
            elif t == "door":
                box(i, j, WALL)
                box(i, j, DOOR, 2)
            elif t == "gate":
                box(i, j, GATE)
            elif t == "floor":
                box(i, j, KIND.get(kinds.get(room), CORRIDOR))

    for f in visible:
        if f["kind"] in OVERLAY:
            draw_feature(f)

    # faint grid every 5 tiles, counted from the centre tile, so positions can be counted off the picture
    grid_col = (196, 180, 150)
    for k in range(-60, 61, 5):
        gx = (k - x0) * TILE
        gy = (k - y0) * TILE
        if 0 <= gx <= w * TILE:
            d.line([gx, 0, gx, h * TILE], fill=grid_col if k else (150, 130, 100), width=1)
        if 0 <= gy <= h * TILE:
            d.line([0, gy, w * TILE, gy], fill=grid_col if k else (150, 130, 100), width=1)
    font = korean_font(13)
    small = korean_font(11)
    for r in plan["rooms"]:
        if r["phase"] > max_phase or r["kind"] == "corridor":
            continue
        cx, cy = r["center"]
        i, j = cx - x0, cy - y0
        name = SHORT.get(r["name"], r["name"].split("(")[0])
        if r["kind"] == "bedroom":
            name = name.replace("침실 ", "")
            fnt = small
        else:
            fnt = font
        px, py = i * TILE + TILE // 2, j * TILE + TILE // 2
        tw = d.textlength(name, font=fnt)
        d.text((px - tw / 2, py - 7), name, font=fnt, fill=(40, 36, 30))
    # (text, dx, dy, phase it first appears in)
    labels = HARD_LABELS if plan.get("variant") == "hard" else [("남문(정문)", 0, 25, 4), ("서문(밭)", -26, -1, 4), ("동문", 25, -3, 4), ("북문", 0, -25, 4),
              ("밭", -28, 8, 1), ("중력부양선 갑판", 31, -10, 5), ("발전기 띠", 12, -28, 3), ("무덤", 23, -26, 3),
              ("폐기물 창고", 35, -19, 4), ("킬박스", -8, 27, 4)]
    for text, dx, dy, ph in labels:
        if ph > max_phase:
            continue
        i, j = dx - x0, dy - y0
        if 0 <= i < w and 0 <= j < h:
            tw = d.textlength(text, font=small)
            d.text((i * TILE - tw / 2, j * TILE - 6), text, font=small, fill=(60, 50, 40))
    img.save(out_path, optimize=True)
    print("saved", out_path, img.size)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 9)
