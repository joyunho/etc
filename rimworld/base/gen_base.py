"""Generate a round, efficient RimWorld base plan on the tile grid.

Layout ("rosette"):
  - Ø13 great hall in the middle (dining + recreation)
  - inner ring of work rooms out to Ø25
  - a 2-wide ring corridor between Ø25 and Ø31
  - outer ring of bedrooms and big rooms out to the Ø45 outer wall
  - four 3-wide avenues on the compass axes, gates at their ends
  - outside: killbox (south), crop arcs (west), gravship pad (east),
    solar arc and graves (north), wastepack freezer (south-east)

Every ring is a band of tiles at a whole radius, so the in-game
「빈 타원」 (empty oval) draw style with a square drag of the same
diameter gives the same shape.

Usage: python -I gen_base.py <out_dir>
Writes plan.json (for the blueprint page) and plan.png (for the README).
"""
import collections
import json
import math
import sys

R_HALL, R_IN, R_MID, R_OUT = 6, 12, 15, 22
ARM_HALF, ARM_WALL = 1, 2

# canvas around the base centre
W_MIN, W_MAX = -32, 45      # dx range
H_MIN, H_MAX = -30, 34      # dy range (screen y grows downward = south)
CX, CY = -W_MIN, -H_MIN
WIDTH, HEIGHT = W_MAX - W_MIN + 1, H_MAX - H_MIN + 1

GROUND, WALL, DOOR, FLOOR, GATE = "ground", "wall", "door", "floor", "gate"


def polar(dx, dy):
    r = math.hypot(dx, dy)
    ang = math.degrees(math.atan2(-dy, dx)) % 360.0
    return r, ang


def in_band(r, radius):
    return radius - 0.5 <= r < radius + 0.5


def on_ray(dx, dy, ang_deg):
    """4-connected digital ray from the centre at the given angle."""
    a = math.radians(ang_deg)
    ux, uy = math.cos(a), -math.sin(a)
    if dx * ux + dy * uy <= 0:
        return False
    dist = abs(dx * uy - dy * ux)
    return dist < 0.5 * (abs(ux) + abs(uy))


def arm_axis(dx, dy):
    """Return (axis_name, offset, along) if the cell lies on an avenue strip."""
    if abs(dx) <= ARM_WALL and dy < 0:
        return "N", dx, -dy
    if abs(dx) <= ARM_WALL and dy > 0:
        return "S", dx, dy
    if abs(dy) <= ARM_WALL and dx > 0:
        return "E", dy, dx
    if abs(dy) <= ARM_WALL and dx < 0:
        return "W", dy, -dx
    return None


