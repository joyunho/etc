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

Max-difficulty variant (--hard): the same rosette becomes the inner castle.
  - a second, two-layer ring wall at radius 40/41 (Ø83) with a clear band
    inside it that a ring of mini-turrets watches, so sappers who dig
    anywhere but the gate pay the turret avoidance cost on every tile
  - the yard between the walls holds the fields, power, graves and ship pad
  - south: an open gate gap, a walled courtyard (no turrets) narrowing to
    a one-tile hole in the inner wall, and a gatehouse behind the hole
    (one melee blocker, shooters in a line)
  - outside the gate: a crescent block with a switchback trap lane

Usage: python -I gen_base.py <out_dir> [--hard]
Writes plan.json, or plan_hard.json with --hard.
"""
import collections
import json
import math
import sys

R_HALL, R_IN, R_MID, R_OUT = 6, 12, 15, 22
ARM_HALF, ARM_WALL = 1, 2

# canvas around the base centre: dx min, dx max, dy min, dy max (screen y grows downward = south)
BOUNDS = (-32, 45, -30, 34)

# ---- max-difficulty variant --------------------------------------------------
R_C = 40                      # outer ring wall: layers at radius 40 and 41
COURT = (251, 289)            # courtyard side walls (rays); gate and hole at 270
BAND = (35.5, 39.5)           # clear band inside the outer wall
TURRET_R = 35                 # ring turrets: 4.5 tiles inside the outer wall (a dying turret can blow up, radius 3.9)
TURRET_ANGLES = (22.5, 67.5, 112.5, 157.5, 202.5, 237.5, 302.5, 337.5)   # off the postern axes, none in the courtyard
OW_W, OW_E, OW_TURN = 236, 304, 4      # trap block: angular span and the west turn
OW_STORE = 273                # trap block: rays east of the gate close off the store
OW_ENTRY = 4                  # entrance gap (degrees) in the block's outer wall at its east end
HARD_BOUNDS = (-44, 44, -44, 54)

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
     "「스토브」 2대(전기가 생기면 「전기 스토브」). 문은 링 복도 쪽 하나만 두어 지나다니는 사람이 없게. 바닥을 깔고 늘 깨끗하게."),
    ("prison", "수감실", "prison", "inner", 228, 264, 4,
     "수감용 침대 2~3. 문은 링 복도 쪽 하나."),
    ("lab", "연구소", "lab", "inner", 6, 84, 2,
     "연구 작업대 2대, 나중에 「첨단 연구 작업대」와 바로 옆 「복합 분석기」. 문은 홀 쪽 하나만."),
    ("school", "어린이방·학교", "school", "inner", 96, 174, 4,
     "「아기 침대」, 「교실 책상」과 「칠판」 3개. 문은 홀 쪽 하나만. 아이가 없으면 독서실·휴게실로."),
    ("mechbay", "메카노이드 정비실", "mech", "inner", 276, 318, 4,
     "「메카노이드 충전기」와 「메카노이드 배양기」. 리프터가 바로 창고로 나갑니다."),
    ("battery", "축전지실", "power", "inner", 318, 354, 3,
     "축전지와 「전원 스위치」. 처음부터 돌벽과 돌문으로 지어 불이 번지지 않게. 발전기는 바깥에."),
    ("freezer", "냉동고", "freezer", "outer", 185, 224, 2,
     "선반 줄. 「냉방기」 2대를 바깥벽 평평한 곳에 박아 −5°C(뜨거운 쪽은 바깥, 그 바깥 칸은 비워 두기). 문은 링 복도와 도축실 둘뿐."),
    ("butcher", "도축실", "butcher", "outer", 224, 242, 2,
     "「도축 작업대」. 냉동고 옆이라 고기가 바로 들어갑니다."),
    ("hospital", "병실", "hospital", "outer", 242, 266, 3,
     "병상 3~4, 「생체신호 모니터」. 남문과 붙어 있어 쓰러진 사람을 바로 옮깁니다."),
    ("storage", "남쪽 창고", "storage", "outer", 274, 316, 3,
     "선반 줄(한 칸에 3묶음). 남쪽 길 문과 작업장 문. 정문에서 가장 가까운 큰 방. 「중력닻」 자리(4×4)도 여기."),
    ("workshop", "작업장", "workshop", "outer", 316, 354, 3,
     "석재 절삭대, 재봉·단조·기계 작업대, 나중에 조립 작업대. 창고와 문 하나로 연결."),
]
BED_ANGLES_NE = [6, 22, 37, 53, 68, 84]
BED_ANGLES_NW = [96, 112, 127, 143, 158, 174]
for i in range(5):
    ROOMS.append((f"bed_ne{i+1}", f"침실 동{i+1}", "bedroom", "outer",
                  BED_ANGLES_NE[i], BED_ANGLES_NE[i + 1], 3 if i < 3 else 4,
                  "침대, 탁자, 서랍장, 조명. 약 20칸."))
    ROOMS.append((f"bed_nw{i+1}", f"침실 서{i+1}", "bedroom", "outer",
                  BED_ANGLES_NW[i], BED_ANGLES_NW[i + 1], 4,
                  "침대, 탁자, 서랍장, 조명. 약 20칸."))

RING_RANGE = {"inner": (R_HALL + 0.5, R_IN - 0.5), "outer": (R_MID + 0.5, R_OUT - 0.5)}

# partition rays per ring (room boundaries that are not avenues)
PARTITIONS = collections.defaultdict(set)
for key, _n, _k, ring, a0, a1, _p, _t in ROOMS:
    if ring in RING_RANGE:
        for a in (a0, a1):
            if a % 90:
                PARTITIONS[ring].add(a)


def build(bounds=BOUNDS, hard=False):
    w_min, w_max, h_min, h_max = bounds
    grid = {}
    for dy in range(h_min, h_max + 1):
        for dx in range(w_min, w_max + 1):
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
    if hard:
        build_hard(grid)
    return grid


def thicken(grid, cells, attrs):
    """Side-connect a set of wall tiles: where two touch only at a corner, wall one side tile."""
    band = set(cells)
    for (x, y) in sorted(band):
        for sx, sy in ((1, 1), (1, -1), (-1, 1), (-1, -1)):
            q = (x + sx, y + sy)
            if q not in band:
                continue
            a1, a2 = (x + sx, y), (x, y + sy)
            if a1 not in grid or a2 not in grid:
                continue
            if grid[a1]["t"] == WALL or grid[a2]["t"] == WALL:
                continue
            pick = min((a1, a2), key=lambda c: (math.hypot(*c), c))
            grid[pick] = dict(attrs, t=WALL)


def in_arc(ang, a0, a1):
    return a0 <= ang <= a1


def build_hard(grid):
    """Walls of the max-difficulty variant: gatehouse, outer ring wall, courtyard, trap block."""
    def wall(p, **kw):
        if p in grid:
            grid[p] = dict(kw, t=WALL)

    # gatehouse: close the ring-corridor wall across the south avenue (its door goes in later)
    for dx in (-1, 0, 1):
        wall((dx, R_MID), ring=R_MID)

    # outer ring wall, two layers
    for radius in (R_C, R_C + 1):
        cells = [q for q in grid if in_band(math.hypot(*q), radius)]
        for q in cells:
            wall(q, ring=radius, part="curtain")
        thicken(grid, cells, {"ring": radius, "part": "curtain"})

    # courtyard side walls between the inner castle and the outer wall
    for q in list(grid):
        r = math.hypot(*q)
        if R_OUT - 0.5 <= r < R_C + 0.5 and any(on_ray(q[0], q[1], a) for a in COURT) and grid[q]["t"] == GROUND:
            wall(q, part="court")

    # trap block outside the gate: rings (arcs) and rays
    def arc_cells(radius, a0, a1):
        return [q for q in grid if in_band(math.hypot(*q), radius) and in_arc(polar(*q)[1], a0, a1)]

    def ray_cells(ang, r0, r1):
        return [q for q in grid if r0 <= math.hypot(*q) < r1 and on_ray(q[0], q[1], ang)]

    parts = [
        (arc_cells(44, OW_W + OW_TURN, OW_E), "ow"),            # inner lane | maintenance corridor
        (arc_cells(47, OW_W + OW_TURN, OW_E), "ow"),            # maintenance corridor | outer lane
        (arc_cells(50, OW_W, OW_E - OW_ENTRY), "ow"),           # outer wall, entrance gap at the east end
        (ray_cells(OW_W, R_C + 1.5, 50.5), "ow"),               # west end
        (ray_cells(OW_E, R_C + 1.5, 50.5), "ow"),               # east end
        (ray_cells(OW_W + OW_TURN, 43.5, 47.5), "ow"),          # maintenance corridor, west end
        (ray_cells(OW_STORE, R_C + 1.5, 43.5), "ow"),           # inner lane | store
    ]
    for cells, part in parts:
        cells = [q for q in cells if grid[q]["t"] == GROUND]
        for q in cells:
            wall(q, part=part)
        thicken(grid, cells, {"part": part})

    # gate gap through both layers of the outer wall (no door)
    for dy in (R_C, R_C + 1):
        grid[(0, dy)] = {"t": FLOOR, "part": "gate_gap"}
    # posterns: two doors (an airlock) through the outer wall on the other three axes
    for (ux, uy) in ((1, 0), (0, -1), (-1, 0)):
        for radius in (R_C, R_C + 1):
            grid[(ux * radius, uy * radius)] = {"t": DOOR, "part": "postern", "between": ["yard", "outside"]}
    # trap block doors: inner lane | maintenance corridor | outer lane, beside the gate
    grid[(0, 44)] = {"t": DOOR, "part": "ow_door", "between": ["lane", "maint"]}
    grid[(0, 47)] = {"t": DOOR, "part": "ow_door", "between": ["maint", "lane"]}
    # store | maintenance corridor: a wall tile of the r=44 arc with ground on both radial sides
    best = None
    for q, c in grid.items():
        if c["t"] != WALL or c.get("part") != "ow" or not (43.5 <= math.hypot(*q) < 44.5):
            continue
        ang = polar(*q)[1]
        if not (OW_STORE + 4 <= ang <= OW_E - 4):
            continue
        for a, b in (((q[0] + 1, q[1]), (q[0] - 1, q[1])), ((q[0], q[1] + 1), (q[0], q[1] - 1))):
            if grid.get(a, {}).get("t") == GROUND and grid.get(b, {}).get("t") == GROUND:
                ra, rb = math.hypot(*a), math.hypot(*b)
                if min(ra, rb) < 43.5 and max(ra, rb) >= 44.5:
                    d = abs(ang - 288)
                    if best is None or d < best[0]:
                        best = (d, q)
    if best is None:
        raise SystemExit("no spot for the store door")
    grid[best[1]] = {"t": DOOR, "part": "ow_door", "between": ["store", "maint"]}


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


HARD_PART_PHASE = {"hole": 2, "court": 3, "curtain": 4, "postern": 4, "gate_gap": 4, "ow": 5, "ow_door": 5}


def hard_phase(p, c):
    """Build phase of a max-difficulty structure tile: the outer wall's second layer comes a phase later."""
    ph = HARD_PART_PHASE[c["part"]]
    if c["part"] in ("curtain", "postern", "gate_gap") and math.hypot(*p) >= R_C + 0.5:
        ph += 1
    return ph


