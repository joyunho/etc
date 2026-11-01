"""Check a furnished base plan against RimWorld 1.6 rules (played on 1.7 beta with Biotech, Odyssey and mods).

Usage: python3 -I validate_plan.py plan.json [--room KEY] [--json report.json] [--catalog DIR] [--rules rules.json]
         [--phase N] [--hygiene-max 40] [--vanilla-floors] [--all-info]

The plan is the format sim_raids.py reads: cells [type, room, phase, door_phase, material?] with types ground, floor,
wall, diag, door, gate; a rooms list {key, kind, ...}; furniture items written by furnish_lib.item_dict; features
{kind, phase, cells} (stockpile and dumping zones, no_roof cells, floor overlays {kind: floor, floor: name}).
Plan x grows east, y grows south (game z = -y); rotations N/E/S/W.

Every finding cites a rule of rules.json by its position: R54 is rules.json[54] (roof support). The cited rules are
checked against rules.json at start-up (topic and a key phrase), so a reordered rules.json is noticed.

Checks per room: footprints and edifice overlap, interaction cells, doors, furniture-aware reachability, beds and
bed facilities, facilities (tool cabinet, multi-analyzer, blackboard, gene bank/processor ...), joy objects, the
room role and its bench penalties, impressiveness, light, roof support, temperature (heuristic), Dubs Bad Hygiene
walking distance and power by phase. Errors break a game rule (the thing will not work, or the room changes role);
warnings are advice. Exit code 1 when there is an error.
"""
import argparse
import collections
import heapq
import importlib.util
import json
import math
import os
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


fl = _load("furnish_lib")

N4 = ((1, 0), (-1, 0), (0, 1), (0, -1))
DIAG = ((1, 1), (1, -1), (-1, 1), (-1, -1))
N8 = N4 + DIAG
INF = float("inf")

# Cited rules: id -> (topic, phrase that must be in the rule text). Ids are rules.json positions (0-based).
RULE_REFS = {
    0: ("footprint", "OccupiedRect"), 1: ("footprint", "RotatedBy"), 2: ("footprint", "<rotatable>"),
    3: ("footprint", "sleeping slot"), 4: ("footprint", "head against a wall"),
    5: ("interaction_cells", "InteractionCellStandable"), 6: ("interaction_cells", "NotBlockingAnyInteractionCells"),
    7: ("interaction_cells", "PreventInteractionSpotOverlap"), 8: ("interaction_cells", "door cell"),
    9: ("interaction_cells", "without an interaction cell"), 10: ("interaction_cells", "Wall attachments"),
    11: ("interaction_cells", "One edifice per cell"),
    13: ("doors", "door directly behind door"), 14: ("doors", "Portal"), 16: ("doors", "Multi-cell doors"),
    17: ("doors", "Doors do not swing"),
    18: ("room_detection", "What closes a room"), 19: ("room_detection", "huge"),
    21: ("room_detection", "PsychologicallyOutdoors"), 22: ("room_detection", "expanded by 1"),
    24: ("room_detection", "prisoner bed"),
    25: ("room_roles", "highest score"), 26: ("room_roles", "Bedroom test"), 27: ("room_roles", "Hospital ="),
    28: ("room_roles", "Mixed rooms"), 30: ("room_roles", "Kitchen score"), 31: ("room_roles", "Nursery"),
    32: ("room_stats", "Space (room stat)"), 33: ("room_stats", "Beauty (room stat)"),
    34: ("room_stats", "Wealth (room stat)"), 35: ("room_stats", "Cleanliness (room stat)"),
    36: ("room_stats", "Impressiveness ="), 37: ("room_stats", "Room-size need"),
    40: ("thoughts", "Sleeping thoughts"), 41: ("thoughts", "Slept outside"), 43: ("thoughts", "Ate without table"),
    44: ("thoughts", "Hospital patient"), 45: ("thoughts", "Darkness -5"),
    48: ("facilities", "CompAffectedByFacilities"), 49: ("facilities", "End table"),
    50: ("facilities", "Vitals monitor"), 51: ("facilities", "Tool cabinet"), 52: ("facilities", "Multi-analyzer"),
    53: ("facilities", "blackboard"),
    54: ("roofs", "6.9"), 56: ("lights", "Light levels"), 57: ("lights", "Lamp reach"),
    58: ("lights", "Effects of darkness"),
    59: ("temperature", "Cooler"), 60: ("temperature", "Heater"), 61: ("temperature", "Vent"),
    62: ("temperature", "Heat leak"), 63: ("temperature", "freezer"), 64: ("temperature", "x0.7"),
    66: ("cleanliness", "Surgery"), 67: ("cleanliness", "Research speed"),
    70: ("work_speed", "WorkTableWorkSpeedFactor"), 71: ("storage", "Shelves"), 72: ("joy_furniture", "Television"),
    73: ("joy_furniture", "Billiards"), 74: ("children", "School desk"), 76: ("children", "toy box"),
    80: ("mechanitor", "Band node"), 82: ("genetics", "Gene assembler"), 88: ("movement", "Ticks to step"),
    89: ("movement", "Path costs"), 91: ("power_fire", "Power:"), 92: ("power_fire", "Rain"),
    97: ("practical", "Kitchen"), 99: ("practical", "Hospital"), 101: ("practical", "Bedroom size"),
    102: ("practical", "tiles next to doors"), 103: ("practical", "Workshop"),
    109: ("mods", "Dubs Skylights"), 110: ("mods", "Dubs Bad Hygiene"), 111: ("mods", "Dubs Central Heating"),
    112: ("mods", "LightsOut"), 113: ("mods", "Floors Are"), 114: ("mods", "Hospitality"),
    117: ("storage", "dumping stockpile"),
}

# Room kinds used by gen_base.py and the macro plans, folded to classes
KIND_CLASS = {
    "bedroom": "bedroom", "bedroom_couple": "bedroom", "bed": "bedroom", "suite": "bedroom", "quarters": "bedroom",
    "barracks": "barracks", "dorm": "barracks", "guest_room": "guest", "guest": "guest", "guestroom": "guest",
    "prison": "prison", "prison_cell": "prison", "prison_barracks": "prison", "cell": "prison",
    "hospital": "hospital", "clinic": "hospital", "surgery": "hospital", "ward": "hospital", "infirmary": "hospital",
    "kitchen": "kitchen", "workshop": "workshop", "brewery": "workshop", "smithy": "workshop",
    "lab": "lab", "laboratory": "lab", "research": "lab", "genetics": "lab", "gene_lab": "lab",
    "hall": "dining", "great_hall": "dining", "dining": "dining", "dining_room": "dining", "rec": "dining",
    "rec_room": "dining", "lounge": "dining", "guest_lounge": "dining",
    "storage": "storage", "store": "storage", "warehouse": "storage", "pantry": "storage", "armoury": "storage",
    "armory": "storage", "freezer": "freezer", "cold_store": "freezer", "butcher": "butcher", "butchery": "butcher",
    "school": "school", "classroom": "school", "kids": "kids", "nursery": "nursery", "playroom": "playroom",
    "bathroom": "bathroom", "washroom": "bathroom", "deathrest": "deathrest", "tomb": "tomb", "barn": "barn",
    "mech": "mech", "mech_bay": "mech", "power": "power", "battery": "power", "library": "library",
    "corridor": "corridor", "hallway": "corridor", "gate": "corridor", "gatehouse": "corridor",
}
EXPECTED_ROLES = {
    "bedroom": {"Bedroom"}, "barracks": {"Barracks"}, "guest": {"GuestRoom"},
    "prison": {"PrisonCell", "PrisonBarracks"}, "hospital": {"Hospital"}, "kitchen": {"Kitchen"},
    "workshop": {"Workshop"}, "lab": {"Laboratory"}, "dining": {"DiningRoom", "RecRoom"},
    "school": {"Classroom"}, "kids": {"Playroom", "Nursery", "Classroom"}, "nursery": {"Nursery"},
    "playroom": {"Playroom"}, "bathroom": {"PublicBathroom", "PrivateBathroom"}, "deathrest": {"DeathrestChamber"},
    "tomb": {"Tomb"}, "barn": {"Barn"},
}
SLEEP_CLASSES = {"bedroom", "barracks", "guest", "prison", "hospital", "kids", "nursery"}
WORK_CLASSES = {"kitchen", "workshop", "lab", "butcher", "mech", "school", "library", "storage", "freezer", "power"}
OUTDOOR_KINDS = {"court", "yard", "outdoor", "outside", "field", "farm", "garden", "lane", "pad", "ground"}
STOCKPILE_KINDS = {"stockpile", "dumping", "dumping_stockpile", "zone_stockpile", "stockpile_zone"}
NO_ROOF_KINDS = {"no_roof", "unroofed", "open_roof", "sky", "noroof"}
ROLE_KO = {"Bedroom": "침실", "Barracks": "막사", "PrisonCell": "수감실", "PrisonBarracks": "단체 수감실",
           "Hospital": "병실", "Laboratory": "연구소", "Kitchen": "주방", "Workshop": "작업소", "DiningRoom": "식당",
           "RecRoom": "휴게실", "Storeroom": "창고", "Barn": "축사", "Nursery": "보육실", "Playroom": "놀이방",
           "Classroom": "교실", "DeathrestChamber": "휴면실", "Room": "방", "Tomb": "무덤", "GuestRoom": "손님방",
           "PublicBathroom": "공용 화장실", "PrivateBathroom": "개인 화장실"}
ROLE_ORDER = ("PrisonCell", "PrisonBarracks", "GuestRoom", "Nursery", "Barracks", "Bedroom", "Hospital",
              "PrivateBathroom", "DeathrestChamber", "PublicBathroom", "Laboratory", "Tomb", "Kitchen", "Workshop",
              "DiningRoom", "Classroom", "Playroom", "Barn", "RecRoom", "Storeroom", "Room")
STAGES = [(-1e9, "awful"), (20, "dull"), (30, "mediocre"), (40, "decent"), (50, "slightly impressive"),
          (65, "somewhat impressive"), (85, "very impressive"), (120, "extremely impressive"),
          (170, "unbelievably impressive"), (240, "wondrously impressive")]
PLANT_BEAUTY = {"Plant_Rose": 14, "Plant_Daylily": 18}      # Core Plants_Cultivated_Decorative.xml


def stage_name(v):
    s = STAGES[0][1]
    for m, n in STAGES:
        if v >= m:
            s = n
    return s


def impress_factor(x):
    if abs(x) < 1:
        return x
    return 1 + math.log(x) if x > 0 else -1 - math.log(-x)


