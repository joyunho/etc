"""Simulate how raiders, sappers and breachers path into a plan (plan.json / plan_hard.json).

The plan sits in the middle of a square map of open ground. Raiders spawn on the
map edge. Each raider type runs Dijkstra toward the owned beds (bedrooms, prison,
school cribs) with RimWorld-like costs:

  step            cardinal 13, diagonal 18; no corner cutting past a blocked tile
  wall (dig)      WALL_BASE + WALL_PER_HP * hp
  door (bash)     DOOR_BASE + DOOR_PER_HP * hp
  turret cover    avoid grid as in RimWorld 1.6 (AvoidGrid / AvoidGridTuning): every turret adds 45 to each
                  walkable tile within range + 4 that it can see, capped at 255, then wall and building
                  tiles take the highest value of their 8 neighbours; the path finder adds value x 8
  known trap      TRAP_KNOWN (a fraction KNOWN_CHANCE of traps is known)
  fence / sandbag extra path cost 80 / 42

Modes:
  sapper          digs walls and doors, avoids turret cover, knows some traps
  breach          digs walls and doors, ignores turret cover (standard breach raid)
  smart_breach    like breach but avoids turret cover
  walker          cannot pass walls or closed doors (normal and smart assaults)

Usage: python -I sim_raids.py <plan.json> [--map 250] [--step 10] [--params params.json] [--png out.png]
"""
import heapq
import json
import math
import random
import sys

P = {
    "CARD": 13, "DIAG": 18,
    "WALL_BASE": 70, "WALL_PER_HP": 0.2, "DOOR_BASE": 50, "DOOR_PER_HP": 0.2,
    "WALL_HP": 510, "DOOR_HP": 272,          # granite wall 300x1.7; granite door 160x1.7
    "AVOID_PER_TURRET": 45, "AVOID_CAP": 255, "AVOID_FACTOR": 8, "TURRET_RANGE": 28.9, "RANGE_EXTRA": 4,
    "TRAP_KNOWN": 800, "KNOWN_CHANCE": 0.3,
    "FENCE": 80, "SANDBAG": 42,
}
BLOCKING_FEATURES = {"turret", "generator", "wastepack", "engine", "console", "tank", "thruster",
                     "graves", "centrepiece", "anchor", "solar"}
SIGHT_BLOCKING_FEATURES = {"wastepack", "engine"}


def load(plan_path, map_size, upto=99):
    plan = json.load(open(plan_path, encoding="utf-8"))
    ox, oy = plan["origin"]
    half = map_size // 2
    n = map_size
    kind = bytearray(n * n)          # 0 ground, 1 wall, 2 door, 3 floor, 4 blocked building
    extra = [0] * (n * n)           # path cost on top of the step
    room = [None] * (n * n)
    part = {}
    idx = lambda x, y: (y + half) * n + (x + half)
    for j, row in enumerate(plan["cells"]):
        for i, (t, rm, ph, dph) in enumerate(row):
            x, y = i + ox, j + oy
            k = idx(x, y)
            kind[k] = {"ground": 0, "wall": 1, "door": 2, "gate": 2, "floor": 3}[t]
            room[k] = rm
            if ph and ph > upto:          # not built yet: open ground (a room floor stays walkable)
                kind[k] = 0 if t in ("wall", "door", "gate") else (3 if t == "floor" else 0)
            elif t == "door" and dph and dph > upto:
                kind[k] = 1               # door slot still walled up
    feats = {}
    for f in plan["features"]:
        if f["phase"] <= upto or f["kind"] in ("hole", "court", "lane"):
            feats.setdefault(f["kind"], []).extend(tuple(c) for c in f["cells"])
    for kname in BLOCKING_FEATURES:
        for (x, y) in feats.get(kname, []):
            if kind[idx(x, y)] in (0, 3):
                kind[idx(x, y)] = 4
    for (x, y) in feats.get("fence", []):
        extra[idx(x, y)] += P["FENCE"]
    for (x, y) in feats.get("sandbags", []):
        extra[idx(x, y)] += P["SANDBAG"]
    beds = []
    for r in plan["rooms"]:
        if r["kind"] in ("bedroom", "prison", "school"):
            beds.append((r["key"], tuple(r["center"])))
    return plan, n, half, idx, kind, extra, room, feats, beds


def sight_line(x0, y0, x1, y1):
    """Bresenham cells between the ends (exclusive of the start, inclusive of the end)."""
    dx, dy = abs(x1 - x0), -abs(y1 - y0)
    sx, sy = (1 if x0 < x1 else -1), (1 if y0 < y1 else -1)
    err = dx + dy
    x, y = x0, y0
    while (x, y) != (x1, y1):
        e2 = 2 * err
        if e2 >= dy:
            err += dy
            x += sx
        if e2 <= dx:
            err += dx
            y += sy
        yield x, y


