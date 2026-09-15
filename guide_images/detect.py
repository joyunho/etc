"""Find the text on a guide page.

The pages use a tiny palette -- a flat cream page and four ink colours --
while the artwork is full colour with near-black outlines. So ink is found by
colour; then glyphs are found as connected components and clustered into
lines. Row profiles do not work here: the book frame and the item icons put a
floor of ink-ish pixels under every row, so a band never closes.
"""
import numpy as np
from PIL import Image
from scipy import ndimage

INKS = {
    "ink":   (90, 60, 33),      # body brown
    "gold":  (165, 150, 41),    # highlighted terms and sub-headings
    "navy":  (49, 60, 115),     # headings on the cream pages
    "plum":  (90, 56, 82),      # headings on the purple-trim pages
    "grey":  (74, 74, 74),      # the few near-black captions
}
TOL = 58

# a glyph of body text is about 8-17 px tall; a heading up to about 34
GLYPH = dict(hmin=4, hmax=40, wmax=90, amin=6, amax=1600)


def load(path):
    return np.asarray(Image.open(path).convert("RGB")).astype(int)


def ink_mask(a):
    m = np.zeros(a.shape[:2], bool)
    for rgb in INKS.values():
        m |= np.abs(a - np.array(rgb)).max(axis=2) < TOL
    return m



def page_mask(a):
    """The flat cream/ivory body of the page -- what real text sits on."""
    lo, hi = a.min(axis=2), a.max(axis=2)
    return (lo > 188) & (hi - lo < 52)


def page_body(pm, min_area=40000):
    """Only the page itself, not every pale patch that looks like it.

    A white skull outlined in black is page-coloured inside and its outline is
    ink, so by colour alone it is indistinguishable from writing and a cover
    box will happily be drawn straight across it. But the page background is
    one huge connected region, and the inside of the skull is a small island
    walled off by its own outline. Keeping only the big components separates
    them."""
    lab, n = ndimage.label(pm)
    if n == 0:
        return pm
    sizes = ndimage.sum_labels(pm, lab, range(1, n + 1))
    keep = np.zeros(n + 1, bool)
    keep[1:] = sizes >= min_area
    return keep[lab]


def artwork(a, min_area=26000):
    """Bounding boxes of the big non-page regions: embedded screenshots and
    character portraits. Any writing inside those is part of the picture."""
    holes = ~page_mask(a)
    holes = ndimage.binary_closing(holes, np.ones((3, 3)))
    lab, n = ndimage.label(holes)
    if n == 0:
        return []
    out = []
    for sl, i in zip(ndimage.find_objects(lab), range(1, n + 1)):
        ys, xs = sl
        h, w = ys.stop - ys.start, xs.stop - xs.start
        if h * w < min_area or h < 90 or w < 90:
            continue
        if w > 1300 and h > 700:          # the book frame itself
            continue
        # a screenshot or a portrait fills its box; a cluster of icons with
        # page showing between them does not, and must not swallow the text
        if (lab[sl] == i).sum() / float(h * w) < 0.62:
            continue
        out.append((xs.start, ys.start, xs.stop, ys.stop))
    return out


def icons(a, pm, ink, min_area=420):
    """Bounding boxes of the drawings on the page -- item icons, creature
    sprites, the little speed lines under a shoe.

    A drawing is what is neither the page nor a letter, so the mask is built
    from exactly that. It matters because a drawing's small dark details sit on
    the cream page and are the size and shape of letters: without this, the
    dashes beside an icon join the line of text next to them, and the line then
    claims to start 70 pixels further left and to be twice as tall as it is."""
    # The halo of half-tone pixels around a letter is neither page nor ink, and
    # closing turns a whole line of those halos into one big blob, which then
    # looks like a drawing and swallows the line. So grow the ink first -- but
    # only the letter-sized pieces of it. Growing all of it closes the gap
    # across an icon's own thin outline and the icon stops being found at all.
    lab, n = ndimage.label(ink, structure=np.ones((3, 3)))
    small = np.zeros_like(ink)
    if n:
        for sl, i in zip(ndimage.find_objects(lab), range(1, n + 1)):
            ys, xs = sl
            if ys.stop - ys.start <= 40 and xs.stop - xs.start <= 90:
                small[sl] |= (lab[sl] == i)
    blob = ~(pm | ndimage.binary_dilation(small, np.ones((5, 5))))
    blob = ndimage.binary_closing(blob, np.ones((3, 3)))
    lab, n = ndimage.label(blob)
    if n == 0:
        return []
    out = []
    for sl, i in zip(ndimage.find_objects(lab), range(1, n + 1)):
        ys, xs = sl
        h, w = ys.stop - ys.start, xs.stop - xs.start
        if h * w < min_area or h < 12 or w < 12:
            continue
        if w > 1300 and h > 700:
            continue
        out.append((xs.start - 2, ys.start - 2, xs.stop + 2, ys.stop + 2))
    return out


def on_page(a, pm, g, pad=2, need=0.42):
    """Is this component surrounded by page, rather than embedded in artwork?"""
    y0 = max(0, g["y0"] - pad); y1 = min(pm.shape[0], g["y1"] + pad)
    x0 = max(0, g["x0"] - pad); x1 = min(pm.shape[1], g["x1"] + pad)
    ring = pm[y0:y1, x0:x1].copy()
    inner = ring[pad:ring.shape[0] - pad, pad:ring.shape[1] - pad]
    tot = ring.sum() - inner.sum()
    n = ring.size - inner.size
    return n > 0 and tot / float(n) >= need