def impressiveness(wealth, beauty, space, clean):
    """RoomStatWorker_Impressiveness (R36)."""
    f = [impress_factor(wealth / 1500.0), impress_factor(beauty / 3.0), impress_factor(space / 125.0),
         impress_factor(1 + min(clean, 0.0) / 2.5)]
    avg = sum(f) / 4.0
    v = avg + (min(f) - avg) * 0.35
    cap = f[2] * 5
    if v > cap:
        v = v + (cap - v) * 0.75
    return v * 100.0


def load_rules(path):
    """rules.json and the cited ids re-checked against it: {id: (topic, ok, actual id)}."""
    status = {"path": path, "loaded": False, "checked": 0, "moved": {}, "missing": []}
    rules = None
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            rules = json.load(fh)
        status["loaded"] = True
    mapping = {}
    for rid, (topic, phrase) in RULE_REFS.items():
        mapping[rid] = rid
        if rules is None:
            continue
        status["checked"] += 1
        ok = rid < len(rules) and rules[rid].get("topic") == topic and phrase.lower() in rules[rid]["rule"].lower()
        if not ok:
            cands = [j for j, r in enumerate(rules) if r.get("topic") == topic and phrase.lower() in r["rule"].lower()]
            if cands:
                mapping[rid] = cands[0]
                status["moved"][rid] = cands[0]
            else:
                status["missing"].append(rid)
    return rules, mapping, status


class Item:
    """One furniture item, read back with its catalog def."""

    def __init__(self, raw, idx, catalog, problems):
        self.raw = raw
        self.idx = idx
        self.defname = str(raw.get("def") or "?")
        self.id = str(raw.get("id") or raw.get("key") or f"{self.defname}#{idx}")
        d = catalog.get(self.defname)
        self.n = fl.info(d) if d is not None else None
        n = self.n
        self.phase = int(raw.get("phase") or 0)
        self.stuff = raw.get("stuff")
        self.quality = raw.get("quality")
        rot_raw = raw.get("rot", None)
        try:
            rot = fl.rot_index(rot_raw)
        except ValueError:
            rot = 0
            problems.append(("error", 0, f"{self.id}: unknown rotation {rot_raw!r}"))
        self.rot = fl.effective_rot(n, rot) if n else rot
        if n and not n["rotatable"] and rot_raw is not None and rot != self.rot:
            problems.append(("warn", 2, f"{self.id}: {self.defname} is not rotatable, so it always stands at "
                                         f"{fl.ROTS[self.rot]} (the plan says {fl.ROTS[rot]})"))
        x, y = raw.get("x"), raw.get("y")
        w, h = int(raw.get("w", 1) or 1), int(raw.get("h", 1) or 1)
        if raw.get("pos") is not None:
            self.pos = (int(raw["pos"][0]), int(raw["pos"][1]))
        elif n and x is not None:
            self.pos = fl.place_by_rect(n, int(x), int(y), self.rot)
        else:
            sr = fl.sim_raids()
            self.pos = sr.thing_position(int(x), int(y), w, h, self.rot) if sr else (int(x), int(y))
        if n:
            self.cells = fl.footprint(n, self.pos, self.rot)
            rx, ry, rw, rh = fl.rect_of(self.cells)
            if x is not None and (int(x), int(y), w, h) != (rx, ry, rw, rh):
                problems.append(("error", 0, f"{self.id}: x,y,w,h {x},{y},{w},{h} is not the game footprint of "
                                             f"{self.defname} at pos {list(self.pos)} rot {fl.ROTS[self.rot]} "
                                             f"({rx},{ry},{rw},{rh})"))
            self.ics = fl.interaction_cells(n, self.pos, self.rot)
            if "interaction" in raw or "interaction_cells" in raw:
                given = raw.get("interaction_cells") or ([raw["interaction"]] if raw.get("interaction") else [])
                given = [tuple(c) for c in given]
                if not (given == self.ics or (len(given) == 1 and self.ics and given[0] == self.ics[0])):
                    problems.append(("error", 1, f"{self.id}: interaction cell {[list(c) for c in given]} in the "
                                                 f"plan, the game puts it at {[list(c) for c in self.ics]}"))
            self.pass_ = n["passability"]
            self.fill = n["fill"]
            self.path_cost = n["path_cost"]
            self.edifice = n["edifice"]
            self.layer = n["layer"]
            for key, mine in (("pass", self.pass_), ("edifice", self.edifice), ("layer", self.layer)):
                if raw.get(key) is not None and raw.get(key) != mine:
                    problems.append(("warn", 0, f"{self.id}: item says {key}={raw.get(key)!r}, the catalog says "
                                                f"{mine!r} (the catalog is used)"))
        else:
            xx, yy = (int(x), int(y)) if x is not None else self.pos
            self.cells = [(xx + i, yy + j) for j in range(h) for i in range(w)]
            given = raw.get("interaction_cells") or ([raw["interaction"]] if raw.get("interaction") else [])
            self.ics = [tuple(c) for c in given]
            self.pass_ = raw.get("pass") or raw.get("passability") or "Standable"
            self.fill = float(raw.get("fill", raw.get("fill_percent", 0.0)) or 0.0)
            self.path_cost = int(raw.get("path_cost") or 0)
            self.edifice = bool(raw.get("edifice", True))
            self.layer = raw.get("layer") or ("in_wall" if raw.get("over_wall") or raw.get("door") else
                                              ("edifice" if self.edifice else "floor_deco"))
            problems.append(("warn", 0, f"{self.id}: {self.defname} is not in the catalog; its own fields are used"))
        self.cellset = set(self.cells)
        self.room = raw.get("room")
        self.bed = n["bed"] if n else None
        if self.bed is None and raw.get("bed"):
            self.bed = {"slots": 1, "humanlike": True, "baby": False, "animal": False, "medical_default": False,
                        "counts_for_bedroom": True, "deathrest": False, "hospital_bed": False}
        self.medical = bool(raw.get("medical", self.bed["medical_default"] if self.bed else False))
        self.prisoner = bool(raw.get("prisoner"))
        self.guest = bool(raw.get("guest"))
        self.owned = bool(raw.get("owned_bed"))
        self.door = bool(raw.get("door")) or bool(n and n["sim_role"] in ("door", "free"))
        self.fence = bool(raw.get("fence")) or bool(n and n["sim_role"] == "fence")

    # convenient flags
    def has(self, key):
        return bool(self.n and self.n.get(key))

    @property
    def label(self):
        return f"{self.defname}@{self.pos[0]},{self.pos[1]}"


class Finding(dict):
    pass


