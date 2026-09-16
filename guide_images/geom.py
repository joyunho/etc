"""Turn every guide page into a list of text blocks with real coordinates,
and draw a numbered copy of the page so a reader can say which block is which."""
import json, os, sys, statistics
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import detect
import numpy as np
from scipy import ndimage
from PIL import Image, ImageDraw, ImageFont

S = os.environ.get("GUIDE_WORK", "work")
TABS = {"basic_guide": 12, "perk_abilities": 8, "perk_attributes": 2, "perk_expert": 45,
        "perk_global": 6, "perk_instant": 2, "perk_produce": 10, "rog": 35}


def trim_to_page(solid, blocked, x0, y0, x1, y1, need=0.72, run=5):
    """Pull a cover box in until both ends sit on the page.

    Over a line of writing, every column is either a letter or the page behind
    it, so ink-or-page covers essentially the whole column. Over a drawing --
    an item icon to the left of the line, a character portrait beside it -- it
    does not. That difference is what stops the overlay painting a cream
    rectangle across somebody's face."""
    band = solid[y0:y1, :]
    if band.shape[0] == 0:
        return x0, x1
    col = band.mean(axis=0)
    hit = blocked[y0:y1, :].any(axis=0)

    def good(x):
        # a white icon -- a skull, a bone, a page-coloured shield -- reads as
        # page, so "ink or page" alone will happily paint straight over it.
        return x1 > x >= 0 and col[x] >= need and not hit[x]

    a = x0
    while a < x1 and not all(good(a + k) for k in range(min(run, x1 - a))):
        a += 1
    b = x1
    while b > a and not all(good(b - 1 - k) for k in range(min(run, b - a))):
        b -= 1
    return (a, b) if b - a >= 6 else (x0, x1)


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


def page_colour(a, pm, cover, fallback=(255, 253, 236)):
    """The colour to paint over the English with.

    Sampled from the page around the writing, never assumed: the pages are
    cream in the body, ivory in the margins, and a coloured panel here and
    there. And sampled only where the page mask says it really is page -- a
    strip taken blindly above a line can land on the row of icons or on a dark
    panel, and then the overlay paints a dark rectangle across a cream row."""
    picks = []
    for x0, y0, x1, y1 in cover:
        lo, hi = max(0, y0 - 6), min(a.shape[0], y1 + 6)
        region = a[lo:hi, x0:x1]
        mask = pm[lo:hi, x0:x1]
        if mask.sum() >= 40:
            picks.append(np.median(region[mask], axis=0))
    if not picks:
        return list(fallback)
    return [int(v) for v in np.median(np.array(picks), axis=0)]


def margins(cov_all, tol=5, least=3):
    """The left edges the writing on this page actually uses.

    Every column of text starts at one of a small number of x positions -- a
    title margin, a body margin -- and they repeat down the page. Edges that
    only one box claims are not margins, they are mistakes."""
    xs = sorted(c["x0"] for c in cov_all)
    out, i = [], 0
    while i < len(xs):
        j = i
        while j < len(xs) and xs[j] - xs[i] <= tol:
            j += 1
        if j - i >= least:
            out.append(int(statistics.median(xs[i:j])))
        i = j
    return out


def push_off_drawings(draw_px, cov, edges, need=0.03):
    """Move a cover box's left edge off a drawing it is sitting on.

    Some icons cannot be told from writing by colour at all -- a white skull
    outlined in black is page inside and ink around, and its outline is broken
    so the inside is not even walled off. What does give it away is that the
    strip of page between the box's edge and where the writing really starts is
    full of pixels that are neither page nor ink. Real text has almost none.
    So when that strip is dirty, the edge moves up to the next margin the page
    itself uses.

    This catches the clear cases only. A white skull outlined in black leaves
    barely twice the smudge of a perfectly clean title strip (0.009 against
    0.005 measured), which is too close to call in pixels. Those are left to
    the reader looking at the page, who can see it at a glance; the margins
    are published in the geometry file so the fix is a choice between two
    numbers rather than a guess at a coordinate."""
    for c in cov:
        for e in edges:
            if e <= c["x0"] + 4 or e >= c["x1"]:
                continue
            strip = draw_px[c["y0"]:c["y1"], c["x0"]:e]
            if strip.size and strip.mean() >= need:
                c["x0"] = e
            break