def flood_from(grid, seed, ok):
    seen = {seed}
    q = collections.deque([seed])
    while q:
        c = q.popleft()
        for n in neighbors4(c):
            if n not in seen and n in grid and ok(n):
                seen.add(n)
                q.append(n)
    return seen


def hard_regions(grid):
    """Courtyard, yard, trap lane, maintenance corridor and store of the max-difficulty variant."""
    ground = lambda q: grid[q]["t"] == GROUND
    inside = lambda q: R_OUT + 0.5 <= math.hypot(*q) < R_C - 0.5
    court = flood_from(grid, (0, 30), lambda q: ground(q) and inside(q))
    yard = flood_from(grid, (-30, 0), lambda q: ground(q) and inside(q))
    in_block = lambda q: R_C + 1.5 <= math.hypot(*q) < 49.5 and in_arc(polar(*q)[1], OW_W - 2, OW_E + 2)
    lane = flood_from(grid, (0, 48), lambda q: ground(q) and in_block(q))
    maint = flood_from(grid, (0, 45), lambda q: ground(q) and in_block(q))
    store_seed = min((q for q in grid if ground(q) and R_C + 1.5 <= math.hypot(*q) < 43.5
                      and in_arc(polar(*q)[1], OW_STORE + 4, OW_E - 4)), key=lambda q: abs(polar(*q)[1] - 290))
    store = flood_from(grid, store_seed, lambda q: ground(q) and in_block(q))
    checks = {"courtyard/yard": court & yard, "lane/maintenance": lane & maint, "lane/store": lane & store,
              "maintenance/store": maint & store}
    for name, overlap in checks.items():
        if overlap:
            raise SystemExit(f"{name} regions leak into each other at {sorted(overlap)[:3]}")
    if not {(0, R_C + 2), (0, R_C + 3)} <= lane:
        raise SystemExit("the trap lane does not reach the gate")
    if len(court) > 900 or len(maint) > 400 or len(store) > 200:
        raise SystemExit(f"a region leaked: court {len(court)} maint {len(maint)} store {len(store)}")
    return court, yard, lane, maint, store