def avoid_grid(n, half, idx, kind, feats):
    """Number of turrets that see each tile (walkable tiles within range + extra, with line of sight)."""
    cover = [0] * (n * n)
    blocks_sight = lambda k: kind[k] in (1, 2)
    sight_blockers = {idx(x, y) for kname in SIGHT_BLOCKING_FEATURES for (x, y) in feats.get(kname, [])}
    rad = P["TURRET_RANGE"] + P["RANGE_EXTRA"]
    r_int = int(rad) + 1
    for (tx, ty) in feats.get("turret", []):
        for y in range(ty - r_int, ty + r_int + 1):
            for x in range(tx - r_int, tx + r_int + 1):
                if (x - tx) ** 2 + (y - ty) ** 2 > rad * rad:
                    continue
                if not (-half <= x < half and -half <= y < half):
                    continue
                k = idx(x, y)
                if kind[k] not in (0, 3):
                    continue
                ok = True
                for (cx, cy) in sight_line(tx, ty, x, y):
                    if (cx, cy) == (x, y):
                        break
                    kk = idx(cx, cy)
                    if blocks_sight(kk) or kk in sight_blockers:
                        ok = False
                        break
                if ok:
                    cover[k] = min(P["AVOID_CAP"], cover[k] + P["AVOID_PER_TURRET"])
    # ExpandAvoidGridIntoEdifices: walls/doors/buildings next to a covered tile take the highest neighbour value
    expanded = list(cover)
    for k in range(n * n):
        if cover[k] and kind[k] in (0, 3):
            y, x = divmod(k, n)
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    xx, yy = x + dx, y + dy
                    if (dx or dy) and 0 <= xx < n and 0 <= yy < n:
                        kk = yy * n + xx
                        if kind[kk] in (1, 2, 4):
                            expanded[kk] = max(expanded[kk], cover[k])
    return expanded


def dijkstra(n, half, idx, kind, extra, cover, known_traps, src, mode):
    """Costs from src to every tile (reverse search from a bed: costs are paid on entering a tile)."""
    INF = float("inf")
    dist = [INF] * (n * n)
    prev = [-1] * (n * n)
    s = idx(*src)
    dist[s] = 0
    heap = [(0, s)]
    wall_cost = P["WALL_BASE"] + P["WALL_PER_HP"] * P["WALL_HP"]
    door_cost = P["DOOR_BASE"] + P["DOOR_PER_HP"] * P["DOOR_HP"]
    dig = mode in ("sapper", "breach", "smart_breach")
    avoid = mode in ("sapper", "smart_breach")
    use_traps = mode == "sapper"
    steps = [(1, 0, P["CARD"]), (-1, 0, P["CARD"]), (0, 1, P["CARD"]), (0, -1, P["CARD"]),
             (1, 1, P["DIAG"]), (1, -1, P["DIAG"]), (-1, 1, P["DIAG"]), (-1, -1, P["DIAG"])]

    def enter_cost(k):
        t = kind[k]
        av = P["AVOID_FACTOR"] * cover[k] if avoid else 0
        if t in (0, 3):
            c = extra[k] + av
            if use_traps and k in known_traps:
                c += P["TRAP_KNOWN"]
            return c
        if not dig:
            return None
        if t == 1:
            return wall_cost + av
        if t == 2:
            return door_cost + av
        return wall_cost + av   # other impassable buildings: dug like a wall

    def blocked(k):
        return kind[k] in (1, 2, 4)

    while heap:
        d, k = heapq.heappop(heap)
        if d != dist[k]:
            continue
        y, x = divmod(k, n)
        x -= half
        y -= half
        for dx, dy, step in steps:
            nx, ny = x + dx, y + dy
            if not (-half <= nx < half and -half <= ny < half):
                continue
            nk = idx(nx, ny)
            if dx and dy and (blocked(idx(x + dx, y)) or blocked(idx(x, y + dy))):
                continue
            c = enter_cost(nk)
            if c is None:
                continue
            nd = d + step + c
            if nd < dist[nk]:
                dist[nk] = nd
                prev[nk] = k
                heapq.heappush(heap, (nd, nk))
    return dist, prev


def edge_points(half, step):
    pts = []
    for v in range(-half, half, step):
        pts += [(v, -half), (v, half - 1), (-half, v), (half - 1, v)]
    return sorted(set(pts))


def classify(path_cells, kind, room, idx, feats):
    """Where the path gets in: through the hole, or by digging somewhere."""
    hole = set(map(tuple, feats.get("hole", [])))
    court = set(map(tuple, feats.get("court", [])))
    dug = [(x, y) for (x, y) in path_cells if kind[idx(x, y)] in (1, 2, 4)]
    through_hole = any(c in hole for c in path_cells)
    in_court = any(c in court for c in path_cells)
    first_dig = None
    for (x, y) in path_cells:
        if kind[idx(x, y)] in (1, 2, 4):
            first_dig = (x, y)
            break
    return through_hole, in_court, dug, first_dig