def describe(path):
    a, blocks, art, ic, big = detect.page(path)
    ink = detect.ink_mask(a)
    pm = detect.page_mask(a)
    body = detect.page_body(pm)
    solid = ndimage.binary_closing(ink | body, np.ones((3, 3)))
    draw_px = ~(pm | ndimage.binary_dilation(ink, np.ones((3, 3))))
    blocked = np.zeros(pm.shape, bool)
    for ix0, iy0, ix1, iy1 in ic:
        blocked[max(0, iy0):iy1, max(0, ix0):ix1] = True
    staged = []
    for b in blocks:
        cov = cover_boxes(b)
        for c in cov:
            c["x0"], c["x1"] = trim_to_page(solid, blocked, c["x0"], c["y0"], c["x1"], c["y1"])
            if not any(ax0 <= c["x1"] < ax1 and ay0 <= c["y0"] < ay1
                       for ax0, ay0, ax1, ay1 in art):
                grown = extend_right(ink, pm, c["x0"], c["y0"], c["x1"], c["y1"])
                # only keep the growth while it stays on the page
                _, grown = trim_to_page(solid, blocked, c["x0"], c["y0"], grown, c["y1"])
                c["x1"] = max(c["x1"], grown)
        cov = [c for c in cov if c["x1"] - c["x0"] >= 6]
        if cov:
            staged.append((b, cov))

    # margins are a property of the page, so they need every box first
    page_margins = {}
    for name, lo, hi in (("L", 0, 720), ("R", 720, 1428)):
        half = [c for _, cov in staged for c in cov if lo <= c["x0"] < hi]
        edges = margins(half)
        page_margins[name] = edges
        for _, cov in staged:
            push_off_drawings(draw_px, [c for c in cov if lo <= c["x0"] < hi], edges)

    out = []
    for i, (b, cov) in enumerate(staged, 1):
        cov = [c for c in cov if c["x1"] - c["x0"] >= 6]
        if not cov:
            continue
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
            colour=detect.colour_of(a, dict(x0=cov[0]["x0"], x1=cov[0]["x1"],
                                            y0=cov[0]["y0"], y1=cov[0]["y1"])),
            bg=page_colour(a, pm, [[c["x0"], c["y0"], c["x1"], c["y1"]] for c in cov]),
            budget=len(b) * max(4, int((max(c["x1"] for c in cov) - min(c["x0"] for c in cov))
                                       / (statistics.median(heights) * 0.96))),
            side="L" if min(c["x0"] for c in cov) < 720 else "R",
            cover=[[c["x0"], c["y0"], c["x1"], c["y1"]] for c in cov],
        ))
    return out, art, page_margins


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
            blocks, art, page_margins = describe(src)
            json.dump(dict(page=name, artwork=art, margins=page_margins, blocks=blocks),
                      open(f"{S}/geom/{name}.json", "w"), ensure_ascii=False, indent=1)
            annotate(src, blocks, f"{S}/annot/{name}.png")
            index[name] = len(blocks)
            total += len(blocks)
    json.dump(index, open(f"{S}/geom/index.json", "w"), indent=1)
    print(f"{len(index)} pages, {total} blocks")


if __name__ == "__main__":
    main()