class Validator:
    def __init__(self, plan, catalog, rules=None, rule_map=None, phase=None, hygiene_max=40.0, faw=True):
        self.plan = plan
        self.cat = catalog
        self.rules = rules
        self.rule_map = rule_map or {k: k for k in RULE_REFS}
        self.hygiene_max = hygiene_max
        self.faw = faw
        self.findings = []
        self.notes = []
        self.room_stats = {}
        self._load_cells(phase)
        self._load_rooms()
        self._load_items()
        self._build_grid()
        self._room_things()

    # ------------------------------------------------------------------ findings

    def add(self, level, rule, room, msg, cells=(), items=()):
        rid = self.rule_map.get(rule, rule)
        topic = RULE_REFS.get(rule, ("?",))[0]
        if self.rules and isinstance(rid, int) and rid < len(self.rules):
            topic = self.rules[rid].get("topic", topic)
        f = Finding(level=level, rule=f"R{rid}", topic=topic, room=room, msg=msg,
                    cells=[list(c) for c in list(cells)[:40]], items=list(items))
        self.findings.append(f)
        return f

    # ------------------------------------------------------------------ loading

    def _load_cells(self, phase):
        p = self.plan
        ox, oy = p.get("origin", [0, 0])
        rows = p["cells"]
        self.cell = {}
        maxph = 0
        for j, row in enumerate(rows):
            for i, c in enumerate(row):
                ph = (c[2] if len(c) > 2 else 0) or 0
                maxph = max(maxph, ph, (c[3] if len(c) > 3 else 0) or 0)
        for it in p.get("furniture") or []:
            maxph = max(maxph, int(it.get("phase") or 0))
        self.phase = maxph if phase is None else phase
        for j, row in enumerate(rows):
            for i, c in enumerate(row):
                t = c[0]
                rm = c[1] if len(c) > 1 else None
                ph = (c[2] if len(c) > 2 else 0) or 0
                dph = (c[3] if len(c) > 3 else 0) or 0
                mat = c[4] if len(c) > 4 else None
                if t in ("wall", "diag", "door", "gate") and ph > self.phase:
                    t = "ground"
                elif t in ("door", "gate") and dph > self.phase:
                    t = "wall"
                self.cell[(ox + i, oy + j)] = {"t": t, "room": rm, "mat": mat, "phase": ph}
        self.features = [f for f in (p.get("features") or []) if (f.get("phase") or 0) <= self.phase]
        self.stockpile = set()
        self.unroofed = set()
        self.floor_over = {}
        for f in self.features:
            k = str(f.get("kind") or "").lower()
            cells = [tuple(c[:2]) for c in f.get("cells") or []]
            if k in STOCKPILE_KINDS:
                self.stockpile.update(cells)
            elif k in NO_ROOF_KINDS:
                self.unroofed.update(cells)
            elif k == "floor":
                for c in cells:
                    self.floor_over[c] = f.get("floor") or f.get("def") or f.get("terrain")

    def ctype(self, c):
        e = self.cell.get(c)
        return e["t"] if e else None

    def _load_rooms(self):
        meta = {}
        for r in self.plan.get("rooms") or []:
            if r.get("key") is not None:
                meta[r["key"]] = r
        floors = collections.defaultdict(set)
        for c, e in self.cell.items():
            if e["t"] in ("floor", "ground") and e["room"] is not None:
                floors[e["room"]].add(c)
        self.rooms = {}
        for key in list(meta) + [k for k in floors if k not in meta]:
            m = meta.get(key, {"key": key})
            kind = str(m.get("kind") or "").lower() or None
            cls = KIND_CLASS.get(kind, kind)
            outdoor = (kind in OUTDOOR_KINDS) or m.get("outdoor") is True
            self.rooms[key] = {"key": key, "meta": m, "kind": kind, "cls": cls, "floor": floors.get(key, set()),
                               "outdoor": outdoor, "doors": set(), "walls": set(), "items": [], "touch": []}
        for key, r in self.rooms.items():
            fset = r["floor"]
            for (x, y) in fset:
                for dx, dy in N8:
                    c = (x + dx, y + dy)
                    t = self.ctype(c)
                    if t in ("door", "gate") and (dx == 0 or dy == 0):
                        r["doors"].add(c)
                    elif t in ("wall", "diag", "door", "gate"):
                        r["walls"].add(c)
            r["roofed"] = set() if (r["outdoor"] or r["meta"].get("roofed") is False) else (fset - self.unroofed)
            r["psych_outdoors"] = r["outdoor"] or len(fset - r["roofed"]) >= 300
            r["outdoor_temp"] = r["outdoor"] or (len(fset) and len(fset - r["roofed"]) >= math.ceil(0.25 * len(fset)))
        self.cell_room = {}
        for key, r in self.rooms.items():
            for c in r["floor"]:
                self.cell_room[c] = key

    def _load_items(self):
        problems = []
        self.items = []
        for i, raw in enumerate(self.plan.get("furniture") or []):
            if int(raw.get("phase") or 0) > self.phase:
                continue
            before = len(problems)
            it = Item(raw, i, self.cat, problems)
            if it.room is None:
                it.room = self.cell_room.get(it.pos) or next((self.cell_room[c] for c in it.cells
                                                              if c in self.cell_room), None)
                if it.room is None and it.layer == "in_wall":
                    rooms = sorted({self.cell_room[(c[0] + dx, c[1] + dy)] for c in it.cells for dx, dy in N4
                                    if (c[0] + dx, c[1] + dy) in self.cell_room})
                    it.room = rooms[0] if rooms else None
            for lvl, rule, msg in problems[before:]:
                self.add(lvl, rule, it.room, msg, it.cells, [it.id])
            self.items.append(it)
        self.items_at = collections.defaultdict(list)
        for it in self.items:
            for c in it.cells:
                self.items_at[c].append(it)
        self.by_id = {it.id: it for it in self.items}

    # ------------------------------------------------------------------ grid

    def floor_of(self, c):
        """(name, values, guessed) of the terrain on a cell."""
        e = self.cell.get(c)
        name = self.floor_over.get(c)
        if name is None and e is not None:
            if e["t"] == "floor":
                name = e["mat"] or self.rooms.get(e["room"], {}).get("meta", {}).get("floor")
            elif e["t"] == "ground":
                name = e["mat"] or "Soil"
        return fl.terrain_of(name)

    def _build_grid(self):
        """Per cell: walk (a pawn may enter), stand (Standable: no thing with another passability), full (a full-fill
        edifice: blocks diagonal steps and sight), light (blocks light), holder (holds roof), door, fence, cost."""
        self.walk, self.stand, self.full, self.light, self.holder = set(), set(), set(), set(), set()
        self.doorc, self.fencec, self.wallc = set(), set(), set()
        self.cost = {}
        for c, e in self.cell.items():
            t = e["t"]
            if t in ("wall", "diag"):
                self.full.add(c)
                self.light.add(c)
                self.holder.add(c)
                self.wallc.add(c)
            elif t in ("door", "gate"):
                self.walk.add(c)
                self.stand.add(c)
                self.full.add(c)
                self.light.add(c)
                self.holder.add(c)
                self.doorc.add(c)
                self.cost[c] = 0
            else:
                self.walk.add(c)
                self.stand.add(c)
                self.cost[c] = self.floor_of(c)[1][2]
        for it in self.items:
            for c in it.cells:
                if c not in self.cell:
                    continue
                t = self.cell[c]["t"]
                if it.layer == "ceiling":
                    continue
                if t in ("wall", "diag", "door", "gate"):
                    if it.layer != "in_wall" or not it.edifice:
                        continue                        # wall decorations leave the wall as it is
                    for s in (self.walk, self.stand, self.full, self.light, self.holder, self.doorc, self.wallc):
                        s.discard(c)
                    self.cost[c] = 0
                    if it.door:
                        self.walk.add(c)
                        self.stand.add(c)
                        self.doorc.add(c)
                        self.full.add(c)
                    else:
                        if it.pass_ != "Impassable":
                            self.walk.add(c)
                            if it.pass_ == "Standable":
                                self.stand.add(c)
                        else:
                            self.wallc.add(c)
                        if it.fill > 0.99:
                            self.full.add(c)
                    if it.n and it.n["block_light"]:
                        self.light.add(c)
                    if it.n and it.n["holds_roof"]:
                        self.holder.add(c)
                    continue
                if it.door:                              # a door item standing in a gap
                    self.doorc.add(c)
                    self.full.add(c)
                    self.light.add(c) if (not it.n or it.n["block_light"]) else None
                    self.holder.add(c)
                    continue
                self.cost[c] = max(self.cost.get(c, 0), it.path_cost)
                if it.pass_ == "Impassable":
                    self.walk.discard(c)
                    self.stand.discard(c)
                elif it.pass_ != "Standable":
                    self.stand.discard(c)
                if it.edifice and it.fill > 0.99:
                    self.full.add(c)
                if it.n and it.n["block_light"]:
                    self.light.add(c)
                if it.n and it.n["holds_roof"]:
                    self.holder.add(c)
                if it.fence:
                    self.fencec.add(c)

    def opaque(self, c):
        """GenGrid.CanBeSeenOverFast is false: a full-fill edifice that is not an open door (doors count closed)."""
        return c in self.full or c not in self.cell

    def los_rect(self, start, end, srect, erect):
        """GenSight.LineOfSight(start, end, map, startRect, endRect) in game coordinates (GenSight.cs:70-120)."""
        sx, sz, ex, ez = start[0], -start[1], end[0], -end[1]
        flag = (sx < ex) if sx != ex else (sz < ez)
        a, b = abs(ex - sx), abs(ez - sz)
        x, z = sx, sz
        steps = 1 + a + b
        stx = 1 if ex > sx else -1
        stz = 1 if ez > sz else -1
        err = a - b
        a2, b2 = 2 * a, 2 * b
        while steps > 1:
            c = (x, -z)
            if c in erect:
                return True
            if c not in srect and self.opaque(c):
                return False
            if err > 0 or (err == 0 and flag):
                x += stx
                err -= b2
            else:
                z += stz
                err += a2
            steps -= 1
        return True

    def los(self, start, end, skip_first=True):
        """GenSight.LineOfSight(start, end, map, skipFirstCell) (GenSight.cs:20-68); the end cell is not checked."""
        sx, sz, ex, ez = start[0], -start[1], end[0], -end[1]
        flag = (sx < ex) if sx != ex else (sz < ez)
        a, b = abs(ex - sx), abs(ez - sz)
        x, z = sx, sz
        steps = 1 + a + b
        stx = 1 if ex > sx else -1
        stz = 1 if ez > sz else -1
        a4, b4 = 4 * a, 4 * b
        err = a4 // 2 - b4 // 2
        while steps > 1:
            c = (x, -z)
            if (not skip_first or c != start) and self.opaque(c):
                return False
            if err > 0 or (err == 0 and flag):
                x += stx
                err -= b4
            else:
                z += stz
                err += a4
            steps -= 1
        return True

    def los_things(self, a, b):
        """CompAffectedByFacilities LOS: some cell of a sees some cell of b (walls and closed doors block)."""
        for s in a.cells:
            for e in b.cells:
                if self.los_rect(s, e, a.cellset, b.cellset):
                    return True
        return False

    def _room_things(self):
        for it in self.items:
            if it.room in self.rooms:
                self.rooms[it.room]["items"].append(it)
        for key, r in self.rooms.items():
            near = set()
            for (x, y) in r["floor"]:
                for dx, dy in N8:
                    near.add((x + dx, y + dy))
            seen = set()
            for c in near - r["floor"]:
                for it in self.items_at.get(c, ()):
                    if it.layer == "in_wall" and it.id not in seen and it.room != key:
                        seen.add(it.id)
                        r["touch"].append(it)

    # ------------------------------------------------------------------ movement

    def step_ok(self, a, b, allowed=None, clear=False):
        """A colonist step a -> b: b walkable (and Standable on a clear route); a diagonal needs both side cells
        walkable and free of full-fill edifices and fences (PathFinderJob.cs:147-155)."""
        if b not in self.walk or (allowed is not None and b not in allowed):
            return False
        if clear and b not in self.stand:
            return False
        dx, dy = b[0] - a[0], b[1] - a[1]
        if dx and dy:
            for s in ((a[0] + dx, a[1]), (a[0], a[1] + dy)):
                if s not in self.walk or s in self.full or s in self.fencec:
                    return False
        return True

    def dijkstra(self, sources, allowed=None, clear=False, cells_metric=False):
        """Ticks (13 straight, 18 diagonal, plus each entered cell's path cost) or cells (1 / 1.414) from sources."""
        dist = {}
        pq = []
        for s in sources:
            if s in self.walk:
                dist[s] = 0.0
                heapq.heappush(pq, (0.0, s))
        while pq:
            d, c = heapq.heappop(pq)
            if d > dist.get(c, INF):
                continue
            for dx, dy in N8:
                n = (c[0] + dx, c[1] + dy)
                if not self.step_ok(c, n, allowed, clear):
                    continue
                diag = dx != 0 and dy != 0
                if cells_metric:
                    nd = d + (1.41421 if diag else 1.0)
                else:
                    nd = d + (18 if diag else 13) + self.cost.get(n, 0)
                if nd < dist.get(n, INF):
                    dist[n] = nd
                    heapq.heappush(pq, (nd, n))
        return dist

    # ------------------------------------------------------------------ run

    def run(self):
        self.check_rooms_shape()
        self.check_footprints()
        self.check_edifices()
        self.check_interaction_cells()
        self.check_doors()
        self.check_beds()
        self.check_facilities()
        self.check_joy()
        self.check_reachability()
        self.check_roles()
        self.check_stats()
        self.check_light()
        self.check_roof()
        self.check_temperature()
        self.check_hygiene()
        self.check_power()
        return self

    # ------------------------------------------------------------------ room shape (R18, R22)

    def check_rooms_shape(self):
        for key, r in self.rooms.items():
            if r["outdoor"] or not r["floor"]:
                continue
            leaks = collections.defaultdict(set)
            for (x, y) in r["floor"]:
                for dx, dy in N4:
                    c = (x + dx, y + dy)
                    other = self.cell_room.get(c)
                    if other is not None and other != key and c in self.walk and (x, y) in self.walk:
                        leaks[other].add((x, y))
            for other, cells in sorted(leaks.items(), key=str):
                if self.rooms.get(other, {}).get("outdoor") and not r["outdoor"]:
                    self.add("warn", 18, key, f"open to outdoor area {other} without a wall or door: the room is not "
                                              "closed, so it is outdoors for roles, stats and temperature", cells)
                else:
                    self.add("warn", 18, key, f"touches room {other} with no wall or door between: the game merges "
                                              "them into one room (rooms flood through cardinal neighbours)", cells)
            # one room or split by full-fill furniture?
            free = {c for c in r["floor"] if c not in self.full and (c in self.walk or c not in self.wallc)}
            if free:
                start = next(iter(sorted(free)))
                seen = {start}
                dq = collections.deque([start])
                while dq:
                    c = dq.popleft()
                    for dx, dy in N4:
                        n = (c[0] + dx, c[1] + dy)
                        if n in free and n not in seen:
                            seen.add(n)
                            dq.append(n)
                if len(seen) < len(free):
                    self.add("warn", 18, key, f"full-fill buildings split the room into more than one room "
                                              f"({len(free) - len(seen)} cells cut off)", sorted(free - seen))
            if not r["doors"] and not r["outdoor"] and not any(it.door for it in r["touch"]):
                self.add("warn", 14, key, "no door: nobody can get in (or the door is missing from the plan)")

    # ------------------------------------------------------------------ footprints (R0, R10, R11)

    def check_footprints(self):
        for it in self.items:
            room = it.room
            r = self.rooms.get(room)
            if room is not None and r is None:
                self.add("warn", 0, room, f"{it.id}: room {room!r} is not in the plan's rooms", it.cells, [it.id])
            types = {c: self.ctype(c) for c in it.cells}
            if any(t is None for t in types.values()):
                self.add("error", 0, room, f"{it.id}: footprint leaves the plan grid", it.cells, [it.id])
                continue
            if it.layer == "in_wall":
                bad = [c for c, t in types.items() if t not in ("wall", "diag", "door", "gate")]
                if bad and not it.door:
                    self.add("warn", 18, room, f"{it.id}: in-wall {it.defname} stands on {len(bad)} floor cell(s); "
                                               "it is meant to replace wall cells", bad, [it.id])
                if it.n and it.defname == "FreezerUnit":
                    front = fl.side_cells(it.cells, fl.FACING[(it.rot + 2) % 4])
                    blocked = [c for c in front if c not in self.walk]
                    if blocked:
                        self.add("error", 111, room, f"{it.id}: walk-in freezer unit needs both cells on its front "
                                                     "(-Z) side free of impassable things", blocked, [it.id])
                if it.n and it.n["cool"] and it.defname != "FreezerUnit" or it.has("vent"):
                    self._check_cooler_sides(it)
                continue
            outside = [c for c in it.cells if types[c] not in ("floor", "ground")]
            if outside:
                self.add("error", 10 if it.layer == "wall_attach" else 11, room,
                         f"{it.id}: {it.defname} ({it.layer}) stands on {types[outside[0]]} cell(s); only in-wall "
                         "items (coolers, vents, freezer units, doors, stall doors, wall fridges, embrasures) may "
                         "replace a wall cell", outside, [it.id])
                continue
            if r is not None and not r["outdoor"]:
                strays = [c for c in it.cells if self.cell_room.get(c) != room]
                if strays:
                    self.add("error", 0, room, f"{it.id}: footprint leaves room {room} (cells in "
                                               f"{sorted({str(self.cell_room.get(c)) for c in strays})})",
                             strays, [it.id])
            if it.layer == "wall_attach":
                vx, vy = fl.FACING[it.rot]
                for c in it.cells:
                    wcell = (c[0] + vx, c[1] + vy)
                    if self.ctype(wcell) not in ("wall", "diag") or wcell not in self.full or wcell in self.doorc:
                        self.add("error", 10, room, f"{it.id}: wall attachment {it.defname} faces "
                                                    f"{fl.ROTS[it.rot]} but {list(wcell)} is not a full wall "
                                                    "(it must stand on the floor cell in front of a wall and point "
                                                    "at it)", [c, wcell], [it.id])
                    fullhere = [o for o in self.items_at[c] if o is not it and o.edifice and o.fill > 0.99]
                    if fullhere:
                        self.add("error", 10, room, f"{it.id}: its cell holds a full-fill building "
                                                    f"({fullhere[0].id})", [c], [it.id])
            if it.layer == "ceiling":
                imp = [c for c in it.cells if c not in self.walk]
                if imp:
                    self.add("error", 111, room, f"{it.id}: ceiling item over an impassable cell", imp, [it.id])
                if it.defname.startswith("SkyLight") and r is not None and set(it.cells) - r["roofed"]:
                    self.add("error", 109, room, f"{it.id}: a skylight needs a constructed roof over every cell",
                             it.cells, [it.id])
            if r is not None and it.phase < int(r["meta"].get("phase") or 0):
                self.add("warn", 0, room, f"{it.id}: furniture phase {it.phase} comes before its room "
                                          f"(phase {r['meta'].get('phase')})", it.cells, [it.id])

    def _check_cooler_sides(self, it):
        """Building_Cooler / vent: both sides (P +/- the facing cell) must not be impassable (R59, R61)."""
        vx, vy = fl.FACING[it.rot]
        p = it.pos
        hot, cold = (p[0] + vx, p[1] + vy), (p[0] - vx, p[1] - vy)
        rule = 61 if it.has("vent") else 59
        for c, side in ((hot, "front/hot"), (cold, "back/cold")):
            if c not in self.walk:
                self.add("error", rule, it.room, f"{it.id}: {side} side {list(c)} is blocked; both sides must be "
                                                 "open", [c], [it.id])
        it.hot, it.cold = hot, cold

    # ------------------------------------------------------------------ one edifice per cell (R11)

    def check_edifices(self):
        seen = set()
        for c, its in self.items_at.items():
            ed = [it for it in its if it.edifice and it.layer in ("edifice", "in_wall")]
            if len(ed) > 1:
                key = tuple(sorted(it.id for it in ed))
                if key in seen:
                    continue
                seen.add(key)
                self.add("error", 11, ed[0].room, f"two edifices on one cell: {', '.join(it.id for it in ed)}",
                         [c], [it.id for it in ed])
            att = collections.Counter(it.rot for it in its if it.layer == "wall_attach")
            for rot, k in att.items():
                if k > 1:
                    self.add("error", 10, its[0].room, f"{k} wall attachments on one cell face {fl.ROTS[rot]}",
                             [c], [it.id for it in its if it.layer == "wall_attach"])
            fans = [it for it in its if it.defname.startswith("CeilingFan")]
            if len(fans) > 1:
                self.add("error", 111, fans[0].room, "two ceiling fans over one cell", [c], [f.id for f in fans])

    # ------------------------------------------------------------------ interaction cells (R5-R8)

    def check_interaction_cells(self):
        users = collections.defaultdict(list)
        for it in self.items:
            for ic in it.ics:
                users[ic].append(it)
        for it in self.items:
            for k, ic in enumerate(it.ics):
                room = it.room
                what = "student/teacher seat" if len(it.ics) > 1 else "interaction cell"
                if ic in self.doorc:
                    self.add("error", 8, room, f"{it.id}: {what} {list(ic)} is on a door: a pawn there holds the "
                                               "door open", [ic], [it.id])
                    continue
                t = self.ctype(ic)
                if t not in ("floor", "ground") or ic not in self.walk:
                    self.add("error", 5, room, f"{it.id}: {what} {list(ic)} is on a {t or 'missing'} cell",
                             [ic], [it.id])
                    continue
                ic_room = self.cell_room.get(ic)
                if it.layer != "in_wall" and room is not None and ic_room != room:
                    self.add("error", 5, room, f"{it.id}: {what} {list(ic)} is outside the room (in {ic_room})",
                             [ic], [it.id])
                blockers = [o for o in self.items_at.get(ic, ()) if o is not it and o.layer != "ceiling"
                            and o.pass_ != "Standable"]
                if blockers:
                    self.add("error", 5 if blockers[0].phase <= it.phase else 6, room,
                             f"{it.id}: {what} {list(ic)} holds {blockers[0].id} ({blockers[0].pass_}); only "
                             "Standable things (chairs, stools, conduits, wall lamps) may stand there", [ic],
                             [it.id] + [b.id for b in blockers])
                others = [o for o in users[ic] if o is not it]
                if others and it.idx < min(o.idx for o in others):
                    self.add("error", 7, room, f"{it.id} and {', '.join(o.id for o in others)} share the "
                                               f"interaction cell {list(ic)}; only one pawn can stand there",
                             [ic], [it.id] + [o.id for o in others])

    # ------------------------------------------------------------------ doors (R8, R13, R16, R17, R102)

    def door_cells(self):
        return sorted(self.doorc)

    def check_doors(self):
        for d in self.door_cells():
            rooms = sorted({self.cell_room[(d[0] + dx, d[1] + dy)] for dx, dy in N4
                            if (d[0] + dx, d[1] + dy) in self.cell_room}, key=str)
            room = rooms[0] if rooms else None
            bad = [it for it in self.items_at.get(d, ()) if not it.door and it.layer != "ceiling"
                   and (it.pass_ != "Standable" or it.edifice)]
            if bad:
                self.add("error", 8, room, f"door {list(d)} holds {bad[0].id}: keep door cells free", [d],
                         [b.id for b in bad])
            if d in self.stockpile:
                self.add("error", 8, room, f"stockpile zone on door {list(d)}: items there hold the door open", [d])
            for dx, dy in N4:
                c = (d[0] + dx, d[1] + dy)
                if self.ctype(c) not in ("floor", "ground"):
                    continue
                r = self.cell_room.get(c)
                block = [it for it in self.items_at.get(c, ()) if it.layer not in ("ceiling",)
                         and it.pass_ != "Standable"]
                if block:
                    self.add("error", 17, r, f"{block[0].id} stands in the first cell {list(c)} inside door "
                                             f"{list(d)}: keep it free (only Standable things)", [c],
                             [b.id for b in block])
                elif any(it.edifice and it.path_cost > 0 for it in self.items_at.get(c, ())):
                    chairs = [it.id for it in self.items_at.get(c, ()) if it.edifice]
                    self.add("warn", 17, r, f"{chairs[0]} in front of door {list(d)} slows every pawn walking "
                                            "through", [c], chairs)
                if c in self.stockpile:
                    self.add("error", 102, r, f"stockpile cell {list(c)} touches door {list(d)}: pawns drop items "
                                              "and stand in the doorway", [c])
            for dx, dy in N8:
                c = (d[0] + dx, d[1] + dy)
                shelves = [it for it in self.items_at.get(c, ()) if it.has("hauled_to")]
                if shelves:
                    lvl = "error" if (dx == 0 or dy == 0) else "warn"
                    self.add(lvl, 102, self.cell_room.get(c), f"{shelves[0].id} touches door {list(d)}: haulers "
                                                              "stand in the doorway and hold it open", [c],
                             [s.id for s in shelves])
                elif dx and dy and c in self.stockpile:
                    self.add("warn", 102, self.cell_room.get(c), f"stockpile cell {list(c)} touches door "
                                                                 f"{list(d)} diagonally", [c])
            for dx, dy in ((1, 0), (0, 1)):
                c = (d[0] + dx, d[1] + dy)
                if c in self.doorc and not self._same_door(d, c):
                    self.add("warn", 13, room, f"doors {list(d)} and {list(c)} are back to back: +45 path cost; "
                                               "an airlock needs one free cell between them", [d, c])
        for it in self.items:
            if it.door and it.n and max(it.n["size"]) > 1:
                # DoorUtility.WallRequirementCells: one full-fill non-door wall beyond each end of the long axis
                cells = sorted(it.cells)
                x0, y0, w, h = fl.rect_of(cells)
                ends = [(x0 - 1, y0), (x0 + w, y0)] if w > 1 else [(x0, y0 - 1), (x0, y0 + h)]
                miss = [c for c in ends if not (c in self.full and c not in self.doorc and c in self.wallc)]
                if miss:
                    self.add("error", 16, it.room, f"{it.id}: multi-cell door needs a wall beyond each end, "
                                                   "else it is stuck open", miss, [it.id])

    def _same_door(self, a, b):
        return any(b in it.cellset for it in self.items_at.get(a, ()) if it.door)

    # ------------------------------------------------------------------ beds (R3, R4, R24, R26, R27, R49, R50, R114)

    def beds_in(self, r):
        return [it for it in r["items"] if it.bed and it.layer == "edifice"]

    def bed_side_cells(self, b):
        """Cells beside and beyond the foot of a bed that a pawn could step from, in the bed's room."""
        n = b.n
        heads = set(fl.bed_head_cells(n, b.pos, b.rot)) if n else set()
        hv = fl.bed_head_dir(b.rot)
        out = []
        for (x, y) in b.cells:
            for dx, dy in N4:
                c = (x + dx, y + dy)
                if c in b.cellset or ((x, y) in heads and (dx, dy) == hv):
                    continue
                if self.cell_room.get(c) == b.room and c in self.stand and c not in self.doorc:
                    out.append(c)
        return sorted(set(out))

    def check_beds(self):
        for key, r in self.rooms.items():
            beds = self.beds_in(r)
            cls = r["cls"]
            humans = [b for b in beds if b.bed["humanlike"] and b.bed["counts_for_bedroom"]]
            for b in beds:
                if not b.n:
                    continue
                heads = fl.bed_head_cells(b.n, b.pos, b.rot)
                hv = fl.bed_head_dir(b.rot)
                behind = [(c[0] + hv[0], c[1] + hv[1]) for c in heads]
                if not b.bed["baby"] and not all(self.ctype(c) in ("wall", "diag") for c in behind):
                    self.add("warn", 4, key, f"{b.id}: bed head is not against a wall (pillow side {fl.ROTS[(b.rot + 2) % 4]}"
                                             f", foot {fl.ROTS[b.rot]})", behind, [b.id])
                if not self.bed_side_cells(b):
                    self.add("error", 4, key, f"{b.id}: no free walkable cell beside the bed", b.cells, [b.id])
            prisoners = [b for b in humans if b.prisoner or cls == "prison"]
            if prisoners and len(prisoners) < len(humans):
                self.add("error", 24, key, "prisoner and colonist beds in one room: every bed becomes a prisoner bed",
                         [], [b.id for b in humans])
            guests = [b for b in humans if b.guest or cls == "guest"]
            if guests and len(guests) < len(humans):
                self.add("error", 114, key, "guest beds (Hospitality) and colonist beds in one room: the room becomes "
                                            "a guest room (110000 per guest bed)", [], [b.id for b in humans])
            if cls == "bedroom":
                adults = [b for b in humans if not b.bed["baby"]]
                if len(adults) > 1:
                    couple = r["meta"].get("couple") or all(b.raw.get("couple") for b in adults)
                    self.add("warn" if couple else "error", 26, key,
                             f"{len(adults)} beds in a bedroom: it stays a bedroom only if every bed is owned by one "
                             "couple" + ("" if couple else "; otherwise it is a barracks"), [], [b.id for b in adults])
                if any(b.medical for b in humans):
                    self.add("error", 26, key, "a medical bed in a bedroom cancels the Bedroom role", [],
                             [b.id for b in humans if b.medical])
            if cls == "hospital":
                for b in humans:
                    if not b.medical:
                        self.add("error", 27, key, f"{b.id}: a normal bed in the hospital makes the room a barracks "
                                                   "(100100 > 100000); use hospital beds or set it Medical",
                                 b.cells, [b.id])
                    elif not b.bed["hospital_bed"]:
                        self.add("warn", 50, key, f"{b.id}: {b.defname} set Medical: vitals monitors cannot link to "
                                                  "it (only hospital beds)", b.cells, [b.id])
            if cls in ("nursery", "kids") and any(not b.bed["baby"] for b in humans):
                self.add("warn", 31, key, "a bed for bigger pawns cancels the Nursery role (cribs only)", [],
                         [b.id for b in humans if not b.bed["baby"]])

    # ------------------------------------------------------------------ facilities (R48-R53, R82)

    @staticmethod
    def _others(link):
        o = link.get("other")
        return set(o) if isinstance(o, list) else ({o} if o else set())

    def _link_spec(self, F, A):
        if not (F.n and A.n):
            return None
        for l in F.n["facility_links"]:
            if l.get("role") == "facility" and A.defname in self._others(l):
                return l
        for l in A.n["facility_links"]:
            if l.get("role") == "affected" and F.defname in self._others(l):
                return l
        return None

    def _link_ok(self, F, A, spec):
        """CompAffectedByFacilities.CanPotentiallyLinkTo_Static + IsPotentiallyValidFacilityForMe_Static."""
        eff = (spec.get("effect") or "").lower()
        if "gravship" in eff or "same-room binding" in eff:
            return None                              # not a CompFacility distance link; not checked here
        if "head cell on a cardinal side" in eff:
            if not A.bed:
                return False, INF
            heads = fl.bed_head_cells(A.n, A.pos, A.rot)
            ok = any(h in F.cellset or any((h[0] + dx, h[1] + dy) in F.cellset for dx, dy in N4) for h in heads)
            if ok and "and face" in eff:
                v = fl.FACING[F.rot]
                ok = any((c[0] + v[0], c[1] + v[1]) in set(heads) for c in F.cells)
            dist = 0.0
        elif "must touch" in eff or "mustbeplacedadjacent" in eff or "8-way" in eff:
            ok = any((c[0] + dx, c[1] + dy) in A.cellset for c in F.cells for dx, dy in N8 + ((0, 0),))
            dist = 0.0
        elif "interaction cell" in eff:
            ok = any(c in set(A.ics) for c in F.cells)
            dist = 0.0
        else:
            ax, ay = fl.true_center(A.n, A.pos, A.rot)
            bx, by = fl.true_center(F.n, F.pos, F.rot)
            dist = math.hypot(ax - bx, ay - by)
            maxd = spec.get("max_distance")
            maxd = 8.0 if maxd is None else float(maxd)      # CompProperties_Facility.maxDistance default 8
            ok = dist <= maxd
        if ok and "no line of sight" not in eff and "requireslos false" not in eff:
            ok = self.los_things(A, F)
        return ok, dist

    FAC_RULE = {"EndTable": 49, "Dresser": 49, "VitalsMonitor": 50, "ToolCabinet": 51, "MultiAnalyzer": 52,
                "Blackboard": 53, "GeneBank": 82, "GeneProcessor": 82}

    def check_facilities(self):
        facs = [it for it in self.items if it.n and any(l.get("role") == "facility" for l in it.n["facility_links"])]
        affected = [it for it in self.items if it.n and it.n["facility_links"]]
        links = collections.defaultdict(list)          # (A.id, F.def) -> [(dist, F)]
        possible = collections.defaultdict(list)       # F.id -> [A]
        maxsim = {}
        for F in facs:
            for A in affected:
                if A is F:
                    continue
                spec = self._link_spec(F, A)
                if spec is None:
                    continue
                res = self._link_ok(F, A, spec)
                if res is None:
                    possible[F.id].append(None)
                    continue
                ok, dist = res
                if ok:
                    links[(A.id, F.defname)].append((dist, F))
                    possible[F.id].append(A)
                    maxsim[(A.id, F.defname)] = int(spec.get("max_simultaneous") or 1)
        used = collections.defaultdict(list)
        for (aid, fdef), lst in links.items():
            lst.sort(key=lambda t: (t[0], t[1].idx))
            k = maxsim[(aid, fdef)]
            A = self.by_id[aid]
            for dist, F in lst[:k]:
                used[F.id].append(aid)
            if len(lst) > k:
                rule = self.FAC_RULE.get(fdef, 48)
                self.add("warn", rule, A.room, f"{A.id}: {len(lst)} {fdef} in range but only {k} count",
                         [], [A.id] + [F.id for _, F in lst[k:]])
        self.facility_links = used
        for F in facs:
            if any(p is None for p in possible.get(F.id, [])):
                continue
            rule = self.FAC_RULE.get(F.defname, 48)
            if not possible.get(F.id):
                why = ""
                if F.defname == "VitalsMonitor":
                    near_beds = [A for A in self.items if A.bed and any(
                        (c[0] + dx, c[1] + dy) in A.cellset for c in F.cells for dx, dy in N8)]
                    why = (" (it touches only normal beds: vitals monitors link to hospital beds)" if near_beds else
                           " (it must touch a hospital bed, diagonals count)")
                elif F.defname == "EndTable":
                    why = " (it must touch a bed's head cell on a N/E/S/W side)"
                else:
                    sp = next((l for l in F.n["facility_links"] if l.get("role") == "facility"), {})
                    md = sp.get("max_distance") or 8
                    why = f" (needs {', '.join(sorted(self._others(sp)))[:80]} within {md} with line of sight)"
                self.add("error", rule, F.room, f"{F.id}: links to nothing{why}", F.cells, [F.id])
            elif not used.get(F.id):
                self.add("warn", rule, F.room, f"{F.id}: every building in range already has enough {F.defname}",
                         F.cells, [F.id])
        # beds without bed furniture (advice) and benches without tool cabinets (advice)
        for key, r in self.rooms.items():
            if r["cls"] not in ("bedroom", "guest", "barracks"):
                continue
            for b in self.beds_in(r):
                if b.bed["baby"] or not b.n:
                    continue
                got = {fd for (aid, fd) in links if aid == b.id}
                missing = [x for x in ("EndTable", "Dresser") if not any(fd == x or fd.endswith(x[3:]) for fd in got)]
                if missing:
                    self.add("info", 49, key, f"{b.id}: no {' or '.join(missing)} linked (+0.05 comfort each)",
                             b.cells, [b.id])

    # ------------------------------------------------------------------ joy (R72, R73, R43)

    def watch_cells(self, tv):
        rects = fl.watch_rects(tv.n, tv.pos, tv.rot)
        room = self.cell_room.get(tv.pos) or tv.room
        out = []
        for (x0, y0, w, h) in rects:
            for j in range(h):
                for i in range(w):
                    c = (x0 + i, y0 + j)
                    if self.cell_room.get(c) != room:
                        continue
                    bed = any(o.bed for o in self.items_at.get(c, ()))
                    if not (c in self.stand or bed):
                        continue
                    if self.los(tv.pos, c, skip_first=True):
                        out.append(c)
        return out

    def check_joy(self):
        self.watch = {}
        for it in self.items:
            if not it.n:
                continue
            n = it.n
            room = it.room
            if n["watch"]:
                cells = self.watch_cells(it)
                self.watch[it.id] = cells
                rule = 72 if (n["watch"]["min"] != n["watch"]["max"] or n["rotatable"]) else 73
                if not cells:
                    self.add("error", rule, room, f"{it.id}: no cell to use it from (watch area "
                                                  f"{n['watch']['min']}-{n['watch']['max']} cells, "
                                                  f"{n['watch']['width']} wide, same room, Standable, line of sight)",
                             it.cells, [it.id])
                elif rule == 72:
                    seats = [c for c in cells if any(o.has("sittable") for o in self.items_at.get(c, ()))]
                    facing = [c for c in seats if any(o.has("sittable") and o.rot == (it.rot + 2) % 4
                                                      for o in self.items_at.get(c, ()))]
                    self.add("info", 72, room, f"{it.id}: {len(cells)} watch cells, {len(seats)} seats "
                                               f"({len(facing)} facing it)", cells, [it.id])
            if n["billiards"]:
                ring = set()
                for (x, y) in it.cells:
                    for dx, dy in N8:
                        c = (x + dx, y + dy)
                        if c not in it.cellset:
                            ring.add(c)
                bad = sorted(c for c in ring if c not in self.stand)
                if bad:
                    self.add("error", 73, room, f"{it.id}: billiards needs every cell of the ring around it Standable",
                             bad, [it.id])
            if n["requires_chair"]:
                adj = {(c[0] + dx, c[1] + dy) for c in it.cells for dx, dy in N4} - it.cellset
                if not any(o.has("sittable") and o.edifice for c in adj for o in self.items_at.get(c, ())):
                    self.add("error", 73, room, f"{it.id}: needs a chair on a N/E/S/W side", sorted(adj), [it.id])
        # dining chairs need a table on a cardinal side (R43)
        ic_cells = {c for it in self.items for c in it.ics}
        game = [it for it in self.items if it.has("requires_chair")]
        for key, r in self.rooms.items():
            if r["cls"] not in ("dining", "kitchen", "prison", "guest"):
                continue
            for ch in r["items"]:
                if not ch.has("sittable") or not ch.edifice:
                    continue
                c = ch.pos
                if c in ic_cells or any(c in {(g[0] + dx, g[1] + dy) for g in gm.cells for dx, dy in N4}
                                        for gm in game):
                    continue
                if any(c in cells for cells in self.watch.values()):
                    continue
                if not any(o.has("eat") for dx, dy in N4 for o in self.items_at.get((c[0] + dx, c[1] + dy), ())):
                    self.add("warn", 43, key, f"{ch.id}: chair with no table on a N/E/S/W side: eating there gives "
                                              "'ate without table'", [c], [ch.id])

    # ------------------------------------------------------------------ reachability (R9, R4, R71, R72, R89, R110)

    def check_reachability(self):
        self.reach = {}
        for key, r in self.rooms.items():
            if not r["floor"] or r["outdoor"]:
                continue
            doors = set(r["doors"]) | {c for it in r["touch"] if it.door for c in it.cells}
            if not doors:
                continue
            allowed = r["floor"] | doors
            dist = self.dijkstra(doors, allowed)
            clear = self.dijkstra(doors, allowed, clear=True)
            self.reach[key] = (dist, clear)
            for it in r["items"]:
                if it.layer == "ceiling":
                    continue
                for ic in it.ics:
                    if ic not in allowed:
                        continue
                    if ic not in dist:
                        self.add("error", 9, key, f"{it.id}: interaction cell {list(ic)} cannot be reached from the "
                                                  "door", [ic], [it.id])
                    elif ic not in clear:
                        self.add("warn", 89, key, f"{it.id}: interaction cell {list(ic)} is reached only by walking "
                                                  "over furniture", [ic], [it.id])
                if it.bed and it.layer == "edifice":
                    sides = self.bed_side_cells(it)
                    if sides and not any(c in clear for c in sides):
                        self.add("error", 4, key, f"{it.id}: no free cell beside the bed can be reached from the door",
                                 sides, [it.id])
                if it.has("hauled_to"):
                    bad = [c for c in it.cells if not self._touchable(c, it, clear)]
                    if bad:
                        self.add("error", 71, key, f"{it.id}: storage cell(s) no hauler can reach", bad, [it.id])
                if it.n and it.n["hygiene"] and not it.ics:
                    if not any((c in dist) for c in it.cells) or not any(self._touchable(c, it, clear) for c in it.cells):
                        self.add("error", 110, key, f"{it.id}: {it.n['hygiene']} cannot be reached from the door",
                                 it.cells, [it.id])
                if it.id in getattr(self, "watch", {}) and self.watch[it.id]:
                    if not any(c in dist for c in self.watch[it.id]):
                        self.add("error", 72, key, f"{it.id}: no watch cell can be reached from the door",
                                 self.watch[it.id], [it.id])
            free = [c for c in r["floor"] if c in self.walk and c not in dist]
            if free:
                self.add("warn", 9, key, f"{len(free)} walkable cell(s) cannot be reached from the door", free)

    def _touchable(self, c, thing, reached):
        """A cell of a thing used by touch: some reached Standable neighbour; a diagonal neighbour needs one side cell
        walkable and not a door (TouchPathEndModeUtility.IsCornerTouchAllowed)."""
        for dx, dy in N8:
            n = (c[0] + dx, c[1] + dy)
            if n in thing.cellset or n not in reached or n not in self.stand:
                continue
            if dx and dy:
                s1, s2 = (c[0] + dx, c[1]), (c[0], c[1] + dy)
                if not any(s in self.walk and s not in self.doorc for s in (s1, s2)):
                    continue
            return True
        return False

    # ------------------------------------------------------------------ roles (R25-R31, R70, R110, R114)

    def role_scores(self, r):
        things = list(r["items"]) + list(r["touch"])
        beds = [b for b in things if b.bed and b.bed["humanlike"]]
        cb = [b for b in beds if b.bed["counts_for_bedroom"]]
        cls = r["cls"]

        anyp = cls == "prison" or any(b.prisoner for b in beds)     # one prisoner bed converts them all (R24)

        def prisoner(b):
            return anyp

        def guest(b):
            return b.guest or cls == "guest"
        s = {"Room": 0.99}
        notes = []
        if cb and not any(b.medical or prisoner(b) for b in cb):
            s["Bedroom"] = 100000 if self._is_bedroom(cb, r, notes) else 0
        if cb and not any(prisoner(b) for b in cb) and not self._is_bedroom(cb, r, []):
            s["Barracks"] = 100100 * sum(1 for b in cb if not b.medical)
        for b in beds:
            if prisoner(b):
                break
            if b.medical:
                s["Hospital"] = 100000
                break
        if beds and all(prisoner(b) for b in beds):
            normal = sum(1 for b in beds if not b.medical)
            med = len(beds) - normal
            if normal == 1:
                s["PrisonCell"] = 170000
            elif med == 1:
                s["PrisonCell"] = 100000
            if normal + med > 1:
                s["PrisonBarracks"] = normal * 100100 + med * 50001
        nonmed = [b for b in beds if not b.medical]
        if nonmed and not any(prisoner(b) or not b.bed["baby"] for b in nonmed) and len(nonmed) >= 2:
            s["Nursery"] = 100200 * len(nonmed)
        g = sum(1 for b in beds if guest(b))
        if g and not any(prisoner(b) for b in beds):
            s["GuestRoom"] = 110000 * g
        if not beds:
            s["Classroom"] = 8 * sum(1 for t in things if t.has("classroom"))
            s["Playroom"] = 8 * sum(1 for t in things if t.has("playroom"))
        s["Laboratory"] = 60 * sum(1 for t in things if t.n and t.n["work_role"] and t.n["work_role"][0] == "Laboratory")
        s["Workshop"] = 27 * sum(1 for t in things if t.n and t.n["work_role"] and t.n["work_role"][0] == "Workshop")
        s["Kitchen"] = 28 * sum(1 for t in things if t.has("kitchen"))
        s["DiningRoom"] = 12 * sum(1 for t in things if t.has("eat"))
        s["RecRoom"] = 7 * sum(1 for t in things if t.has("joy"))
        s["Storeroom"] = 1 * sum(1 for t in things if t.has("storage"))
        s["Barn"] = 7.6 * sum(1 for t in things if t.bed and t.bed["animal"])
        caskets = sum(1 for t in things if t.bed and t.bed["deathrest"])
        bind = sum(1 for t in things if t.n and not t.bed and "deathrestcasket" in
                   json.dumps(t.n["facility_links"]).lower())          # CompDeathrestBindable
        s["DeathrestChamber"] = 100 * caskets + 50 * bind
        showers = sum(1 for t in things if t.n and t.n["hygiene"] == "wash" and t.n["thing_class"].endswith(
            ("Building_bath", "Building_Shower", "Building_PowerShower")))
        toilets = sum(1 for t in things if t.n and t.n["hygiene"] == "toilet")
        if showers or toilets >= 2:
            s["PublicBathroom"] = 30 * showers + toilets
        if any(t.raw.get("linked_bed") or t.raw.get("private") for t in things if t.n and t.n["hygiene"]) \
                and cls != "prison":
            s["PrivateBathroom"] = 4000
        best = max(s.items(), key=lambda kv: (kv[1], -ROLE_ORDER.index(kv[0]) if kv[0] in ROLE_ORDER else -99))
        return best[0], {k: v for k, v in s.items() if v}, notes

    def _is_bedroom(self, beds, r, notes):
        """RoomRoleWorker_Bedroom.IsBedroomHelper with planned owners: owned_bed marks an owned bed; the room's or the
        beds' 'couple' flag stands for one love cluster (R26)."""
        owned = [b for b in beds if b.owned]
        empty = [b for b in beds if not b.owned and not b.bed["baby"]]     # cribs: bed_emptyCountsForBarracks false
        if (len(empty) == 1 and not owned) or (not empty and len(owned) == 1):
            return True
        if empty:
            return False
        if not owned:
            return True
        adults = [b for b in owned if not b.bed["baby"]]
        if len(adults) <= 1:
            notes.append("owned cribs assumed to belong to the bed owners' children")
            return True
        return bool(r["meta"].get("couple")) or all(b.raw.get("couple") for b in adults)

    def check_roles(self):
        self.roles = {}
        for key, r in self.rooms.items():
            if not r["floor"] or r["outdoor"]:
                continue
            if len(r["floor"]) > 60 * 144:
                self.add("warn", 19, key, "more than 60 regions: a huge room gets no role and no stats")
            role, scores, notes = self.role_scores(r)
            self.roles[key] = (role, scores)
            exp = EXPECTED_ROLES.get(r["cls"])
            if exp and role not in exp:
                top = ", ".join(f"{k} {v:g}" for k, v in sorted(scores.items(), key=lambda kv: -kv[1])[:4])
                self.add("warn", 28 if role in ("Kitchen", "Workshop", "Laboratory") else 25, key,
                         f"room kind {r['kind']} expects {'/'.join(sorted(exp))} but the game gives {role} "
                         f"({ROLE_KO.get(role, role)}): {top}")
            things = r["items"]
            stoves = [t for t in things if t.has("kitchen") and t.n["work_role"]]
            shops = [t for t in things if t.n and t.n["work_role"] and t.n["work_role"][0] == "Workshop"]
            if stoves and shops:
                self.add("warn", 28, key, f"stoves and workshop benches share the room: {role} wins and the others "
                                          "work at 80%", [], [t.id for t in stoves + shops])
            if not r["psych_outdoors"]:
                for t in things:
                    if t.n and t.n["work_role"]:
                        want, factor = t.n["work_role"]
                        if factor < 1 and role != want:
                            self.add("warn", 70 if want != "Laboratory" else 67, key,
                                     f"{t.id}: {t.defname} needs a {want} room; here ({role}) it works at "
                                     f"x{factor:g}", t.cells, [t.id])

    # ------------------------------------------------------------------ stats (R32-R37, R113)

    def item_beauty(self, it):
        if it.raw.get("beauty") is not None:
            return float(it.raw["beauty"]), False
        if not it.n:
            return 0.0, True
        b = fl.beauty_of(it.n, it.stuff, it.quality)
        if it.n["thing_class"].endswith("Building_PlantGrower") and it.n["category"] == "decor":
            plant = it.raw.get("plant") or "Plant_Rose"
            b += PLANT_BEAUTY.get(plant, 14)
            return b, it.raw.get("plant") is None
        return b, False

    def item_value(self, it):
        if it.raw.get("value") is not None:
            return float(it.raw["value"]), False
        if not it.n:
            return 0.0, True
        return fl.market_value(it.n, it.stuff, it.quality)

    def wall_material(self, c):
        return (self.cell.get(c) or {}).get("mat")

    def compute_room_stats(self, r):
        cells = r["floor"]
        n = len(cells)
        guesses = set()
        if r["psych_outdoors"]:
            space = 350.0
        else:
            space = min(350.0, sum(1.4 if c in self.stand else (0.5 if c in self.walk else 0.0) for c in cells))
        counted = set()
        beauty = 0.0
        clean = 0.0
        wealth = 0.0
        things = list(r["items"]) + list(r["touch"])
        for c in cells:
            here = [it for it in self.items_at.get(c, ())]
            full = [it for it in here if it.edifice and it.fill > 0.99]
            if full:
                for it in full:
                    if it.id not in counted:
                        b, g = self.item_beauty(it)
                        beauty += b
                        counted.add(it.id)
                continue
            for it in here:
                if it.id in counted:
                    continue
                counted.add(it.id)
                b, g = self.item_beauty(it)
                beauty += b
                if g:
                    guesses.add(f"{it.defname}: plant pot counted with a grown rose (beauty 14)" if it.n
                                else f"{it.defname}: unknown def, beauty 0")
            name, tv, tg = self.floor_of(c)
            if tg:
                guesses.add(f"floor {name}: unknown, beauty/cleanliness 0")
            tb = tv[0]
            if tv[4] and r["psych_outdoors"]:
                tb = 0                      # natural terrain uses BeautyOutdoors 0 outdoors
            beauty += tb
            clean += tv[1]
            if self.faw and not name == "SmoothStone":
                pass
            else:
                wealth += tv[3]
        # things touching the room but standing outside it: in-wall items, walls and doors (R22)
        for it in things:                    # in-wall items (in the room's walls or touching it, R22)
            if it.id in counted or it.layer == "ceiling" and not set(it.cells) & cells:
                continue
            counted.add(it.id)
            b, _ = self.item_beauty(it)
            beauty += b
        for c in sorted(r["walls"]):
            if any(it.layer == "in_wall" and it.edifice for it in self.items_at.get(c, ())):
                continue
            mat = self.wall_material(c)
            if mat is None:
                guesses.add("wall material unknown: granite assumed")
                mat = "granite"
            d = fl.DOOR_DEF if c in self.doorc else fl.WALL_DEF
            beauty += fl.beauty_of(d, mat)
            v, g = fl.market_value(d, mat)
            wealth += v
        for it in things:
            v, g = self.item_value(it)
            wealth += v
            if g:
                guesses.add(f"{it.defname}: market value partly guessed")
            if it.n:
                clean += it.n["cleanliness"] or 0.0
        div = (20 + 0.5 * n) if n <= 40 else float(n)
        beauty_stat = beauty / div if n else 0.0
        clean_stat = clean / n if n else 0.0
        imp = impressiveness(wealth, beauty_stat, space, clean_stat)
        return {"cells": n, "wealth": round(wealth, 1), "beauty": round(beauty_stat, 2), "space": round(space, 1),
                "cleanliness": round(clean_stat, 3), "impressiveness": round(imp, 1), "stage": stage_name(imp),
                "beauty_sum": round(beauty, 1), "guesses": sorted(guesses)}

    def check_stats(self):
        for key, r in self.rooms.items():
            if not r["floor"] or r["outdoor"]:
                continue
            st = self.compute_room_stats(r)
            self.room_stats[key] = st
            if st["guesses"]:
                self.add("info", 34, key, "stats estimate: " + "; ".join(st["guesses"]))
            if r["cls"] in SLEEP_CLASSES | WORK_CLASSES | {"dining", "bathroom"} and st["cells"] <= 10 \
                    and r["cls"] not in ("power", "storage", "freezer"):
                self.add("warn", 37, key, f"{st['cells']} cells: an awake pawn here gets 'cramped interior' "
                                          "(-5; 3 or fewer cells -10)")
            if r["cls"] == "bedroom" and st["impressiveness"] < 30:
                self.add("warn", 40, key, f"bedroom impressiveness {st['impressiveness']} ({st['stage']}): sleeping "
                                          "here gives a bad or no mood")

    # ------------------------------------------------------------------ light (R45, R56-R58, R112)

    def check_light(self):
        self.light_level = {}
        for key, r in self.rooms.items():
            if not r["floor"] or r["outdoor"]:
                continue
            lamps = [it for it in list(r["items"]) + list(r["touch"]) if it.n and it.n["glow"]]
            contrib = collections.defaultdict(list)
            for lamp in lamps:
                g = lamp.n["glow"]
                field = fl.glow_at_cells(lamp.pos, g, lambda c: c in self.light or c not in self.cell)
                for c, (rgb, d) in field.items():
                    if c in r["floor"]:
                        contrib[c].append((rgb, d, g["overlight"]))
            level = {c: fl.combine_glow(contrib[c]) for c in r["floor"]}
            self.light_level[key] = level
            walk = [c for c in r["floor"] if c in self.walk]
            dark = sorted(c for c in walk if level[c] <= 0.3 and c not in self.unroofed)
            dark = [c for c in dark if c in r["roofed"]]
            if dark:
                sleep = r["cls"] in ("bedroom", "barracks", "guest", "prison")
                self.add("warn" if not sleep or len(dark) > len(walk) // 2 else "info", 45, key,
                         f"{len(dark)} of {len(walk)} walkable cells unlit (30% or less) by the room's own lamps"
                         + (" (sleepers do not mind; awake pawns get -5 and x0.8 speed)" if sleep else
                            ": -5 mood and x0.8 work and move speed"), dark)
            for it in r["items"]:
                if it.bed and it.medical:
                    lv = max(level.get(c, 0) for c in it.cells)
                    if lv < 0.5:
                        self.add("warn", 58, key, f"{it.id}: {int(lv * 100)}% light at the bed; surgery needs 50% "
                                                  "for full success", it.cells, [it.id])
                for ic in it.ics:
                    if ic in level and level[ic] <= 0.3 and it.n and it.n["work_role"]:
                        self.add("warn", 58, key, f"{it.id}: its worker cell {list(ic)} is dark (x0.8 work speed)",
                                 [ic], [it.id])
            if not lamps and r["roofed"] and r["cls"] not in ("power", "storage", "freezer"):
                self.add("warn", 56, key, "no lamp in the room (lamps in other rooms do not count: doors block light "
                                          "and LightsOut switches off empty rooms)")

    # ------------------------------------------------------------------ roof (R54)

    def check_roof(self):
        roofed = set()
        for r in self.rooms.values():
            roofed |= r["roofed"]
        roofed |= {c for c in self.doorc}
        r2 = 6.9 * 6.9
        for key, r in self.rooms.items():
            bad = []
            for c in sorted(r["roofed"]):
                if not self._roof_held(c, roofed, r2):
                    bad.append(c)
            if bad:
                self.add("error", 54, key, f"{len(bad)} roofed cell(s) more than 6.9 from a wall, door or column: the "
                                           "roof collapses there (add a column)", bad)

    def _roof_held(self, c, roofed, r2):
        """RoofCollapseUtility.WithinRangeOfRoofHolder: flood through roofed cells within 6.9 of c; a holdsRoof
        edifice on a visited cell or next to it (cardinal), itself within 6.9 of c, holds the roof."""
        seen = {c}
        dq = collections.deque([c])
        while dq:
            x = dq.popleft()
            for dx, dy in ((0, 0),) + N4:
                h = (x[0] + dx, x[1] + dy)
                if h in self.holder and (h[0] - c[0]) ** 2 + (h[1] - c[1]) ** 2 <= r2:
                    return True
            for dx, dy in N4:
                n = (x[0] + dx, x[1] + dy)
                if n not in seen and n in roofed and (n[0] - c[0]) ** 2 + (n[1] - c[1]) ** 2 <= r2:
                    seen.add(n)
                    dq.append(n)
        return False

    # ------------------------------------------------------------------ temperature (R59-R64, R111), warnings only

    def check_temperature(self):
        for key, r in self.rooms.items():
            if not r["floor"] or r["outdoor"]:
                continue
            things = list(r["items"]) + list(r["touch"])
            heat = [t for t in things if t.has("heat")]
            cool = [t for t in things if t.has("cool") and (t.layer != "in_wall" or self._cools(t, r))]
            vents = [t for t in things if t.has("vent")]
            cls = r["cls"]
            if r["outdoor_temp"]:
                self.add("warn", 21, key, "25% or more of the room is unroofed: it uses the outdoor temperature")
                continue
            if cls == "freezer":
                if not cool:
                    self.add("warn", 63, key, "freezer without a cooler or walk-in freezer unit cooling it")
                for d in r["doors"]:
                    other = {self.cell_room.get((d[0] + dx, d[1] + dy)) for dx, dy in N4} - {key, None}
                    lock = any((d[0] + 2 * dx, d[1] + 2 * dy) in self.doorc for dx, dy in N4)
                    if other and not lock:
                        self.add("warn", 63, key, f"door {list(d)} opens straight into {', '.join(map(str, other))}: "
                                                  "an airlock (door, free cell, door) keeps the cold in", [d])
            elif cls in SLEEP_CLASSES | {"kitchen", "workshop", "lab", "dining", "school", "library", "bathroom"}:
                if not heat and not vents:
                    self.add("warn", 60 if cls in SLEEP_CLASSES else 64, key,
                             "no heater, radiator or vent: the room follows the walls in winter "
                             + ("('slept in the cold' -4)" if cls in SLEEP_CLASSES else "(benches x0.7 below 9 C)"))
                if not cool and not vents and cls not in ("bathroom",):
                    self.add("info", 59, key, "no cooler, air-con unit, ceiling fan or vent for summer")
            pushers = [t for t in things if t.n and t.n["thing_class"].endswith("HeatPush")]
            if pushers and not cool and not vents and cls not in ("freezer",):
                self.add("info", 64, key, f"{len(pushers)} heat-pushing bench(es) and no cooling: keep it below 35 C",
                         [], [t.id for t in pushers])
            for t in things:
                if t.n and t.n["thing_class"].endswith("Building_Cooler") and hasattr(t, "hot"):
                    hr = self.cell_room.get(t.hot)
                    if hr is not None and not self.rooms[hr]["outdoor_temp"]:
                        self.add("warn", 59, key, f"{t.id}: hot side blows into room {hr}, which does not use "
                                                  "the outdoor temperature: vent it outdoors", [t.hot], [t.id])

    def _cools(self, t, r):
        """An in-wall cooler cools the room on its cold side (P + South rotated); a freezer unit its -Z side."""
        if t.defname == "FreezerUnit":
            v = fl.FACING[(t.rot + 2) % 4]
            return any((c[0] + v[0], c[1] + v[1]) in r["floor"] for c in t.cells)
        if hasattr(t, "cold"):
            return t.cold in r["floor"]
        return True

    # ------------------------------------------------------------------ Dubs Bad Hygiene Lite (R110)

    def check_hygiene(self):
        toilets = [it for it in self.items if it.n and it.n["hygiene"] == "toilet"]
        wash = [it for it in self.items if it.n and it.n["hygiene"] == "wash"]
        want = [k for k, r in self.rooms.items() if r["cls"] in ("bedroom", "barracks", "guest", "kitchen",
                                                                 "workshop", "lab", "butcher", "hospital", "mech")]
        if not want:
            return
        if not toilets:
            self.add("warn", 110, None, "no toilet in the plan: Dubs Bad Hygiene Lite pawns need one (bladder)")
        if not wash:
            self.add("warn", 110, None, "no basin, shower or bath in the plan (hygiene need)")
        fields = {}
        for name, fx in (("toilet", toilets), ("wash", wash)):
            if fx:
                src = set()
                for it in fx:
                    src.update(it.ics or it.cells)
                fields[name] = self.dijkstra(src, cells_metric=True)
        for key in want:
            r = self.rooms[key]
            starts = set(r["doors"]) or set(r["floor"])
            for name, dist in fields.items():
                d = min((dist.get(c, INF) for c in starts), default=INF)
                if d > self.hygiene_max:
                    txt = "unreachable" if d == INF else f"{d:.0f} cells"
                    self.add("warn", 110, key, f"nearest {name} is {txt} from the door (limit {self.hygiene_max:g})",
                             sorted(starts)[:4])
                self.room_stats.setdefault(key, {})[f"walk_to_{name}"] = None if d == INF else round(d, 1)

    # ------------------------------------------------------------------ power (R91, R112), warnings only

    def check_power(self):
        phases = sorted({it.phase for it in self.items})
        self.power = []
        for p in phases:
            use = sum(it.n["power_w"] for it in self.items if it.phase <= p and it.n and (it.n["power_w"] or 0) > 0)
            make = -sum(it.n["power_w"] for it in self.items if it.phase <= p and it.n and (it.n["power_w"] or 0) < 0)
            bat = sum(it.n["battery_wd"] or 0 for it in self.items if it.phase <= p and it.n)
            self.power.append({"phase": p, "use_w": round(use), "make_w": round(make), "battery_wd": round(bat)})
            if use > make:
                self.add("warn", 91, None, f"phase {p}: furniture draws {use:.0f} W, generators in the plan give "
                                           f"{make:.0f} W, batteries {bat:.0f} Wd (LightsOut lowers the draw; "
                                           "solar is 0 at night)")

    # ------------------------------------------------------------------ report

    def report(self, room=None):
        rooms = {}
        keys = [room] if room else list(self.rooms)
        for key in keys:
            if key not in self.rooms:
                continue
            r = self.rooms[key]
            role = self.roles.get(key) if hasattr(self, "roles") else None
            rooms[key] = {"kind": r["kind"], "name": r["meta"].get("name"), "cells": len(r["floor"]),
                          "role": role[0] if role else None, "role_ko": ROLE_KO.get(role[0]) if role else None,
                          "scores": role[1] if role else {}, "stats": self.room_stats.get(key, {}),
                          "items": len(r["items"]),
                          "lit": self._lit_summary(key),
                          "findings": [f for f in self.findings if f["room"] == key]}
        glob = [f for f in self.findings if f["room"] is None or f["room"] not in self.rooms]
        if room:
            glob = []
        sel = [f for v in rooms.values() for f in v["findings"]] + glob
        counts = collections.Counter(f["level"] for f in sel)
        return {"plan_phase": self.phase, "rooms": rooms, "global": glob, "power": getattr(self, "power", []),
                "counts": {k: counts.get(k, 0) for k in ("error", "warn", "info")}, "notes": self.notes}

    def _lit_summary(self, key):
        lv = getattr(self, "light_level", {}).get(key)
        r = self.rooms[key]
        if not lv:
            return None
        walk = [c for c in r["floor"] if c in self.walk and c in r["roofed"]]
        return {"lit": sum(1 for c in walk if lv[c] > 0.3), "walkable": len(walk)}


