"""Draw a page the way the game will: cover the English, print the Korean.

This is the preview. The same numbers drive the in-game overlay, so what this
renders is what the widget puts on the page -- give or take the font, since the
game draws Korean with Klei's own CJK fallback face."""
import json, os, re, sys, statistics
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from PIL import Image, ImageDraw, ImageFont
import numpy as np

S = os.environ.get("GUIDE_WORK", "work")
F = os.environ.get("GUIDE_FONTS", S + "/fonts")

COLOURS = {"ink": (90, 60, 33), "gold": (165, 150, 41), "navy": (49, 60, 115),
           "plum": (90, 56, 82), "grey": (74, 74, 74)}
RUN = re.compile(r"\{\{([gnpi])\|(.*?)\}\}")
RUN_COLOUR = {"g": "gold", "n": "navy", "p": "plum", "i": "ink"}

_fonts = {}
def font(size, heavy):
    key = (size, heavy)
    if key not in _fonts:
        path = F + ("/BlackHanSans.ttf" if heavy else "/NotoSansKR-Bold.ttf")
        _fonts[key] = ImageFont.truetype(path, size)
    return _fonts[key]


def runs(s, base):
    """Split {{g|...}} markers into (text, colour) runs."""
    out, i = [], 0
    for m in RUN.finditer(s):
        if m.start() > i:
            out.append((s[i:m.start()], base))
        out.append((m.group(2), RUN_COLOUR[m.group(1)]))
        i = m.end()
    if i < len(s):
        out.append((s[i:], base))
    return out or [(s, base)]


def tokens(s):
    out, buf = [], ""
    for ch in s:
        if ch == " ":
            if buf: out.append(buf); buf = ""
            out.append(" ")
        elif "가" <= ch <= "힣":
            if buf: out.append(buf); buf = ""
            out.append(ch)
        else:
            buf += ch
    if buf: out.append(buf)
    return out


def wrap(draw, rs, width, ft):
    lines, cur, x = [], [], 0.0
    for text, colour in rs:
        for tok in tokens(text):
            w = draw.textlength(tok, font=ft)
            if x + w > width and cur:
                if tok == " ":
                    lines.append(cur); cur, x = [], 0.0
                    continue
                lines.append(cur); cur, x = [], 0.0
            if tok == " " and not cur:
                continue
            cur.append((tok, colour)); x += w
    if cur:
        lines.append(cur)
    return lines


def bg_of(a, cover):
    """The page colour just outside a line box -- what to paint over it with."""
    picks = []
    for x0, y0, x1, y1 in cover:
        for yy in (max(0, y0 - 4), min(a.shape[0] - 1, y1 + 3)):
            strip = a[yy, x0:x1]
            if len(strip):
                picks.append(np.median(strip, axis=0))
    if not picks:
        return (255, 253, 236)
    return tuple(int(v) for v in np.median(np.array(picks), axis=0))


def render(page, blocks_geom, tr, out_path, src=None):
    src = src or f"{S}/pages/{page}.png"
    im = Image.open(src).convert("RGB")
    a = np.asarray(im).astype(int)
    d = ImageDraw.Draw(im)
    by_id = {b["id"]: b for b in blocks_geom}
    trs = {t["id"]: t for t in tr}

    # a reader who saw the box sitting on a drawing can move its left edge
    for b in blocks_geom:
        left = (trs.get(b["id"]) or {}).get("left")
        if isinstance(left, int) and b["x"] < left < b["x"] + b["w"]:
            b["cover"] = [[max(c[0], left), c[1], c[2], c[3]] for c in b["cover"]]
            b["cover"] = [c for c in b["cover"] if c[2] - c[0] >= 6]
            b["w"] -= left - b["x"]
            b["x"] = left

    # paint out every block that is really text
    groups = {}
    for b in blocks_geom:
        t = trs.get(b["id"])
        if t is None or t.get("kind") == "art":
            continue
        col = bg_of(a, b["cover"])
        for x0, y0, x1, y1 in b["cover"]:
            d.rectangle((x0 - 2, y0 - 2, x1 + 2, y1 + 2), fill=col)
        g = t.get("group") or b["id"]
        groups.setdefault(g, []).append(b["id"])

    # then set the Korean, one flowing region per group
    for g, ids in sorted(groups.items()):
        ids.sort()
        parts, gb = [], [by_id[i] for i in ids]
        for i in ids:
            s = (trs[i].get("ko") or "").strip()
            if s:
                parts.append(s)
        if not parts:
            continue
        text = " ".join(parts)
        x = min(b["x"] for b in gb)
        y = min(b["y"] for b in gb)
        w = max(b["x"] + b["w"] for b in gb) - x
        h = int(statistics.median([b["h"] for b in gb]))
        lead = int(statistics.median([b["lead"] for b in gb]))
        avail = max(b["y"] + b["lines"] * b["lead"] for b in gb) - y
        base = COLOURS.get(by_id[ids[0]]["colour"], COLOURS["ink"])
        heavy = h >= 26
        size = h + (2 if heavy else 1)
        rs = runs(text, by_id[ids[0]]["colour"])
        while size > 8:
            ft = font(size, heavy)
            lines = wrap(d, rs, w, ft)
            step = max(lead, size + 3) if len(lines) > 1 else lead
            if len(lines) * step <= avail + lead * 0.6:
                break
            size -= 1
        yy = y
        for line in lines:
            cx = x
            for tok, colour in line:
                if tok != " ":
                    d.text((cx, yy), tok, font=ft, fill=COLOURS.get(colour, base))
                cx += d.textlength(tok, font=ft)
            yy += step
    im.save(out_path)
    return im