def widen(a, cover, ic, limit=16, gap=12, dirt=0.03, near=70):
    """Grow a finished cover box over the last few pixels of English beside it.

    The boxes are measured from clustered letters, so anything the clusterer
    would not take -- a bullet's leading hyphen, a lone digit, the first stroke
    of a capital that sits in the page-edge shading -- ends up just outside,
    and survives the paint as a sliver of English next to the Korean. This
    walks outward from both ends and absorbs ink that is only a few pixels
    away, provided the ground it crosses is page rather than drawing.

    Applied after the geometry is settled and keyed by nothing but the box, so
    it can be re-tuned without renumbering the blocks a reader has already
    worked on."""
    ink = detect.ink_mask(a)
    pm = detect.page_mask(a)
    draw_px = ~(pm | ndimage.binary_dilation(ink, np.ones((3, 3))))
    blocked = np.zeros(pm.shape, bool)
    for ix0, iy0, ix1, iy1 in ic:
        blocked[max(0, iy0):iy1, max(0, ix0):ix1] = True

    out = []
    for x0, y0, x1, y1 in cover:
        lo, hi = max(0, y0 - 1), min(a.shape[0], y1 + 1)

        base = np.array(page_colour(a, pm, [[x0, y0, x1, y1]]))

        def clean(p, q):
            if q <= p:
                return True
            if blocked[lo:hi, p:q].any():
                return False
            strip = draw_px[lo:hi, p:q]
            if strip.size == 0 or strip.mean() < dirt:
                return True
            # The page-edge shading is not page and not ink, so it reads as
            # drawing, but it is only the page a little darker. Crossing it
            # costs a faint notch; not crossing it leaves a capital letter
            # standing in English. Cross it, but only while it stays close to
            # the page colour -- a real drawing never is.
            patch = a[lo:hi, p:q].reshape(-1, 3)
            return bool(patch.size) and np.abs(patch - base).max(axis=1).max() < near

        left = x0
        while x0 - left < limit:
            p = max(0, left - gap)
            band = ink[lo:hi, p:left]
            if band.size == 0 or not band.any():
                break
            cols = np.nonzero(band.sum(axis=0))[0]
            first = p + int(cols[0])
            if not clean(first, left):
                break
            left = first
        right = x1
        while right - x1 < limit:
            q = min(a.shape[1], right + gap)
            band = ink[lo:hi, right:q]
            if band.size == 0 or not band.any():
                break
            cols = np.nonzero(band.sum(axis=0))[0]
            last = right + int(cols[-1]) + 1
            if not clean(right, last):
                break
            right = last
        out.append([max(0, left), y0, right, y1])
    return out


def widen_page(page, blocks, work=None):
    """widen() for a whole page, loading what it needs off disk."""
    work = work or S
    a = detect.load(f"{work}/pages/{page}.png")
    ic = detect.icons(a, detect.page_mask(a), detect.ink_mask(a))
    for b in blocks:
        b["cover"] = widen(a, b["cover"], ic)
        b["x"] = min(c[0] for c in b["cover"])
        b["w"] = max(c[2] for c in b["cover"]) - b["x"]
    return blocks


def body_height(blocks):
    """The height of ordinary body text on this page.

    Taken from the blocks that have more than one line, because those are
    certainly paragraphs: a single-line block can be a heading, or a stat row
    whose measured height was inflated by an icon that got clustered into it."""
    hs = sorted(b["h"] for b in blocks)
    if not hs:
        return 17
    # the taller half is headings and rows an icon inflated, so take the
    # middle of the shorter half -- that is the paragraph text
    cut = hs[:max(1, int(len(hs) * 0.6))]
    return int(statistics.median(cut))


def text_size(h, body, text):
    """How big to set a block's Korean.

    A block's own measured height is the right answer for a heading, and the
    wrong one for a row of stats whose heart icon joined the line and doubled
    it. Length tells them apart: headings are short. Anything long is body
    text and is held near the page's own body size, so a mismeasured row can
    no longer print at twice the size of the paragraph beside it."""
    size = h + 1
    if len(text) > 12:
        size = min(size, body + 2)      # long means body text, whatever the box says
    return max(9, size)