def fmt_cells(cells, n=6):
    s = " ".join(f"({c[0]},{c[1]})" for c in cells[:n])
    return s + (f" +{len(cells) - n}" if len(cells) > n else "")


def text_report(rep, plan_path, cat, rules_status, show_info=False):
    out = []
    c = rep["counts"]
    out.append(f"validate_plan {os.path.basename(plan_path)}: phase {rep['plan_phase']}, catalog {len(cat)} defs "
               f"({len(cat.duplicates)} duplicates kept by the verified rule), rules "
               + (f"{rules_status['checked']} cited ids checked" if rules_status["loaded"] else "not found")
               + (f", MOVED {rules_status['moved']}" if rules_status["moved"] else "")
               + (f", MISSING {rules_status['missing']}" if rules_status["missing"] else ""))
    tag = {"error": "ERROR", "warn": "WARN ", "info": "info "}
    for key, r in rep["rooms"].items():
        st = r["stats"] or {}
        head = f"== {key} ({r['kind']}{', ' + r['name'] if r.get('name') else ''}) {r['cells']} cells, {r['items']} items"
        if r["role"]:
            head += f" | role {r['role']} {r['role_ko']} ({r['scores'].get(r['role'], 0):g})"
        if "impressiveness" in st:
            head += (f" | impressiveness {st['impressiveness']} {st['stage']} (wealth {st['wealth']:.0f}, beauty "
                     f"{st['beauty']}, space {st['space']}, clean {st['cleanliness']})")
        if r.get("lit"):
            head += f" | lit {r['lit']['lit']}/{r['lit']['walkable']}"
        for k in ("walk_to_toilet", "walk_to_wash"):
            if k in st:
                head += f" | {k.split('_')[-1]} {st[k] if st[k] is not None else '-'}"
        out.append(head)
        for f in r["findings"]:
            if f["level"] == "info" and not show_info:
                continue
            cells = f" {fmt_cells(f['cells'])}" if f["cells"] else ""
            out.append(f"  {tag[f['level']]} [{f['rule']} {f['topic']}] {f['msg']}{cells}")
    if rep["global"]:
        out.append("== plan")
        for f in rep["global"]:
            if f["level"] == "info" and not show_info:
                continue
            out.append(f"  {tag[f['level']]} [{f['rule']} {f['topic']}] {f['msg']}")
    if rep["power"]:
        out.append("== power by phase: " + "; ".join(f"{p['phase']}: {p['use_w']} W use / {p['make_w']} W made / "
                                                     f"{p['battery_wd']} Wd" for p in rep["power"]))
    hidden = sum(1 for v in rep["rooms"].values() for f in v["findings"] if f["level"] == "info") \
        + sum(1 for f in rep["global"] if f["level"] == "info")
    out.append(f"== {c['error']} errors, {c['warn']} warnings, {c['info']} notes"
               + ("" if show_info or not hidden else " (notes hidden; --all-info shows them)"))
    return "\n".join(out)