# Rooms: (key, Korean name, kind, ring, angle_from, angle_to, phase, note)
ROOMS = [
    ("hall", "큰 홀(식당+휴게실)", "hall", "center", 0, 360, 1,
     "식탁·의자 12석, 오락 기구, 가운데 조각상. 첫날에는 침대를 놓고 함께 자는 방으로 씁니다."),
    ("kitchen", "주방", "kitchen", "inner", 186, 228, 2,
     "스토브 2대. 홀과 링 복도에 문이 하나씩. 바닥은 「항균 바닥」이나 돌바닥."),
    ("prison", "수감실", "prison", "inner", 228, 264, 4,
     "수감용 침대 2~3. 문은 링 복도 쪽 하나."),
    ("lab", "연구소", "lab", "inner", 6, 84, 2,
     "연구 작업대 2대, 나중에 「첨단 연구 작업대」와 「복합 분석기」."),
    ("school", "어린이방·학교", "school", "inner", 96, 174, 4,
     "아기 침대, 「교실 책상」과 「칠판」 3개. 아이가 없으면 독서실·휴게실로."),
    ("mechbay", "메카노이드 정비실", "mech", "inner", 276, 318, 4,
     "「메카노이드 충전기」와 「메카노이드 배양기」. 리프터가 바로 창고로 나갑니다."),
    ("battery", "축전지실", "power", "inner", 318, 354, 3,
     "축전지와 「전원 스위치」. 발전기는 바깥에, 이 방만 따로 떼어 불이 번지지 않게."),
    ("freezer", "냉동고", "freezer", "outer", 185, 224, 2,
     "선반 줄. 「냉방기」 2대를 바깥벽 평평한 곳에 박아 −5°C(뜨거운 쪽은 바깥). 문은 링 복도와 도축실 둘뿐."),
    ("butcher", "도축실", "butcher", "outer", 224, 242, 2,
     "「도축 작업대」. 냉동고 옆이라 고기가 바로 들어갑니다."),
    ("hospital", "병실", "hospital", "outer", 242, 266, 3,
     "병상 3~4, 「생체신호 모니터」. 남문과 붙어 있어 쓰러진 사람을 바로 옮깁니다."),
    ("storage", "중앙 창고", "storage", "outer", 274, 316, 3,
     "선반 줄(한 칸에 3묶음). 남쪽 길 문과 작업장 문. 정문에서 가장 가까운 큰 방."),
    ("workshop", "작업장", "workshop", "outer", 316, 354, 3,
     "석재 절삭대, 재봉·단조·기계 작업대, 나중에 조립 작업대. 창고와 문 하나로 연결."),
]
BED_ANGLES_NE = [6, 22, 37, 53, 68, 84]
BED_ANGLES_NW = [96, 112, 127, 143, 158, 174]
for i in range(5):
    ROOMS.append((f"bed_ne{i+1}", f"침실 동{i+1}", "bedroom", "outer",
                  BED_ANGLES_NE[i], BED_ANGLES_NE[i + 1], 3 if i < 2 else 4,
                  "침대, 탁자, 서랍장, 조명. 약 20칸."))
    ROOMS.append((f"bed_nw{i+1}", f"침실 서{i+1}", "bedroom", "outer",
                  BED_ANGLES_NW[i], BED_ANGLES_NW[i + 1], 3 if i < 1 else 4,
                  "침대, 탁자, 서랍장, 조명. 약 20칸."))

RING_RANGE = {"inner": (R_HALL + 0.5, R_IN - 0.5), "outer": (R_MID + 0.5, R_OUT - 0.5)}

# partition rays per ring (room boundaries that are not avenues)
PARTITIONS = collections.defaultdict(set)
for key, _n, _k, ring, a0, a1, _p, _t in ROOMS:
    if ring in RING_RANGE:
        for a in (a0, a1):
            if a % 90:
                PARTITIONS[ring].add(a)


def build():
    grid = {}
    for dy in range(H_MIN, H_MAX + 1):
        for dx in range(W_MIN, W_MAX + 1):
            grid[(dx, dy)] = {"t": GROUND}

    def setc(dx, dy, t, **kw):
        cell = {"t": t}
        cell.update(kw)
        grid[(dx, dy)] = cell

    # base footprint
    for (dx, dy) in list(grid):
        r, ang = polar(dx, dy)
        if r >= R_OUT + 0.5:
            continue
        arm = arm_axis(dx, dy)
        t = FLOOR
        if in_band(r, R_OUT):
            t = WALL
        elif in_band(r, R_HALL):
            t = WALL
        elif in_band(r, R_IN) or in_band(r, R_MID):
            t = WALL
            if arm and abs(arm[1]) <= ARM_HALF:
                t = FLOOR  # avenues pass through the ring corridor walls
        elif r < R_HALL - 0.5:
            t = FLOOR
        else:
            if arm and abs(arm[1]) == ARM_WALL:
                in_corridor_ring = R_IN + 0.5 <= r < R_MID - 0.5
                t = FLOOR if in_corridor_ring else WALL
            elif arm and abs(arm[1]) <= ARM_HALF:
                t = FLOOR
            else:
                for ring, (lo, hi) in RING_RANGE.items():
                    if lo <= r < hi and any(on_ray(dx, dy, a) for a in PARTITIONS[ring]):
                        t = WALL
        if t == WALL:
            for radius in (R_HALL, R_IN, R_MID, R_OUT):
                if in_band(r, radius):
                    setc(dx, dy, t, ring=radius)
                    break
            else:
                setc(dx, dy, t)
        else:
            setc(dx, dy, t)

    # Make every ring side-connected ("thick"): where two ring tiles touch only at a
    # corner, wall the inner of the two side tiles. Rooms would close anyway, but
    # corner-only walls leak heat and let fire through (wiki: Wall).
    for radius in (R_HALL, R_IN, R_MID, R_OUT):
        band = {p for p, c in grid.items() if c["t"] == WALL and in_band(math.hypot(*p), radius)}
        for (x, y) in sorted(band):
            for sx, sy in ((1, 1), (1, -1), (-1, 1), (-1, -1)):
                q = (x + sx, y + sy)
                if q not in band:
                    continue
                a1, a2 = (x + sx, y), (x, y + sy)
                if grid[a1]["t"] == WALL or grid[a2]["t"] == WALL:
                    continue
                inner = min((a1, a2), key=lambda c: abs(math.hypot(*c) - radius))
                if radius == R_OUT or arm_axis(*inner) is None or abs(arm_axis(*inner)[1]) > ARM_HALF:
                    setc(inner[0], inner[1], WALL, ring=radius)
    return grid