def main(argv):
    plan_path = argv[0]
    map_size = int(argv[argv.index("--map") + 1]) if "--map" in argv else 250
    step = int(argv[argv.index("--step") + 1]) if "--step" in argv else 10
    if "--params" in argv:
        P.update(json.load(open(argv[argv.index("--params") + 1])))
    modes = argv[argv.index("--modes") + 1].split(",") if "--modes" in argv else ["sapper", "smart_breach", "breach", "walker"]
    seeds = int(argv[argv.index("--seeds") + 1]) if "--seeds" in argv else 3
    upto = int(argv[argv.index("--phase") + 1]) if "--phase" in argv else 99
    plan, n, half, idx, kind, extra, room, feats, beds = load(plan_path, map_size, upto)
    cover = avoid_grid(n, half, idx, kind, feats)
    traps = [idx(x, y) for (x, y) in feats.get("trap", [])]
    spawns = edge_points(half, step)
    report = {"params": dict(P), "map": map_size, "spawns": len(spawns), "beds": [b[0] for b in beds], "modes": {}}
    paths_out = {}
    for mode in modes:
        trap_sets = [set()] if mode != "sapper" else [
            set(random.Random(s).sample(traps, round(len(traps) * P["KNOWN_CHANCE"]))) for s in range(seeds)]
        total = hole_n = court_n = 0
        dig_sites = {}
        unreachable = 0
        lane_steps = []
        targets = beds
        if mode == "walker":
            # normal raiders cannot open doors: check they can reach the hole, and how
            targets = [("hole", tuple(feats["hole"][0]))] if feats.get("hole") else beds
        for ts_i, known in enumerate(trap_sets):
            for key, bed in targets:
                dist, prev = dijkstra(n, half, idx, kind, extra, cover, known, bed, mode)
                for sp in spawns:
                    k = idx(*sp)
                    if dist[k] == float("inf"):
                        unreachable += 1
                        continue
                    cells = []
                    while k != -1:
                        y, x = divmod(k, n)
                        cells.append((x - half, y - half))
                        k = prev[k]
                    # cells runs spawn -> bed
                    through_hole, in_court, dug, first_dig = classify(cells, kind, room, idx, feats)
                    if mode == "walker":
                        lane = set(map(tuple, feats.get("lane", [])))
                        on_lane = sum(1 for c in cells if c in lane)
                        lane_steps.append(on_lane)
                    total += 1
                    hole_n += through_hole
                    court_n += in_court
                    if not through_hole and first_dig:
                        dig_sites[first_dig] = dig_sites.get(first_dig, 0) + 1
                    if ts_i == 0 and (key, sp) not in paths_out and len(paths_out) < 4000:
                        paths_out[(mode, key, sp)] = cells
        report["modes"][mode] = {
            "paths": total, "unreachable": unreachable,
            "through_hole_pct": round(100 * hole_n / total, 1) if total else None,
            "through_courtyard_pct": round(100 * court_n / total, 1) if total else None,
            "other_entries": sorted(dig_sites.items(), key=lambda kv: -kv[1])[:12],
        }
        if lane_steps:
            report["modes"][mode]["lane_tiles_min_max"] = [min(lane_steps), max(lane_steps)]
        print(mode, json.dumps(report["modes"][mode], ensure_ascii=False))
    out = argv[argv.index("--out") + 1] if "--out" in argv else plan_path.rsplit(".", 1)[0] + "_sim.json"
    report["phase"] = upto
    json.dump({"report": report, "cover": None}, open(out, "w"), ensure_ascii=False)
    if "--png" in argv:
        draw(plan, n, half, idx, kind, cover, paths_out, argv[argv.index("--png") + 1], feats)
    return report


def draw(plan, n, half, idx, kind, cover, paths_out, out_png, feats):
    from PIL import Image, ImageDraw
    T = 4
    img = Image.new("RGB", (n * T, n * T), (214, 199, 168))
    d = ImageDraw.Draw(img)
    for y in range(-half, half):
        for x in range(-half, half):
            k = idx(x, y)
            px, py = (x + half) * T, (y + half) * T
            if kind[k] == 1:
                d.rectangle([px, py, px + T - 1, py + T - 1], fill=(70, 74, 80))
            elif kind[k] == 2:
                d.rectangle([px, py, px + T - 1, py + T - 1], fill=(214, 150, 44))
            elif kind[k] == 4:
                d.rectangle([px, py, px + T - 1, py + T - 1], fill=(120, 110, 100))
            elif cover[k]:
                shade = max(120, 214 - 30 * (cover[k] // 45))
                d.rectangle([px, py, px + T - 1, py + T - 1], fill=(214, shade, shade))
    colors = {"sapper": (30, 60, 200), "smart_breach": (140, 40, 170), "breach": (200, 40, 40), "walker": (20, 140, 60)}
    for (mode, key, sp), cells in paths_out.items():
        pts = [((x + half) * T + T // 2, (y + half) * T + T // 2) for (x, y) in cells]
        d.line(pts, fill=colors.get(mode, (0, 0, 0)), width=1)
    img.save(out_png)
    print("saved", out_png)


if __name__ == "__main__":
    main(sys.argv[1:])
