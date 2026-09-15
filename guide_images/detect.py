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


def on_page(a, pm, g, pad=2, need=0.42):
    """Is this component surrounded by page, rather than embedded in artwork?"""
    y0 = max(0, g["y0"] - pad); y1 = min(pm.shape[0], g["y1"] + pad)
    x0 = max(0, g["x0"] - pad); x1 = min(pm.shape[1], g["x1"] + pad)
    ring = pm[y0:y1, x0:x1].copy()
    inner = ring[pad:ring.shape[0] - pad, pad:ring.shape[1] - pad]
    tot = ring.sum() - inner.sum()
    n = ring.size - inner.size
    return n > 0 and tot / float(n) >= need


def glyphs(a, box, pm=None, art=None):
    """Connected ink components that look like letters, not artwork."""
    x0, y0, x1, y1 = box
    if pm is None:
        pm = page_mask(a)
    if art is None:
        art = artwork(a)
    m = ink_mask(a)[y0:y1, x0:x1]
    lab, n = ndimage.label(m, structure=np.ones((3, 3)))
    if n == 0:
        return []
    out = []
    for sl, i in zip(ndimage.find_objects(lab), range(1, n + 1)):
        ys, xs = sl
        h, w = ys.stop - ys.start, xs.stop - xs.start
        area = int((lab[sl] == i).sum())
        if not (GLYPH["hmin"] <= h <= GLYPH["hmax"]):      continue
        if w > GLYPH["wmax"]:                              continue
        if not (GLYPH["amin"] <= area <= GLYPH["amax"]):   continue
        if area / float(h * w) < 0.12:                     continue
        g = dict(x0=x0 + xs.start, x1=x0 + xs.stop,
                 y0=y0 + ys.start, y1=y0 + ys.stop, area=area)
        cx, cy = (g["x0"] + g["x1"]) // 2, (g["y0"] + g["y1"]) // 2
        if any(ax0 <= cx < ax1 and ay0 <= cy < ay1 for ax0, ay0, ax1, ay1 in art):
            continue
        if not on_page(a, pm, g):
            continue
        out.append(g)
    return out


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
    out = [L for L in lines if L["n"] >= min_glyphs and L["x1"] - L["x0"] >= min_w]
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
    res = []
    for box in COLUMNS:
        lns = rows(glyphs(a, box, pm, art))
        for b in blocks(lns):
            res.append(b)
    return a, res, art
