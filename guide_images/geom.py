"""Turn every guide page into a list of text blocks with real coordinates,
and draw a numbered copy of the page so a reader can say which block is which."""
import json, os, sys, statistics
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import detect
import numpy as np
from PIL import Image, ImageDraw, ImageFont

S = os.environ.get("GUIDE_WORK", "work")
TABS = {"basic_guide": 12, "perk_abilities": 8, "perk_attributes": 2, "perk_expert": 45,
        "perk_global": 6, "perk_instant": 2, "perk_produce": 10, "rog": 35}


def cover_boxes(block):
    """Tight rectangles to paint over, one per line.

    A line whose left edge runs far past the paragraph's margin has picked up a
    piece of the icon beside it; clamp it back so the icon is never painted."""
    left = statistics.median([l["x0"] for l in block])
    right = max(l["x1"] for l in block)
    out = []
    for l in block:
        x0 = max(l["x0"], int(left) - 4)
        out.append(dict(x0=x0, y0=l["y0"], x1=min(l["x1"], right), y1=l["y1"]))
    return out


def extend_right(ink, pm, x0, y0, x1, y1, limit=26, gap=9):
    """Push a cover box right over the trailing punctuation the glyph finder
    dropped -- a lone period or colon is too small to cluster into its line.

    Walks in small steps and stops at the first real gap, so the page's own
    edge decoration a few dozen pixels further out is never painted over."""
    end, x = x1, x1
    while x - x1 < limit:
        stop = min(ink.shape[1], x + gap)
        band = ink[max(0, y0 - 1):y1 + 1, x:stop]
        if band.size == 0 or not band.any():
            break
        cols = np.nonzero(band.sum(axis=0))[0]
        last = x + int(cols[-1]) + 1
        if not pm[max(0, y0 - 1):y1 + 1, x:last].any():
            break                      # not sitting on the page: artwork
        end, x = last, last
    return min(end, x1 + limit)


def page_colour(a, cover):
    """The page colour just outside a block's lines -- what the overlay paints
    over the English with. Sampled, never assumed: the pages are cream on the
    right and a blue or grey panel in places, and a wrong fill shows."""
    picks = []
    for x0, y0, x1, y1 in cover:
        for yy in (max(0, y0 - 5), min(a.shape[0] - 1, y1 + 4)):
            strip = a[yy, x0:x1]
            if len(strip):
                picks.append(np.median(strip, axis=0))
    if not picks:
        return [255, 253, 236]
    return [int(v) for v in np.median(np.array(picks), axis=0)]


def describe(path):
    a, blocks, art = detect.page(path)
    ink = detect.ink_mask(a)
    pm = detect.page_mask(a)
    out = []
    for i, b in enumerate(blocks, 1):
        cov = cover_boxes(b)
        for c in cov:
            if not any(ax0 <= c["x1"] < ax1 and ay0 <= c["y0"] < ay1
                       for ax0, ay0, ax1, ay1 in art):
                c["x1"] = extend_right(ink, pm, c["x0"], c["y0"], c["x1"], c["y1"])
        heights = [l["y1"] - l["y0"] for l in b]
        leads = [b[j + 1]["y0"] - b[j]["y0"] for j in range(len(b) - 1)]
        out.append(dict(
            id=i,
            x=min(c["x0"] for c in cov),
            y=b[0]["y0"],
            w=max(c["x1"] for c in cov) - min(c["x0"] for c in cov),
            lines=len(b),
            h=int(statistics.median(heights)),
            lead=int(statistics.median(leads)) if leads else int(statistics.median(heights)) + 4,
            colour=detect.colour_of(a, b[0]),
            bg=page_colour(a, [[c["x0"], c["y0"], c["x1"], c["y1"]] for c in cov]),
            budget=len(b) * max(4, int((max(c["x1"] for c in cov) - min(c["x0"] for c in cov))
                                       / (statistics.median(heights) * 0.96))),
            side="L" if min(c["x0"] for c in cov) < 720 else "R",
            cover=[[c["x0"], c["y0"], c["x1"], c["y1"]] for c in cov],
        ))
    return out, art


def annotate(path, blocks, out):
    im = Image.open(path).convert("RGB")
    d = ImageDraw.Draw(im)
    f = ImageFont.truetype(S + "/tex/fonts/NotoSansKR-Bold.ttf", 15)
    for b in blocks:
        x0 = min(c[0] for c in b["cover"]); y0 = min(c[1] for c in b["cover"])
        x1 = max(c[2] for c in b["cover"]); y1 = max(c[3] for c in b["cover"])
        d.rectangle((x0 - 2, y0 - 2, x1 + 2, y1 + 2), outline=(230, 30, 30), width=2)
        tag = str(b["id"])
        tw = d.textlength(tag, font=f)
        d.rectangle((x0 - 2 - tw - 7, y0 - 2, x0 - 4, y0 + 17), fill=(230, 30, 30))
        d.text((x0 - tw - 6, y0), tag, font=f, fill=(255, 255, 255))
    im.save(out)


def main():
    os.makedirs(S + "/geom", exist_ok=True)
    os.makedirs(S + "/annot", exist_ok=True)
    index, total = {}, 0
    for tab, cnt in TABS.items():
        for i in range(1, cnt + 1):
            name = f"{tab}_{i}"
            src = f"{S}/pages/{name}.png"
            blocks, art = describe(src)
            json.dump(dict(page=name, artwork=art, blocks=blocks),
                      open(f"{S}/geom/{name}.json", "w"), ensure_ascii=False, indent=1)
            annotate(src, blocks, f"{S}/annot/{name}.png")
            index[name] = len(blocks)
            total += len(blocks)
    json.dump(index, open(f"{S}/geom/index.json", "w"), indent=1)
    print(f"{len(index)} pages, {total} blocks")


if __name__ == "__main__":
    main()
