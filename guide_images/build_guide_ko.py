#!/usr/bin/env python3
"""Turn the page translations into the data the in-game overlay reads.

The guide draws its pages as pictures, so the English cannot be replaced as
text. Instead the overlay paints the page's own colour over each piece of
English and sets Korean in the same place. Everything it needs -- where the
English was, what colour the page is there, what to write -- is computed here
and written out as one Lua table.

Input:
    geom/<page>.json   where the text is, measured off the decoded page
    tr/<page>.json     what it says and what it says in Korean
Output:
    scripts/guide_ko_data.lua
"""
import json
import os
import re
import statistics
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import geom

RUN = re.compile(r"\{\{([gnpi])\|(.*?)\}\}")
RUN_COLOUR = {"g": "gold", "n": "navy", "p": "plum", "i": "ink"}
COLOURS = {"ink": (90, 60, 33), "gold": (165, 150, 41), "navy": (49, 60, 115),
           "plum": (90, 56, 82), "grey": (74, 74, 74)}

# The page art is 1428 x 894 and the widget puts its own close button at
# (705, 350), which pins one widget unit to one pixel with the origin at the
# centre. See guide_images/README.md.
HALF_W, HALF_H = 714, 447


def runs(s, base):
    out, i = [], 0
    for m in RUN.finditer(s):
        if m.start() > i:
            out.append((s[i:m.start()], base))
        out.append((m.group(2), RUN_COLOUR[m.group(1)]))
        i = m.end()
    if i < len(s):
        out.append((s[i:], base))
    return out or [(s, base)]


# Characters the game's Korean font cannot draw come out as empty boxes. The
# sun that marks a perk's cost in Stars is one of them, and the mod's own
# Korean already calls that currency 별.
UNDRAWABLE = {"\u263c": "별", "\u2726": "★", "\u2605": "★"}


def drawable(s):
    for bad, good in UNDRAWABLE.items():
        s = s.replace(bad, good)
    return s


def plain(s):
    return drawable(RUN.sub(lambda m: m.group(2), s).replace("\n", " ").replace("\r", " "))


def dominant(s, base):
    """One Text widget draws in one colour, so pick the colour that covers most
    of the line. A gold term inside a brown sentence loses its gold; a heading
    that is gold all through keeps it."""
    tally = {}
    for text, colour in runs(s, base):
        tally[colour] = tally.get(colour, 0) + len(text.strip())
    return max(tally.items(), key=lambda kv: kv[1])[0] if tally else base


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def build(geom_dir, tr_dir, out_path):
    geom_dir, tr_dir = Path(geom_dir), Path(tr_dir)

    pages, n_blocks, n_pages = [], 0, 0
    for gf in sorted(geom_dir.glob("*.json")):
        if gf.name == "index.json":
            continue
        page = gf.stem
        tf = tr_dir / f"{page}.json"
        if not tf.exists():
            continue
        blocks = json.loads(gf.read_text(encoding="utf-8"))["blocks"]
        tr = {t["id"]: t for t in json.loads(tf.read_text(encoding="utf-8"))}
        by_id = {b["id"]: b for b in blocks}

        # one flowing region per group of blocks
        groups = {}
        for b in blocks:
            t = tr.get(b["id"])
            if t is None or t.get("kind") == "art":
                continue
            groups.setdefault(t.get("group") or b["id"], []).append(b["id"])

        # a reader who saw the box sitting on a drawing can move its left edge
        for b in blocks:
            left = (tr.get(b["id"]) or {}).get("left")
            if isinstance(left, int) and b["x"] < left < b["x"] + b["w"]:
                b["cover"] = [[max(c[0], left), c[1], c[2], c[3]] for c in b["cover"]]
                b["cover"] = [c for c in b["cover"] if c[2] - c[0] >= 6]
                b["w"] -= left - b["x"]
                b["x"] = left

        body_h = geom.body_height(blocks)
        entries = []
        for g, ids in sorted(groups.items()):
            ids.sort()
            gb = [by_id[i] for i in ids]
            text = " ".join(x for x in ((tr[i].get("ko") or "").strip() for i in ids) if x)
            if not text:
                continue
            base = by_id[ids[0]]["colour"]
            fg = COLOURS.get(dominant(text, base), COLOURS["ink"])
            x = min(b["x"] for b in gb)
            y = min(b["y"] for b in gb)
            w = max(b["x"] + b["w"] for b in gb) - x
            h = int(statistics.median([b["h"] for b in gb]))
            avail = max(b["y"] + b["lines"] * b["lead"] for b in gb) - y
            cover = []
            for b in gb:
                cover.extend(b["cover"])
            entries.append(dict(
                x=x, y=y, w=w, avail=avail,
                size=geom.text_size(h, body_h, plain(text)),
                fg=fg, bg=by_id[ids[0]].get("bg", [255, 253, 236]),
                cover=cover, ko=plain(text),
            ))

        # blocks the reader called artwork still need no cover, but blocks that
        # are text and must stay in English do -- they keep their own words.
        pages.append((page, entries))
        n_pages += 1
        n_blocks += len(entries)

    out = ["-- guide_ko_data.lua  --  자동 생성 파일. 직접 고치지 마세요.",
           "--",
           f"-- 페이지 {n_pages}개, 글 덩어리 {n_blocks}개.",
           "--",
           "-- 좌표는 1428x894 그림 위의 픽셀입니다. 위젯 단위와 1:1 이고 원점만",
           "-- 가운데로 옮기면 됩니다: ui_x = x - 714, ui_y = 447 - y.",
           "",
           "return {"]
    for page, entries in pages:
        out.append(f'\t["{page}"] = {{')
        for e in entries:
            cov = ",".join("{%d,%d,%d,%d}" % tuple(c) for c in e["cover"])
            out.append(
                "\t\t{x=%d,y=%d,w=%d,avail=%d,size=%d,fg={%d,%d,%d},bg={%d,%d,%d},cover={%s},ko=%s},"
                % (e["x"], e["y"], e["w"], e["avail"], e["size"],
                   e["fg"][0], e["fg"][1], e["fg"][2],
                   e["bg"][0], e["bg"][1], e["bg"][2], cov, lua_str(e["ko"])))
        out.append("\t},")
    out.append("}")
    Path(out_path).write_text("\n".join(out) + "\n", encoding="utf-8")
    return n_pages, n_blocks


if __name__ == "__main__":
    import sys
    a = sys.argv[1:]
    p, b = build(a[0], a[1], a[2])
    print(f"wrote {a[2]}  ({p} pages, {b} blocks)")