def hard_features(grid, feature):
    """Outside features of the max-difficulty variant."""
    court, yard, lane, maint, store = hard_regions(grid)
    taken = set()

    def put(kind, cells, phase, label_text):
        cells = [tuple(c) for c in cells]
        clash = [c for c in cells if c in taken]
        if clash and kind not in ("court", "band", "lane", "maint", "store"):
            raise SystemExit(f"{kind} overlaps another feature at {clash[:3]}")
        if kind not in ("court", "band", "lane", "maint", "store"):
            taken.update(cells)
        feature(kind, cells, phase, label_text)

    band = [q for q in yard if BAND[0] <= math.hypot(*q) < BAND[1]]
    put("court", sorted(court), 3, "옹성 마당: 바깥 성문 틈으로 들어온 적이 구멍까지 오는 마당. 포탑은 한 대도 두지 않습니다")
    put("band", sorted(band), 4, "바깥 성벽 안쪽 빈 띠(4칸): 아무것도 짓지 말고 비워 두어 고리 포탑이 성벽 둘레를 다 보게")
    put("lane", sorted(lane), 5, "뱀길: 동남쪽 입구 → 바깥 줄 서쪽으로 → 꺾어서 → 안쪽 줄 동쪽으로 → 바깥 성문 틈")
    put("maint", sorted(maint), 5, "정비 복도: 성문 옆 문 두 짝으로 두 줄에 드나들며 함정을 다시 놓습니다. 적은 이 문을 벽으로 봅니다")
    put("store", sorted(store), 5, "정비 창고: 함정 재료(목재)를 둡니다. 정비 복도 문으로 드나듭니다")

    fields = [q for q in yard if 26.5 <= math.hypot(*q) < 34 and 140 <= polar(*q)[1] <= 220 and abs(q[1]) > 2]
    put("field", fields, 1, "부채꼴 밭(벼·감자·옥수수). 서쪽 성문 길(가운데 5칸)은 비워 둡니다")
    put("generator", [(-24, 6), (-23, 6), (-24, 7), (-23, 7)], 2,
        "「나무 화력발전기」: 2단계 냉동고 냉방기용 전기(1,000W). 3단계에 발전기 띠와 축전지가 생기면 예비로")
    solar = [q for q in yard if 24.5 <= math.hypot(*q) < 29.5 and 55 <= polar(*q)[1] <= 125 and abs(q[0]) > 2]
    put("solar", solar, 3, "발전기 띠: 「태양광 발전기」 자리. 「풍력 발전기」는 긴 변을 남북으로 세워 빈 땅(7×18)이 띠를 따라 동서로 뻗게")
    put("graves", [(dx, dy) for dx in range(20, 26) for dy in range(-17, -13)], 3, "무덤")
    put("wastepack", [(dx, dy) for dx in range(20, 25) for dy in range(17, 22)], 4,
        "독성 폐기물 냉동 창고: 돌벽, 냉방기 1대. 메카노이드 정비실에서 가까운 남동쪽 뜰, 침실 반대편")
    anchor = [(dx, dy) for dx in range(8, 12) for dy in range(15, 19)]
    if any(grid.get(c, {}).get("room") != "storage" for c in anchor):
        raise SystemExit("grav anchor slot is not all storage floor")
    put("anchor", anchor, 6, "「중력닻」 자리(4×4, 창고 안)")
    put("centrepiece", [(0, 0)], 1, "가운데 조각상이나 「기둥」")

    # ship pad east, inside the yard: Ø13 deck, thrusters on the north and south edges
    pcx = 29
    pad = [q for q in yard if math.hypot(q[0] - pcx, q[1]) < 6.5]
    if any(math.hypot(*q) >= BAND[0] for q in pad):
        raise SystemExit("ship pad reaches the clear band")
    feature("gravship", pad, 6, f"중력부양선 갑판(Ø13, 하부구조 {len(pad)}칸). 동쪽 성문 바로 앞 뜰")
    put("engine", [(pcx + i, j) for i in (-1, 0, 1) for j in (-1, 0, 1)], 6, "「중력구동기」")
    put("console", [(pcx - 5 + i, j) for i in (0, 1) for j in (-1, 0, 1)], 6, "「조종석 콘솔」(2×3)")
    put("tank", [(pcx + 2 + i, 3 + j) for i in (0, 1) for j in (0, 1)], 6, "「소형 화학연료 탱크」")
    put("thruster", [(pcx, -5), (pcx, -6), (pcx, 5), (pcx, 6)], 6,
        "「소형 추진기」 2개(1×2를 남북으로 세워 갑판 북쪽·남쪽 끝에, 분사구는 바깥쪽)")
    put("exhaust", [(pcx, -7 - k) for k in range(5)] + [(pcx, 7 + k) for k in range(5)], 6, "추진기 분사 구역(비워 두기)")
    for q in pad:
        if q not in yard:
            raise SystemExit("ship pad leaves the yard")

    # ring turrets in the band, never in the courtyard
    turrets = []
    for a in TURRET_ANGLES:
        t = (round(TURRET_R * math.cos(math.radians(a))), round(-TURRET_R * math.sin(math.radians(a))))
        if t not in yard:
            raise SystemExit(f"ring turret {t} is not in the yard")
        turrets.append(t)
    for i, a in enumerate(turrets):
        for b in turrets[i + 1:]:
            if math.dist(a, b) < 4:
                raise SystemExit("ring turrets closer than 4 tiles")
    put("turret", turrets, 4, f"고리 포탑: 「소형 기관포」 {len(turrets)}대. 성벽 안쪽 빈 띠와 뜰을 봅니다. 꺼 둬도 공병 길 계산에는 들어가니 평소엔 꺼 두고 습격 때 켭니다")

    # courtyard firing line, gatehouse posts
    sand = sorted(q for q in court if in_band(math.hypot(*q), 31))
    put("sandbags", sand, 3, "1차 사격 줄: 「모래주머니」. 아군은 북쪽(구멍 쪽)에 서서 성문 틈을 봅니다. 밀리면 구멍으로 물러납니다")
    put("hole", [(0, R_OUT)], 2, "구멍: 안쪽 성벽의 문 없는 1칸 틈. 적이 들어올 수 있는 유일한 길입니다")
    put("blocker", [(0, R_OUT - 1)], 2, "막는 칸: 근접 1명이 여기 서면 적은 구멍에서 한 명씩만 싸웁니다")
    put("shooter", [(0, R_OUT - 2 - k) for k in range(5)], 2,
        "사수 자리 5: 구멍과 한 줄로. 막는 사람에서 5칸 안이라 아군 오사가 없습니다")
    put("gategap", [(0, R_C), (0, R_C + 1)], 4, "바깥 성문 틈: 문 없는 1칸. 쪽문과 정비 문은 늘 닫아 두어 적이 여기로만 오게")
    put("postern", [(ux * r, uy * r) for (ux, uy) in ((1, 0), (0, -1), (-1, 0)) for r in (R_C, R_C + 1)], 4,
        "쪽문: 바깥 성벽 두 겹에 문을 하나씩 달아 두 짝을 차례로 지납니다. 늘 닫아 둡니다")

    # trap lane: traps on the inner track of each lane (raiders hug the inside of a curve),
    # a fence across from each trap so stepping round it costs more than stepping on it
    entry = sorted((q for q in lane if math.hypot(*q) >= 47.5 and polar(*q)[1] >= OW_E - OW_ENTRY - 1),
                   key=lambda q: -polar(*q)[1])
    put("entry", entry[:1], 5, "뱀길 입구(동남쪽)")
    inner_lane = [q for q in lane if math.hypot(*q) < 43.5 and polar(*q)[1] <= 270 - 1.5]
    outer_lane = [q for q in lane if 47.5 <= math.hypot(*q) < 49.5 and polar(*q)[1] >= OW_W + OW_TURN + 1]
    traps, fences = [], []
    for cells, r_mid, step in ((inner_lane, R_C + 2.5, 1), (outer_lane, 48.5, 2)):
        track = sorted((q for q in cells if math.hypot(*q) < r_mid), key=lambda q: polar(*q)[1])
        k = 0
        for q in track:
            if any(math.dist(q, t) < 1.5 for t in traps):
                continue
            k += 1
            if (k - 1) % step:
                continue
            traps.append(q)
            # the cell across the lane (one step outward)
            ux, uy = q[0] / math.hypot(*q), q[1] / math.hypot(*q)
            f = (round(q[0] + ux), round(q[1] + uy))
            if f in cells and f not in traps and math.hypot(*f) >= r_mid:
                fences.append(f)
    put("trap", traps, 5, "「가시 함정」: 2칸 간격(붙여 지을 수 없음). 터지면 자동으로 다시 지을 설계도가 생깁니다")
    put("fence", fences, 5, "「울타리」: 함정 맞은편. 사람도 넘어가지만 느려져서(길 비용 80) 적이 함정 쪽으로 걷습니다")