def neighbors4(p):
    x, y = p
    return [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]


def flood(grid, passable):
    label, regions = {}, []
    for p, cell in grid.items():
        if p in label or not passable(p, cell):
            continue
        rid = len(regions)
        q, members = collections.deque([p]), []
        label[p] = rid
        while q:
            c = q.popleft()
            members.append(c)
            for n in neighbors4(c):
                if n in grid and n not in label and passable(n, grid[n]):
                    label[n] = rid
                    q.append(n)
        regions.append(members)
    return label, regions


def seed_for(ring, a0, a1):
    am = math.radians((a0 + a1) / 2)
    if ring == "center":
        return (0, 0)
    lo, hi = RING_RANGE[ring]
    rm = (lo + hi) / 2
    return (round(rm * math.cos(am)), round(-rm * math.sin(am)))


def main(out_dir):
    grid = build()
    inside = lambda p, c: c["t"] == FLOOR and math.hypot(*p) < R_OUT - 0.5
    label, regions = flood(grid, inside)

    room_of_region = {}
    rooms = {}
    for key, name, kind, ring, a0, a1, phase, note in ROOMS:
        s = seed_for(ring, a0, a1)
        if s not in label:  # nudge the seed off a wall
            for d in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1), (1, -1), (-1, 1)]:
                t = (s[0] + d[0], s[1] + d[1])
                if t in label:
                    s = t
                    break
        rid = label[s]
        if rid in room_of_region:
            raise SystemExit(f"{key} shares a region with {room_of_region[rid]}")
        room_of_region[rid] = key
        rooms[key] = {"key": key, "name": name, "kind": kind, "ring": ring, "phase": phase,
                      "note": note, "cells": regions[rid]}
    corridor_rid = label[(0, R_HALL + 3)]  # a cell on the south avenue
    if corridor_rid in room_of_region:
        raise SystemExit("corridor region collides with a room")
    rooms["corridor"] = {"key": "corridor", "name": "링 복도와 큰길", "kind": "corridor", "ring": "corridor",
                         "phase": 2, "note": "2칸 링 복도와 3칸 큰길 4개. 화분과 조명을 줄지어 둡니다.",
                         "cells": regions[corridor_rid]}
    room_of_region[corridor_rid] = "corridor"
    unassigned = [i for i in range(len(regions)) if i not in room_of_region]
    if unassigned:
        raise SystemExit(f"unassigned regions: {[regions[i][:2] for i in unassigned]}")
    for key, room in rooms.items():
        for p in room["cells"]:
            grid[p]["room"] = key

    def room_at(p):
        return grid.get(p, {}).get("room")

    def add_door(a, b, near, t=DOOR):
        """Turn the wall tile closest to `near` that separates rooms a and b into a door."""
        best = None
        for p, cell in grid.items():
            if cell["t"] != WALL:
                continue
            x, y = p
            pairs = [((x + 1, y), (x - 1, y)), ((x, y + 1), (x, y - 1))]
            for p1, p2 in pairs:
                r1, r2 = room_at(p1), room_at(p2)
                ok = {r1, r2} == {a, b} if b != "outside" else (
                    (r1 == a and grid.get(p2, {}).get("t") == GROUND) or (r2 == a and grid.get(p1, {}).get("t") == GROUND))
                if ok:
                    d = math.hypot(x - near[0], y - near[1])
                    if best is None or d < best[0]:
                        best = (d, p)
        if best is None and b != "outside":
            # Diagonal (staircase) walls are two tiles thick for movement, so no
            # single tile has both rooms on opposite sides. Cut a door plus one
            # floor tile instead: room a | door | floor(b) | room b.
            for p, cell in grid.items():
                if cell["t"] != WALL:
                    continue
                x, y = p
                for ddx, ddy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    q = (x + ddx, y + ddy)
                    if grid.get(q, {}).get("t") != WALL:
                        continue
                    before = (x - ddx, y - ddy)
                    after = (q[0] + ddx, q[1] + ddy)
                    if room_at(before) == a and room_at(after) == b:
                        d = math.hypot(x - near[0], y - near[1])
                        if best is None or d < best[0]:
                            best = (d, p, q)
            if best is not None:
                _, p, q = best
                grid[p] = {"t": t, "between": [a, b]}
                grid[q] = {"t": FLOOR, "room": b}
                rooms[b]["cells"].append(q)
                return p
        if best is None:
            raise SystemExit(f"no door spot between {a} and {b}")
        grid[best[1]] = {"t": t, "between": [a, b]}
        return best[1]

    def at(r, ang):
        a = math.radians(ang)
        return (r * math.cos(a), -r * math.sin(a))

    doors = []
    # hall: one door per avenue, plus kitchen and school
    for ang in (90, 180, 270, 0):
        doors.append(add_door("hall", "corridor", at(R_HALL, ang)))
    doors.append(add_door("hall", "kitchen", at(R_HALL, 207)))
    doors.append(add_door("hall", "school", at(R_HALL, 135)))
    doors.append(add_door("hall", "lab", at(R_HALL, 45)))
    # inner rooms to the ring corridor
    for key, ang in [("kitchen", 207), ("prison", 246), ("lab", 45), ("school", 135),
                     ("mechbay", 297), ("battery", 336)]:
        doors.append(add_door(key, "corridor", at(R_IN, ang)))
    # outer rooms to the ring corridor
    for key, room in rooms.items():
        if room["ring"] == "outer":
            a0 = next(r[4] for r in ROOMS if r[0] == key)
            a1 = next(r[5] for r in ROOMS if r[0] == key)
            mid = 196 if key == "freezer" else (a0 + a1) / 2  # freezer door nearer the west avenue
            doors.append(add_door(key, "corridor", at(R_MID, mid)))
    # short cuts onto the avenues and between work rooms
    doors.append(add_door("hospital", "corridor", at(19.5, 267)))    # south avenue: next to the gate
    doors.append(add_door("storage", "corridor", at(19.5, 273)))     # south avenue: loot comes straight in
    doors.append(add_door("storage", "workshop", at(18.5, 316)))
    doors.append(add_door("freezer", "butcher", at(18.5, 224)))
    # gates
    gates = {}
    for name, ang in (("south", 270), ("west", 180), ("east", 0), ("north", 90)):
        gates[name] = add_door("corridor", "outside", at(R_OUT, ang), t=GATE)

    # ---- outside features -------------------------------------------------
    features = []

    def feature(kind, cells, phase, label_text):
        features.append({"kind": kind, "cells": [list(c) for c in cells], "phase": phase, "label": label_text})

    # killbox: two curved sandbag arcs funnelling to the south gate, turrets behind the wall
    crescent = [(dx, dy) for (dx, dy) in grid
                if grid[(dx, dy)]["t"] == GROUND and in_band(math.hypot(dx, dy), 27)
                and 232 <= polar(dx, dy)[1] <= 299]
    feature("kbwall", crescent, 4, "초승달 벽: 적은 동남쪽 끝으로만 들어와 정문까지 걸어옵니다")
    sand = [(dx, 25) for dx in range(-6, 7) if abs(dx) > 1] + [(dx, 24) for dx in (-6, 6)]
    feature("sandbags", sand, 4, "정문 앞 모래주머니(아군이 엄폐하는 줄)")
    feature("turret", [(-5, 23), (5, 23), (-10, 22), (10, 22)], 4, "「소형 기관포」 4대(정문 양옆, 서로 4칸 이상 떨어뜨림)")

    # crop arcs west of the base
    fields = [(dx, dy) for (dx, dy) in grid
              if grid[(dx, dy)]["t"] == GROUND and 24.5 <= math.hypot(dx, dy) < 31.5
              and 140 <= polar(dx, dy)[1] <= 220 and abs(dy) > 2]
    feature("field", fields, 1, "부채꼴 밭(벼·감자·옥수수). 서문에서 냉동고까지 바로 들어옵니다")

    # solar arc north
    solar = [(dx, dy) for (dx, dy) in grid
             if grid[(dx, dy)]["t"] == GROUND and 24.5 <= math.hypot(dx, dy) < 29.5
             and 55 <= polar(dx, dy)[1] <= 125 and abs(dx) > 2]
    feature("solar", solar, 3, "발전기 띠(태양광·풍력, 북쪽 빈 땅)")

    # graves north-east
    graves = [(dx, dy) for dx in range(20, 26) for dy in range(-25, -21)
              if grid.get((dx, dy), {}).get("t") == GROUND]
    feature("graves", graves, 3, "무덤")

    # wastepack freezer south-east, away from bedrooms
    wp = [(dx, dy) for dx in range(19, 24) for dy in range(19, 24)]
    feature("wastepack", wp, 4, "독성 폐기물 냉동 창고(작게, 침실과 멀리)")

    anchor = [(dx, dy) for dx in range(7, 11) for dy in range(17, 21)
              if grid.get((dx, dy), {}).get("room") == "storage"]
    feature("anchor", anchor, 5, "「중력닻」 자리(4×4, 창고 안)")
    feature("centrepiece", [(0, 0)], 1, "가운데 조각상이나 「기둥」")

    # gravship pad east: Ø15 substructure disc, engine in the middle
    pcx = 31
    pad = [(dx, dy) for (dx, dy) in grid if math.hypot(dx - pcx, dy) < 7.5 and grid[(dx, dy)]["t"] == GROUND]
    feature("gravship", pad, 5, "중력부양선 갑판(Ø15, 하부구조 약 180칸)")
    feature("engine", [(pcx + i, j) for i in (-1, 0, 1) for j in (-1, 0, 1)], 5, "「중력구동기」")
    feature("console", [(pcx - 4, -1), (pcx - 4, 0)], 5, "「조종석 콘솔」")
    feature("tank", [(pcx - 1 + i, 4 + j) for i in (0, 1) for j in (0, 1)], 5, "「소형 화학연료 탱크」")
    feature("thruster", [(pcx + 7, -3), (pcx + 7, -2), (pcx + 7, 2), (pcx + 7, 3)], 5,
            "「소형 추진기」 2개(분사구는 동쪽 빈 땅으로)")
    exhaust = [(pcx + 8 + k, y) for k in range(5) for y in (-3, -2, 2, 3)]
    feature("exhaust", exhaust, 5, "추진기 분사 구역(비워 두기)")

    # ---- metrics -----------------------------------------------------------
    walk = lambda p, c: c["t"] in (FLOOR, DOOR, GATE) or (c["t"] == GROUND)

    def bfs(start):
        dist = {start: 0}
        q = collections.deque([start])
        while q:
            c = q.popleft()
            for n in neighbors4(c):
                if n in grid and n not in dist and walk(n, grid[n]):
                    dist[n] = dist[c] + 1
                    q.append(n)
        return dist

    def centroid(key):
        cells = rooms[key]["cells"]
        mx = sum(c[0] for c in cells) / len(cells)
        my = sum(c[1] for c in cells) / len(cells)
        return min(cells, key=lambda c: (c[0] - mx) ** 2 + (c[1] - my) ** 2)

    centers = {k: centroid(k) for k in rooms if k != "corridor"}
    hall_d = bfs(centers["hall"])
    pairs = [
        ("냉동고 → 주방", "freezer", "kitchen"),
        ("주방 → 홀", "kitchen", "hall"),
        ("중앙 창고 → 작업장", "storage", "workshop"),
        ("남문 → 병실", "gate_s", "hospital"),
        ("남문 → 중앙 창고", "gate_s", "storage"),
        ("서문 → 냉동고", "gate_w", "freezer"),
        ("메카노이드 정비실 → 중앙 창고", "mechbay", "storage"),
        ("연구소 → 홀", "lab", "hall"),
    ]
    points = dict(centers)
    points["gate_s"] = gates["south"]
    points["gate_w"] = gates["west"]
    metrics = []
    for label_text, a, b in pairs:
        d = bfs(points[a]).get(points[b])
        metrics.append({"label": label_text, "tiles": d})
    beds = [k for k in rooms if rooms[k]["kind"] == "bedroom"]
    bed_d = [hall_d[centers[k]] for k in beds]
    metrics.append({"label": "침실 → 홀 (평균)", "tiles": round(sum(bed_d) / len(bed_d), 1)})
    metrics.append({"label": "침실 → 홀 (가장 먼 방)", "tiles": max(bed_d)})

    walls = [p for p, c in grid.items() if c["t"] == WALL]
    outer_wall = [p for p in walls if grid[p].get("ring") == R_OUT]
    area_inside = sum(1 for p, c in grid.items() if math.hypot(*p) < R_OUT - 0.5)
    side = math.sqrt(area_inside)
    square_perimeter = round(4 * side + 4)

    # wall phases: the earliest phase of any room touching the tile (8-neighbourhood)
    phase_of = {k: v["phase"] for k, v in rooms.items()}
    for p, c in grid.items():
        if c["t"] in (WALL, DOOR, GATE):
            ph = []
            for ddx in (-1, 0, 1):
                for ddy in (-1, 0, 1):
                    q = (p[0] + ddx, p[1] + ddy)
                    rk = grid.get(q, {}).get("room")
                    if rk and rk != "corridor":
                        ph.append(phase_of[rk])
            if c["t"] == GATE or in_band(math.hypot(*p), R_OUT) and not ph:
                c["phase"] = 4
            else:
                c["phase"] = min(ph) if ph else 4
        elif c.get("room"):
            if c["room"] == "corridor":
                near = []
                for ddx in range(-2, 3):
                    for ddy in range(-2, 3):
                        rk = grid.get((p[0] + ddx, p[1] + ddy), {}).get("room")
                        if rk and rk != "corridor":
                            near.append(phase_of[rk])
                c["phase"] = max(2, min(near)) if near else 4
            else:
                c["phase"] = phase_of[c["room"]]

    room_list = []
    for k, r in rooms.items():
        ds = [d["between"] for p, d in grid.items() if d["t"] in (DOOR, GATE) and k in d.get("between", [])]
        room_list.append({"key": k, "name": r["name"], "kind": r["kind"], "phase": r["phase"],
                          "area": len(r["cells"]), "note": r["note"], "center": list(centers.get(k, (0, 0))),
                          "doors": len(ds)})
    stats = {
        "diameter": 2 * R_OUT + 1,
        "rings": {"hall": 2 * R_HALL + 1, "inner": 2 * R_IN + 1, "corridor_outer": 2 * R_MID + 1, "outer": 2 * R_OUT + 1},
        "walls_total": len(walls),
        "outer_wall_tiles": len(outer_wall),
        "square_same_area_perimeter": square_perimeter,
        "area_inside": area_inside,
        "bedrooms": len(beds),
        "bedroom_area_min": min(len(rooms[k]["cells"]) for k in beds),
        "bedroom_area_max": max(len(rooms[k]["cells"]) for k in beds),
        "walls_by_phase": {str(ph): sum(1 for p, c in grid.items() if c["t"] == WALL and c.get("phase") == ph)
                           for ph in range(1, 6)},
    }

    cells = []
    for dy in range(H_MIN, H_MAX + 1):
        row = []
        for dx in range(W_MIN, W_MAX + 1):
            c = grid[(dx, dy)]
            row.append([c["t"], c.get("room"), c.get("phase", 0)])
        cells.append(row)
    plan = {"origin": [W_MIN, H_MIN], "width": WIDTH, "height": HEIGHT, "cells": cells,
            "rooms": room_list, "features": features, "metrics": metrics, "stats": stats}
    with open(f"{out_dir}/plan.json", "w", encoding="utf-8") as fh:
        json.dump(plan, fh, ensure_ascii=False)
    print(json.dumps({"stats": stats, "metrics": metrics,
                      "rooms": [(r["name"], r["area"], r["doors"]) for r in room_list]}, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main(sys.argv[1])