def parse_args(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("plan")
    ap.add_argument("--room", help="report only this room key")
    ap.add_argument("--json", help="write the full report as JSON")
    ap.add_argument("--catalog", help="catalog directory or comma-separated files (default: FURNISH_CATALOG_DIR)")
    ap.add_argument("--rules", default=fl.RULES_PATH, help="rules.json for the citation check")
    ap.add_argument("--phase", type=int, help="validate the plan as built up to this phase (default: all)")
    ap.add_argument("--hygiene-max", type=float, default=40.0,
                    help="warn when the nearest toilet or wash fixture is farther than this many cells (default 40)")
    ap.add_argument("--vanilla-floors", action="store_true",
                    help="count floor wealth as in vanilla (default: Floors Are Worthless, floors 0, smooth stone 5)")
    ap.add_argument("--all-info", action="store_true", help="print the notes (info lines) too")
    return ap.parse_args(argv)


def catalog_paths(arg):
    if not arg:
        return fl.default_catalog_paths()
    if os.path.isdir(arg):
        return fl.default_catalog_paths(arg)
    return [p for p in arg.split(",") if p]


def main(argv):
    args = parse_args(argv)
    with open(args.plan, encoding="utf-8") as fh:
        plan = json.load(fh)
    cat = fl.load_catalog(catalog_paths(args.catalog))
    rules, rule_map, rstatus = load_rules(args.rules)
    v = Validator(plan, cat, rules, rule_map, phase=args.phase, hygiene_max=args.hygiene_max,
                  faw=not args.vanilla_floors).run()
    rep = v.report(args.room)
    rep["rules"] = rstatus
    rep["catalog"] = {"files": cat.files, "defs": len(cat), "duplicates": cat.duplicates}
    print(text_report(rep, args.plan, cat, rstatus, args.all_info))
    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(rep, fh, ensure_ascii=False, indent=1)
    return 1 if rep["counts"]["error"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