def hard_stats(grid, features):
    parts = collections.Counter(c.get("part") for c in grid.values() if c["t"] == WALL)
    count = lambda kind: len(next(f for f in features if f["kind"] == kind)["cells"])
    return {"curtain_wall_tiles": parts["curtain"], "court_wall_tiles": parts["court"],
            "trap_block_wall_tiles": parts["ow"], "ring_turrets": count("turret"), "traps": count("trap"),
            "fences": count("fence"), "sandbags": count("sandbags"),
            "posterns": sum(1 for c in grid.values() if c.get("part") == "postern"),
            "outer_diameter": 2 * (R_C + 1) + 1,
            "materials_by_phase": materials_by_phase(grid, features)}


def materials_by_phase(grid, features):
    """What each phase builds: walls (5 stuff), doors (25), turrets, traps (45), fences (1), sandbags (5 cloth)."""
    out = {}
    for ph in range(1, 7):
        walls = sum(1 for c in grid.values() if c["t"] == WALL and c.get("phase") == ph)
        temp = sum(1 for c in grid.values() if c["t"] == DOOR and c.get("phase") == ph and c.get("door_phase", 0) > ph)
        doors = sum(1 for c in grid.values() if c["t"] == DOOR and c.get("door_phase") == ph)
        gates = sum(1 for c in grid.values() if c["t"] == GATE and c.get("phase") == ph)
        n = lambda kind: sum(len(f["cells"]) for f in features if f["kind"] == kind and f["phase"] == ph)
        out[str(ph)] = {"walls": walls + temp, "doors": doors + gates,
                        "stuff": (walls + temp) * 5 + (doors + gates) * 25,
                        "turrets": n("turret"), "traps": n("trap"), "fences": n("fence"), "sandbags": n("sandbags")}
    return out