def glyphs(a, box, pm=None, art=None, ic=None):
    """Connected ink components that look like letters, not artwork.

    Two passes. The first also notes every ink component too big to be a
    letter: a white skull outlined in black is page plus ink all the way
    through, so the colour test cannot see it is a drawing, but its outline is
    one 70-pixel component and no letter is. The second pass then throws away
    the eye sockets and the teeth, which are letter-sized and would otherwise
    join the heading beside them and drag its box across the skull."""
    x0, y0, x1, y1 = box
    if pm is None:
        pm = page_mask(a)
    if art is None:
        art = artwork(a)
    ink = ink_mask(a)
    if ic is None:
        ic = icons(a, pm, ink)
    m = ink[y0:y1, x0:x1]
    lab, n = ndimage.label(m, structure=np.ones((3, 3)))
    if n == 0:
        return [], []

    cand, oversize = [], []
    for sl, i in zip(ndimage.find_objects(lab), range(1, n + 1)):
        ys, xs = sl
        h, w = ys.stop - ys.start, xs.stop - xs.start
        area = int((lab[sl] == i).sum())
        g = dict(x0=x0 + xs.start, x1=x0 + xs.stop,
                 y0=y0 + ys.start, y1=y0 + ys.stop, area=area)
        if h > GLYPH["hmax"] or w > GLYPH["wmax"] or area > GLYPH["amax"]:
            if h >= 18 and w >= 18:
                oversize.append((g["x0"] - 2, g["y0"] - 2, g["x1"] + 2, g["y1"] + 2))
            continue
        if not (GLYPH["hmin"] <= h <= GLYPH["hmax"]):      continue
        if not (GLYPH["amin"] <= area):                    continue
        if area / float(h * w) < 0.12:                     continue
        cand.append(g)

    drawings = list(art) + list(ic) + oversize
    out = []
    for g in cand:
        cx, cy = (g["x0"] + g["x1"]) // 2, (g["y0"] + g["y1"]) // 2
        if any(ax0 <= cx < ax1 and ay0 <= cy < ay1 for ax0, ay0, ax1, ay1 in drawings):
            continue
        if not on_page(a, pm, g):
            continue
        out.append(g)
    return out, oversize


def rows(gl, min_glyphs=2, min_w=18):
    """Cluster glyphs into text lines by vertical overlap."""
    if not gl:
        return []
    gl = sorted(gl, key=lambda g: (g["y0"], g["x0"]))
    lines = []
    for g in gl:
        gh = g["y1"] - g["y0"]
        placed = False
        for L in lines:
            lh = L["y1"] - L["y0"]
            lo, hi = max(L["y0"], g["y0"]), min(L["y1"], g["y1"])
            # same line if they share most of the shorter one's height
            if hi - lo > 0.55 * min(gh, lh) and abs(L["mid"] - (g["y0"] + g["y1"]) / 2) < 0.7 * max(gh, lh):
                L["y0"] = min(L["y0"], g["y0"]); L["y1"] = max(L["y1"], g["y1"])
                L["x0"] = min(L["x0"], g["x0"]); L["x1"] = max(L["x1"], g["x1"])
                L["n"] += 1; L["area"] += g["area"]
                L["mid"] = (L["y0"] + L["y1"]) / 2
                placed = True
                break
        if not placed:
            lines.append(dict(x0=g["x0"], x1=g["x1"], y0=g["y0"], y1=g["y1"],
                              mid=(g["y0"] + g["y1"]) / 2, n=1, area=g["area"]))
    out = [L for L in lines
           if L["n"] >= min_glyphs and L["x1"] - L["x0"] >= min_w and L["y1"] - L["y0"] >= 8]
    return sorted(out, key=lambda L: (L["y0"], L["x0"]))


def colour_of(a, L):
    sub = a[L["y0"]:L["y1"], L["x0"]:L["x1"]].reshape(-1, 3)
    best, bestn = "ink", 0
    for name, rgb in INKS.items():
        n = int((np.abs(sub - np.array(rgb)).max(axis=1) < TOL).sum())
        if n > bestn:
            best, bestn = name, n
    return best


def blocks(lns, gap=11, indent=30):
    """Group lines into paragraphs: close together, same left margin, same size."""
    out = []
    for L in lns:
        if out:
            prev = out[-1][-1]
            if (L["y0"] - prev["y1"] <= gap
                    and abs(L["x0"] - out[-1][0]["x0"]) <= indent
                    and abs((L["y1"] - L["y0"]) - (prev["y1"] - prev["y0"])) <= 7):
                out[-1].append(L); continue
        out.append([L])
    return out


COLUMNS = ((62, 36, 706, 862), (740, 36, 1376, 862))


def page(path):
    a = load(path)
    pm = page_mask(a)
    art = artwork(a)
    ic = icons(a, pm, ink_mask(a))
    res, big = [], []
    for box in COLUMNS:
        gl, oversize = glyphs(a, box, pm, art, ic)
        big.extend(oversize)
        lns = rows(gl)
        # a line that sits wholly inside a drawing is part of the drawing
        lns = [L for L in lns
               if not any(ix0 <= L["x0"] and L["x1"] <= ix1 and iy0 <= L["y0"] and L["y1"] <= iy1
                          for ix0, iy0, ix1, iy1 in ic)]
        for b in blocks(lns):
            res.append(b)
    return a, res, art, ic, big