def main(out_dir, hard=False):
    bounds = HARD_BOUNDS if hard else BOUNDS
    w_min, w_max, h_min, h_max = bounds
    grid = build(bounds, hard)
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
    if hard:
        gh_rid = label[(0, R_OUT - 4)]
        if gh_rid in room_of_region:
            raise SystemExit(f"gatehouse shares a region with {room_of_region[gh_rid]}")
        rooms["gatehouse"] = {"key": "gatehouse", "name": "문루(남쪽 큰길 끝)", "kind": "gate", "ring": "gate",
                              "phase": 2,
                              "note": "구멍 바로 안 칸에 근접 1명이 막고, 그 뒤 한 줄에 사수 5명. 링 복도 쪽 문은 싸움 중 닫아 둡니다. 병실 문이 여기로 나 다친 사람을 바로 옮깁니다.",
                              "cells": regions[gh_rid]}
        room_of_region[gh_rid] = "gatehouse"
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
    doors.append(add_door("hall", "school", at(R_HALL, 135)))
    doors.append(add_door("hall", "lab", at(R_HALL, 45)))
    # inner rooms to the ring corridor
    for key, ang in [("kitchen", 207), ("prison", 246), ("mechbay", 297), ("battery", 336)]:
        doors.append(add_door(key, "corridor", at(R_IN, ang)))
    # outer rooms to the ring corridor
    for key, room in rooms.items():
        if room["ring"] == "outer":
            a0 = next(r[4] for r in ROOMS if r[0] == key)
            a1 = next(r[5] for r in ROOMS if r[0] == key)
            mid = 196 if key == "freezer" else (a0 + a1) / 2  # freezer door nearer the west avenue
            doors.append(add_door(key, "corridor", at(R_MID, mid)))
    # short cuts onto the avenues and between work rooms
    south = "gatehouse" if hard else "corridor"
    doors.append(add_door("hospital", south, at(19.5, 267)))    # south avenue: next to the gate
    doors.append(add_door("storage", south, at(19.5, 273)))     # south avenue: loot comes straight in
    doors.append(add_door("storage", "workshop", at(18.5, 316)))
    doors.append(add_door("freezer", "butcher", at(18.5, 224)))
    # gates
    if hard:
        doors.append(add_door("gatehouse", "corridor", at(R_MID, 270)))
    gates = {}
    for name, ang in (("south", 270), ("west", 180), ("east", 0), ("north", 90)):
        if hard and name == "south":
            gates[name] = add_door("gatehouse", "outside", at(R_OUT, ang), t=FLOOR)   # the hole: no door
            grid[gates[name]]["part"] = "hole"
        else:
            gates[name] = add_door("corridor", "outside", at(R_OUT, ang), t=GATE)

    # ---- outside features -------------------------------------------------
    features = []

    def feature(kind, cells, phase, label_text):
        features.append({"kind": kind, "cells": [list(c) for c in cells], "phase": phase, "label": label_text})

    if not hard:
        # Killbox: a crescent wall at radius 31 closed at its west end, open only at the
        # south-east mouth, so raiders walk west along the 8-tile pocket to the south gate.
        # The sandbag line faces the mouth. Turrets stand 4 tiles behind the defenders,
        # 4 tiles apart, and 4+ tiles from the base walls (a dying mini-turret can explode,
        # radius 3.9); the far turret backs onto the crescent, so build that wall in stone.
        KB_R = 31
        crescent = [(dx, dy) for (dx, dy) in grid
                    if grid[(dx, dy)]["t"] == GROUND and in_band(math.hypot(dx, dy), KB_R)
                    and 232 <= polar(dx, dy)[1] <= 304]
        closer = [(dx, dy) for (dx, dy) in grid
                  if grid[(dx, dy)]["t"] == GROUND and R_OUT + 0.5 <= math.hypot(dx, dy) < KB_R + 0.5
                  and on_ray(dx, dy, 232)]
        feature("kbwall", sorted(set(crescent + closer)), 4, "초승달 벽(돌): 서쪽 끝은 바깥벽에 붙여 막고, 동남쪽 끝만 열어 둡니다")
        pocket = lambda dx, dy: grid.get((dx, dy), {}).get("t") == GROUND and R_OUT + 0.5 <= math.hypot(dx, dy) < KB_R - 0.5
        sand = [(7, dy) for dy in range(20, KB_R + 1) if pocket(7, dy)]
        feature("sandbags", sand, 4, "모래주머니 줄: 동남쪽 입구를 향해 세로로. 아군은 이 줄 서쪽(정문 쪽)에 섭니다")
        turrets = [(2, 26), (2, 30)]
        walls_now = [p for p, c in grid.items() if c["t"] in (WALL, DOOR, GATE)]
        for t in turrets:
            if not pocket(*t):
                raise SystemExit(f"turret {t} is not in the killbox pocket")
            near = min(math.dist(t, w) for w in walls_now)
            if near < 3.95:
                raise SystemExit(f"turret {t} is {near:.1f} tiles from a base wall")
        feature("turret", turrets, 4,
                "「소형 기관포」 2대: 아군 뒤 4칸, 서로 4칸, 기지 벽에서 4칸 넘게(「자동 포탑」 연구, 대당 80W)")

        # crop arcs west of the base
        fields = [(dx, dy) for (dx, dy) in grid
                  if grid[(dx, dy)]["t"] == GROUND and 26.5 <= math.hypot(dx, dy) < 32
                  and 140 <= polar(dx, dy)[1] <= 220 and abs(dy) > 2]
        feature("field", fields, 1, "부채꼴 밭(벼·감자·옥수수). 바깥벽과 밭 사이 4칸은 길 겸 방화대")
        feature("generator", [(-24, 6), (-23, 6), (-24, 7), (-23, 7)], 2,
                "「나무 화력발전기」: 2단계 냉동고 냉방기용 전기(1,000W). 3단계에 발전기 띠와 축전지가 생기면 예비로")

        # solar arc north
        solar = [(dx, dy) for (dx, dy) in grid
                 if grid[(dx, dy)]["t"] == GROUND and 24.5 <= math.hypot(dx, dy) < 29.5
                 and 55 <= polar(dx, dy)[1] <= 125 and abs(dx) > 2]
        feature("solar", solar, 3, "발전기 띠: 「태양광 발전기」 자리. 「풍력 발전기」는 긴 변을 남북으로 세워 빈 땅(7×18)이 띠를 따라 동서로 뻗게")

        # graves north-east
        graves = [(dx, dy) for dx in range(20, 26) for dy in range(-25, -21)
                  if grid.get((dx, dy), {}).get("t") == GROUND]
        feature("graves", graves, 3, "무덤")

        # wastepack freezer south-east, away from bedrooms
        wp = [(dx, dy) for dx in range(25, 30) for dy in range(-21, -16)]
        feature("wastepack", wp, 4, "독성 폐기물 냉동 창고: 돌벽, 냉방기 1대. 습격 길·침실·중력부양선에서 떨어진 북동쪽")

        anchor = [(dx, dy) for dx in range(8, 12) for dy in range(15, 19)]
        if any(grid.get(c, {}).get("room") != "storage" for c in anchor):
            raise SystemExit("grav anchor slot is not all storage floor")
        feature("anchor", anchor, 5, "「중력닻」 자리(4×4, 창고 안)")
        feature("centrepiece", [(0, 0)], 1, "가운데 조각상이나 「기둥」")

        # gravship pad east: Ø15 substructure disc, engine in the middle
        pcx = 31
        pad = [(dx, dy) for (dx, dy) in grid if math.hypot(dx - pcx, dy) < 7.5 and grid[(dx, dy)]["t"] == GROUND]
        feature("gravship", pad, 5, "중력부양선 갑판(Ø15, 하부구조 약 180칸)")
        feature("engine", [(pcx + i, j) for i in (-1, 0, 1) for j in (-1, 0, 1)], 5, "「중력구동기」")
        feature("console", [(pcx - 5 + i, j) for i in (0, 1) for j in (-1, 0, 1)], 5, "「조종석 콘솔」(2×3)")
        feature("tank", [(pcx - 1 + i, 4 + j) for i in (0, 1) for j in (0, 1)], 5, "「소형 화학연료 탱크」")
        feature("thruster", [(pcx + 6, -2), (pcx + 7, -2), (pcx + 6, 2), (pcx + 7, 2)], 5,
                "「소형 추진기」 2개(1×2를 동서로 눕혀 갑판 위에, 분사구는 동쪽)")
        exhaust = [(pcx + 8 + k, y) for k in range(5) for y in (-2, 2)]
        feature("exhaust", exhaust, 5, "추진기 분사 구역(비워 두기)")

    else:
        hard_features(grid, feature)

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
        ("냉동고 → 홀 (식사 들고 가는 길)", "freezer", "hall"),
        ("남쪽 창고 → 작업장", "storage", "workshop"),
        ("남문 → 병실", "gate_s", "hospital"),
        ("남문 → 남쪽 창고", "gate_s", "storage"),
        ("서문 → 냉동고", "gate_w", "freezer"),
        ("메카노이드 정비실 → 남쪽 창고", "mechbay", "storage"),
        ("연구소 → 홀", "lab", "hall"),
        ("남쪽 창고 → 냉동고 (먼 길)", "storage", "freezer"),
        ("남쪽 창고 → 연구소 (먼 길)", "storage", "lab"),
        ("냉동고 → 작업장 (가죽 → 재봉, 가장 먼 길)", "freezer", "workshop"),
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
    if hard:
        hole = gates["south"]
        no_doors = lambda p, c: c["t"] in (FLOOR, GROUND)

        def bfs_with(start, ok):
            dist = {start: 0}
            q = collections.deque([start])
            while q:
                c = q.popleft()
                for n in neighbors4(c):
                    if n in grid and n not in dist and ok(n, grid[n]):
                        dist[n] = dist[c] + 1
                        q.append(n)
            return dist
        entry = next(f for f in features if f["kind"] == "entry")["cells"][0]
        metrics.append({"label": "뱀길 입구 → 바깥 성문 (습격자가 걷는 길)",
                        "tiles": bfs_with(tuple(entry), no_doors).get((0, R_C + 1))})
        metrics.append({"label": "바깥 성문 → 구멍 (옹성 마당)", "tiles": bfs((0, R_C)).get(hole)})
        for m in metrics:
            m["label"] = m["label"].replace("남문 → 병실", "구멍 → 병실 (다친 사람)").replace("남문 →", "구멍 →")
        curtain = [p for p, c in grid.items() if c.get("part") == "curtain"]
        bed_cells = [p for k in beds for p in rooms[k]["cells"]]
        metrics.append({"label": "침대 → 바깥 성벽 (가장 가까운 곳, 직선)",
                        "tiles": round(min(math.dist(a, b) for a in bed_cells for b in curtain), 1)})

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
            if hard and c.get("part") in HARD_PART_PHASE:
                c["phase"] = hard_phase(p, c)
            elif hard and (c["t"] == GATE or in_band(math.hypot(*p), R_OUT)):
                c["phase"] = 2   # the inner castle wall closes in the first week
            if c["t"] == DOOR and c.get("part") in HARD_PART_PHASE:
                c["door_phase"] = hard_phase(p, c)
            elif c["t"] == DOOR:
                a, b = c["between"]
                if "hall" in (a, b) and "corridor" in (a, b):
                    # day one: only the west (fields) and south doors; the rest stay wall
                    ang = polar(*p)[1]
                    c["door_phase"] = 1 if 135 <= ang <= 315 else 3
                else:
                    c["door_phase"] = max(phase_of[k] for k in (a, b) if k != "corridor")
                c["door_phase"] = max(c["door_phase"], c["phase"])
        elif c.get("part") in HARD_PART_PHASE:
            c["phase"] = hard_phase(p, c)
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
        **({} if hard else {
            "killbox_wall_tiles": len(next(f for f in features if f["kind"] == "kbwall")["cells"]),
            "sandbags": len(next(f for f in features if f["kind"] == "sandbags")["cells"])}),
        **(hard_stats(grid, features) if hard else {}),
        "walls_by_phase": {str(ph): sum(1 for p, c in grid.items() if c["t"] == WALL and c.get("phase") == ph)
                           for ph in range(1, 7 if hard else 6)},
    }

    cells = []
    for dy in range(h_min, h_max + 1):
        row = []
        for dx in range(w_min, w_max + 1):
            c = grid[(dx, dy)]
            row.append([c["t"], c.get("room"), c.get("phase", 0), c.get("door_phase", 0)])
        cells.append(row)
    plan = {"origin": [w_min, h_min], "width": w_max - w_min + 1, "height": h_max - h_min + 1, "cells": cells,
            "rooms": room_list, "features": features, "metrics": metrics, "stats": stats}
    if hard:
        plan["variant"] = "hard"
    with open(f"{out_dir}/{'plan_hard.json' if hard else 'plan.json'}", "w", encoding="utf-8") as fh:
        json.dump(plan, fh, ensure_ascii=False)
    print(json.dumps({"stats": stats, "metrics": metrics,
                      "rooms": [(r["name"], r["area"], r["doors"]) for r in room_list]}, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main(sys.argv[1], hard="--hard" in sys.argv[2:])
