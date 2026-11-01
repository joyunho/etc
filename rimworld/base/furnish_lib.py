"""Furniture library for the furnished base plan (RimWorld 1.6 code, played on 1.7 beta with Biotech, Odyssey and mods).

Designers place furniture with this module and check rooms with validate_plan.py. It reads the verified catalogs
(one JSON object per buildable def) and turns a def, a position cell and a rotation into the plan's furniture item.

Coordinates. The plan's x grows east and y grows SOUTH (screen order). RimWorld's x grows east and z grows NORTH, so
plan y = -z. Rotations are RimWorld's Rot4: 0 N, 1 E, 2 S, 3 W. Every rule below is done in game coordinates and only
then turned into plan cells, so the game's code can be read line by line next to this file:

  GenAdj.OccupiedRect / AdjustForRotation   Verse/GenAdj.cs:606-754 (decompiled 1.6, commit 9c11094)
  ThingUtility.InteractionCell(sWhenAt)      Verse/ThingUtility.cs:55-80
  IntVec3Utility.RotatedBy                   Verse/IntVec3Utility.cs:36-46
  BedUtility.GetSlotPos                      RimWorld/BedUtility.cs:13-30
  GenThing.TrueCenter                        RimWorld/GenThing.cs (centre of the occupied rect)
  WatchBuildingUtility.GetWatchCellRect      RimWorld/WatchBuildingUtility.cs

Rule ids such as R0 are positions in rules.json (0-based): R0 = rules.json[0], the footprint rule.

Pure standard library. sim_raids.py (same folder) is read for its verified door, fence, trap and turret table so the
items written here mean the same thing to the raid simulator; nothing in sim_raids.py is changed.
"""
import importlib.util
import json
import math
import os
import re
import struct

HERE = os.path.dirname(os.path.abspath(__file__))
FURNISH_DIR = os.environ.get(
    "FURNISH_DIR", "/tmp/claude-0/-home-user-etc/c4cad7b4-88bc-5bae-b1ad-14d8f551754a/scratchpad/furnish")
CATALOG_FILES = ("core.json", "dlc.json", "vfe.json", "storage_dubs_misc.json", "ve_content.json", "other_mods.json")
CATALOG_DIR = os.environ.get("FURNISH_CATALOG_DIR") or os.path.join(FURNISH_DIR, "catalog")
RULES_PATH = os.environ.get("FURNISH_RULES") or os.path.join(FURNISH_DIR, "rules.json")

ROTS = ("N", "E", "S", "W")
# Rot4.FacingCell in plan coordinates (game N = +z = plan -y)
FACING = {0: (0, -1), 1: (1, 0), 2: (0, 1), 3: (-1, 0)}
ROT_WORDS = {"n": 0, "north": 0, "e": 1, "east": 1, "s": 2, "south": 2, "w": 3, "west": 3}


def default_catalog_paths(directory=None):
    d = directory or CATALOG_DIR
    return [os.path.join(d, f) for f in CATALOG_FILES]


def rot_index(rot):
    """0..3 from 0..3, 'N'/'E'/'S'/'W' or 'North'...; None means North."""
    if rot is None:
        return 0
    if isinstance(rot, str):
        key = rot.strip().lower()
        if key in ROT_WORDS:
            return ROT_WORDS[key]
        if key.isdigit():
            return int(key) % 4
        raise ValueError(f"unknown rotation {rot!r}")
    return int(rot) % 4


def rot_name(rot):
    return ROTS[rot_index(rot)]


def f32(v):
    """Round to a C# float (single precision)."""
    return struct.unpack("f", struct.pack("f", v))[0]


# ------------------------------------------------------------------------------------------------ sim_raids link

_SIM = []


def sim_raids():
    """The raid simulator module (read only), or None when it is not next to this file."""
    if not _SIM:
        path = os.path.join(HERE, "sim_raids.py")
        mod = None
        if os.path.exists(path):
            spec = importlib.util.spec_from_file_location("sim_raids", path)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
        _SIM.append(mod)
    return _SIM[0]


# ------------------------------------------------------------------------------------------------ catalog

class Catalog(dict):
    """defName -> catalog entry. .duplicates lists defs found in more than one file, .skipped the entries without a
    defName (mod notes, frameworks), .files the files read."""

    def __init__(self):
        super().__init__()
        self.duplicates = []
        self.skipped = []
        self.files = []

    def get_def(self, name):
        d = self.get(name)
        if d is None:
            raise KeyError(f"{name!r} is not in the catalog ({len(self)} defs from {len(self.files)} files)")
        return d


def load_catalog(paths=None):
    """Read catalog files in order. A def met again in a later file replaces the earlier entry only if the earlier
    one is not verified; every such meeting is reported in .duplicates as a dict {def, kept, other, replaced}."""
    cat = Catalog()
    for path in (paths or default_catalog_paths()):
        with open(path, encoding="utf-8") as fh:
            rows = json.load(fh)
        cat.files.append(path)
        base = os.path.basename(path)
        for e in rows:
            name = e.get("defName")
            if not name:
                cat.skipped.append({"file": base, "label": e.get("label_en"), "source": e.get("source")})
                continue
            e = dict(e)
            e["_file"] = base
            old = cat.get(name)
            if old is None:
                cat[name] = e
                continue
            replace = not old.get("verified")
            cat.duplicates.append({"def": name, "kept": base if replace else old["_file"],
                                   "other": old["_file"] if replace else base, "replaced": replace,
                                   "sources": [old.get("source"), e.get("source")]})
            if replace:
                cat[name] = e
    return cat


# ------------------------------------------------------------------------------------------------ normalised def

# Glow colours (CompGlower glowColor) of the lamps the designers use. Only the colour's channels matter for light
# reach; a lamp missing here is assumed to have the standard lamp colour (214,148,94) and the guess is reported.
GLOW_RGB = {
    "StandingLamp": (214, 148, 94), "WallLamp": (214, 148, 94), "FloodLight": (214, 148, 94),   # Buildings_Furniture
    "TorchLamp": (184, 136, 83), "TorchWallLamp": (184, 136, 83), "SunLamp": (370, 370, 370),
    "Campfire": (252, 187, 113), "Heater": (255, 150, 100),                                     # Buildings_Temperature
    "TableMachining": (73, 123, 138), "ElectricSmelter": (217, 112, 33), "ElectricCrematorium": (217, 112, 33),
    "WoodFiredGenerator": (217, 112, 33), "ChemfuelPoweredGenerator": (80, 112, 180),
    "VanometricPowerCell": (227, 233, 168),
    # mods (their 1.6/1.7 XML)
    "VFE_DeskLamp": (214, 148, 94), "VFE_FloorLamp": (214, 148, 94), "Light_Streetlamp": (214, 148, 94),
    "VFE_RoyalLamp": (214, 148, 94), "Spacer_OutdoorLamp": (214, 148, 94), "Table_IlluminatedEndTable": (214, 148, 94),
    "Table_IlluminatedDresser": (214, 148, 94), "VFES_Table_IlluminatedWardrobe": (214, 148, 94),
    "Stone_Campfire": (252, 187, 113), "CeilingFan": (214, 148, 94), "CeilingFanS": (214, 148, 94),
    "RB_FloorLamp": (214, 148, 94), "RB_Fireplace": (255, 140, 43), "RB_OverwallFireplace": (255, 140, 43),
    "LogBoiler": (217, 112, 33), "Chemlamp": (252, 187, 113), "ChemlampPost": (252, 187, 113),
    "VQEA_AncientSunLamp": (370, 370, 370), "GR_BioLight": (211, 231, 209), "GR_SmallBioLight": (211, 231, 209),
    "VCE_Grill": (244, 112, 42), "ChemBoiler": (255, 50, 25),
}
STANDARD_GLOW = (214, 148, 94)

# Doors, fences, traps and turrets: sim_raids.DEF_ROLES / CLASS_ROLES are the verified source. These are only for
# thing classes the raid table does not list.
DOOR_CLASS_WORDS = ("Building_Door", "Building_MultiTileDoor", "Building_SupportedDoor", "Building_DoorSingle")
NOT_EDIFICE_EXTRA = {"OxygenPump"}       # Biotech/Odyssey wall attachment (dlc.json: isEdifice false)

# Watch buildings: (min distance, max distance, rect width), WatchBuildingUtility (Core/Biotech XML values, R72, R73)
WATCH_VANILLA = {"TubeTelevision": (2, 4, 5), "FlatscreenTelevision": (2, 6, 6), "MegascreenTelevision": (2, 7, 7),
                 "HorseshoesPin": (5, 5, 3), "HoopstoneRing": (5, 5, 3)}
TOILET_CLASSES = ("Building_toilet", "Building_AdvToilet", "Building_Latrine")
WASH_CLASSES = ("Building_basin", "Building_washbucket", "Building_bath", "Building_Shower", "Building_PowerShower")
KITCHEN_DEFS = {"ElectricStove", "FueledStove", "TableButcher", "ButcherSpot"}           # R25, R30
CLASSROOM_DEFS = {"SchoolDesk", "Blackboard"}                                            # RoomRoleWorker_Classroom
PLAYROOM_DEFS = {"ToyBox", "BabyDecoration"}                                             # BabyPlayGainFactor > 1
BABY_BEDS = {"Crib", "BabySleepingSpot"}                                                 # bed_maxBodySize 0.25


def _b(v):
    if isinstance(v, str):
        return v.strip().lower() in ("1", "true", "yes")
    return bool(v)


def _num(v, default=None):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def _parse_cost(entry, ex):
    """cost_list {thing: n} and cost_stuff_count from the catalog (dlc.json writes it as a string)."""
    cost = dict(ex.get("cost_list") or {})
    stuff = int(ex.get("cost_stuff_count") or 0)
    s = entry.get("cost")
    if isinstance(s, str) and not cost and not stuff:
        m = re.search(r"(\d+)\s*stuff", s)
        if m:
            stuff = int(m.group(1))
        for name, n in re.findall(r"([A-Z][A-Za-z_]+)\s+(\d+)", s):
            cost[name] = int(n)
    return cost, stuff


def _parse_watch(entry):
    name = entry.get("defName")
    if name in WATCH_VANILLA:
        a, b, w = WATCH_VANILLA[name]
        return {"min": a, "max": b, "width": w}
    pr = entry.get("placement_rules") or ""
    m = re.search(r"distance\s+(-?\d+)\s*~\s*(-?\d+)\s+cells.*?strip\s+(\d+)\s+wide", pr)
    if m:
        return {"min": int(m.group(1)), "max": int(m.group(2)), "width": int(m.group(3))}
    m = re.search(r"stand/sit\s+(\d+)-(\d+)\s+cells away.*?(\d+)-wide strip", pr)
    if m:
        return {"min": int(m.group(1)), "max": int(m.group(2)), "width": int(m.group(3))}
    m = re.search(r"exactly\s+(\d+)\s+cells away.*?(\d+)-wide strip", pr)
    if m:
        return {"min": int(m.group(1)), "max": int(m.group(1)), "width": int(m.group(2))}
    m = re.search(r"watchBuildingStandDistanceRange\s+(\d+),\s*width\s+(\d+)", pr)
    if m:
        return {"min": int(m.group(1)), "max": int(m.group(1)), "width": int(m.group(2))}
    return None


def _parse_work_role(entry, ex):
    """(role, factor elsewhere) of building.workTableRoomRole, or None (R70)."""
    w = ex.get("work_table_room_role")
    if isinstance(w, dict) and w.get("role"):
        return (w["role"], float(w.get("factor_elsewhere") or 1.0))
    if isinstance(w, str) and w:
        return (w, 0.8)
    rr = entry.get("room_role") or ""
    m = re.search(r"needs a (Workshop|Kitchen|Laboratory)", rr)
    if m:
        f = re.search(r"x(0\.\d+)", rr)
        return (m.group(1), float(f.group(1)) if f else 0.8)
    m = re.search(r"(Workshop|Kitchen|Laboratory) work table([^;]*)", rr)
    if m:
        if "no speed penalty" in m.group(2):
            return (m.group(1), 1.0)
        f = re.search(r"x(0\.\d+)", m.group(2))
        return (m.group(1), float(f.group(1)) if f else 0.8)
    m = re.search(r"workTableRoomRole[ =]*(Laboratory|Workshop|Kitchen)", rr)
    if m:
        f = re.search(r"workTableNotInRoomRoleFactor\s*(0\.\d+)", rr)
        return (m.group(1), float(f.group(1)) if f else 1.0)
    m = re.search(r"Laboratory \([^)]*\)[^;]*(?:\+60|adds 60|60 to)", rr) or re.search(r"\(x(0\.\d+) speed outside a (\w+)\)", rr)
    if m:
        if m.lastindex == 2:
            return (m.group(2), float(m.group(1)))
        return ("Laboratory", 1.0)
    return None


def info(d):
    """Normalised view of one catalog entry, cached in the entry. Every value comes from the catalog; anything that had
    to be assumed is listed in info['guesses']."""
    if d is None:
        return None
    if "_info" in d:
        return d["_info"]
    ex = d.get("extra") if isinstance(d.get("extra"), dict) else {}
    name = d.get("defName") or "?"
    guesses = []
    size = d.get("size")
    if not size:
        size = [1, 1]
        guesses.append("size unknown: 1x1 assumed")
    rotatable = d.get("rotatable")
    if rotatable is None:
        rotatable = True                  # ThingDef.rotatable defaults to true (R2)
    dpr = ex.get("default_placing_rot", d.get("default_placing_rot"))
    default_rot = rot_index(dpr) if dpr else 0    # BuildableDef.defaultPlacingRot defaults to North (R2)
    pw = list(d.get("place_workers") or [])
    pwl = " ".join(pw).lower()
    rules = (d.get("placement_rules") or "")
    rl = rules.lower()
    rr = d.get("room_role") or ""
    tc = ex.get("thing_class") or d.get("thing_class") or ""
    cat = d.get("category") or ""
    pas = d.get("passability") or "Standable"
    fill = d.get("fill_percent")
    if fill is None:
        fill = 1.0 if pas == "Impassable" else 0.0
        guesses.append(f"fill unknown: {fill} assumed")
    os_ = ex.get("other_stats") if isinstance(ex.get("other_stats"), dict) else {}
    hp = os_.get("MaxHitPoints", ex.get("max_hit_points", d.get("max_hit_points")))
    cost, stuff_count = _parse_cost(d, ex)
    work = _num(ex.get("work_to_build", d.get("work_to_build")), 0.0) or 0.0
    work = max(work, _num(ex.get("work_to_make"), 0.0) or 0.0)
    glow = None
    g = ex.get("glow")
    radius = None
    overlight = 0.0
    if isinstance(g, dict) and g.get("radius"):
        radius, overlight = float(g["radius"]), float(g.get("overlight_radius") or 0)
    elif _num(ex.get("glow_radius")):
        radius = float(ex["glow_radius"])
    if radius:
        rgb = GLOW_RGB.get(name)
        if rgb is None:
            rgb = STANDARD_GLOW
            guesses.append("glow colour not in GLOW_RGB: standard lamp colour (214,148,94) assumed")
        glow = {"radius": radius, "overlight": overlight, "rgb": rgb}
    sr = sim_raids()
    role_row = sr.DEF_ROLES.get(name) if sr else None
    short_tc = tc.split(".", 1)[1] if tc.startswith(("RimWorld.", "Verse.")) else tc
    sim_role = role_row[0] if role_row else (sr.CLASS_ROLES.get(short_tc) if sr else None)
    if sim_role is None and any(w in tc for w in DOOR_CLASS_WORDS):
        sim_role = "door"
    attach = "attachedtowall" in pwl or bool(d.get("wall_attachment"))
    explicit_edifice = ex.get("is_edifice")
    if explicit_edifice is not None:
        edifice = _b(explicit_edifice)
    else:
        not_edifice = set(sr.NOT_EDIFICE) if sr else set()
        edifice = not (name in not_edifice or name in NOT_EDIFICE_EXTRA or attach
                       or name.lower().endswith(("conduit", "pipe", "pipehidden")))
    alt = ex.get("altitude_layer") or ""
    in_wall = bool(re.search(r"over an existing wall|goes in (?:a|the) wall line|built into", rl)) or "onwall" in pwl \
        or sim_role in ("door", "free", "wall")
    if attach:
        layer = "wall_attach"
    elif alt == "Weather":
        layer = "ceiling"
    elif in_wall:
        layer = "in_wall"
    elif not edifice:
        layer = "floor_deco"
    else:
        layer = "edifice"
    holds_roof = _b(ex.get("holds_roof")) if ex.get("holds_roof") not in (None, "unchanged (each wall cell holds roof)") \
        else ("holds up roof" in rl or name == "Column" or sim_role in ("door", "free"))
    if ex.get("block_light") is not None:
        block_light = _b(ex.get("block_light"))
    else:
        block_light = name in ("Cooler", "Vent") or sim_role in ("door", "free") \
            or (layer == "in_wall" and pas == "Impassable" and (fill or 0) > 0.99)
    is_bed = ("Building_Bed" in tc or tc.endswith("Bed") or tc.endswith("AndroidStand")) \
        or (not tc and cat == "bed") or name in BABY_BEDS
    deathrest = name == "DeathrestCasket" or "Deathrest chamber (casket" in rr
    bed = None
    if is_bed:
        b_extra = ex.get("bed") if isinstance(ex.get("bed"), dict) else {}
        animal = cat == "animal" or "Barn" in rr
        baby = name in BABY_BEDS or "baby bed" in rr.lower() or "Nursery (counts" in rr
        slots = int(b_extra.get("sleeping_slots") or size[0])          # BedUtility.GetSleepingSlotsCount = size.x
        medical = bool(b_extra.get("medical_by_default")) or name == "HospitalBed" \
            or "medical by default" in rr.lower()
        bed = {"slots": slots, "humanlike": not animal, "baby": baby, "animal": animal,
               "medical_default": medical, "counts_for_bedroom": not deathrest, "deathrest": deathrest,
               "hospital_bed": name == "HospitalBed" or "VitalsMonitor" in json.dumps(d.get("facility_links") or [])}
    work_role = _parse_work_role(d, ex)
    kitchen = name in KITCHEN_DEFS or bool(re.search(r"Kitchen[^;.]*\+28", rr))
    eat = (ex.get("surface_type") == "Eat") or "Dining room" in rr
    joy = bool(ex.get("joy_kind")) or bool(re.search(r"Rec room[^;]*\+\d", rr))     # RoomRoleWorker_RecRoom
    # RoomRoleWorker_StoreRoom counts Building_Storage; Building_Bookcase is not one (Building_Bookcase.cs:8)
    storage = tc.endswith("Building_Storage") or ("Storeroom" in rr and not tc.endswith("Building_Bookcase"))
    hauled_to = storage or tc.endswith("Building_Bookcase")
    sittable = cat == "seat" or "sittable" in rl or bool(ex.get("sittable"))
    hygiene = None
    if any(tc.endswith(c) for c in TOILET_CLASSES):
        hygiene = "toilet"
    elif any(tc.endswith(c) for c in WASH_CLASSES):
        hygiene = "wash"
    temp = ex.get("temp_control") if isinstance(ex.get("temp_control"), dict) else {}
    eps = _num(temp.get("energy_per_second"), None)
    if eps is None:
        eps = _num(ex.get("energy_per_second"), None)
    if eps is None and isinstance(ex.get("radiator"), dict):
        eps = _num(ex["radiator"].get("energy_per_second"), None)
    heat = ("placeworker_heater" in pwl and name not in ("CoolingRadiator",)) or (eps is not None and eps > 0) \
        or tc.endswith("Building_Heater")
    cool = tc.endswith("Building_Cooler") or (eps is not None and eps < 0) or "placeworker_coolersimple" in pwl
    vent = tc.endswith("Building_Vent") or "placeworker_vent" in pwl
    bat = ex.get("battery") if isinstance(ex.get("battery"), dict) else {}
    fac = d.get("facility_links") or []
    watch = _parse_watch(d) if (ex.get("joy_kind") in ("Television",) or name in WATCH_VANILLA
                                or "watch" in rl or "stand/sit" in rl) else None
    ic = []
    mic = d.get("multiple_interaction_cell_offsets")
    if mic:
        ic = [tuple(int(v) for v in o[:2]) for o in mic]
    elif d.get("interaction_cell_offset"):
        ic = [tuple(int(v) for v in d["interaction_cell_offset"][:2])]
    elif d.get("has_interaction_cell"):
        ic = [(0, -1)]
        guesses.append("has an interaction cell but no offset in the catalog: (0,-1) assumed")
    if hp is None:
        guesses.append("MaxHitPoints not in the catalog")
    out = {
        "name": name, "label_en": d.get("label_en"), "label_ko": d.get("label_ko"), "source": d.get("source"),
        "category": cat, "size": (int(size[0]), int(size[1])), "rotatable": bool(rotatable),
        "default_rot": default_rot, "passability": pas, "fill": float(fill), "path_cost": int(d.get("path_cost") or 0),
        "hp": int(hp) if hp is not None else None, "power_w": _num(d.get("power_w")),
        "beauty": _num(d.get("beauty"), 0.0), "comfort": _num(d.get("comfort"), 0.0),
        "cleanliness": _num(d.get("cleanliness"), 0.0), "ic": ic, "place_workers": pw, "thing_class": tc,
        "cost": cost, "stuff_count": stuff_count, "stuff_categories": list(ex.get("stuff_categories") or []),
        "work": work, "market_value": _num(os_.get("MarketValue")), "glow": glow, "edifice": edifice, "layer": layer,
        "holds_roof": bool(holds_roof), "block_light": bool(block_light), "sim_role": sim_role, "role_row": role_row,
        "bed": bed, "deathrest": deathrest, "work_role": work_role, "kitchen": kitchen, "eat": eat, "joy": joy,
        "storage": storage, "hauled_to": hauled_to, "sittable": sittable, "hygiene": hygiene, "heat": heat, "cool": cool, "vent": vent,
        "battery_wd": _num(bat.get("stored_energy_max_wd")), "facility_links": fac, "watch": watch,
        "prevent_ic_overlap": "preventinteractionspotoverlap" in pwl,
        "requires_chair": "need a chair" in rl, "billiards": name == "BilliardsTable" or "ring around it must hold" in rl,
        "playroom": name in PLAYROOM_DEFS or "Playroom" in rr, "classroom": name in CLASSROOM_DEFS,
        "verified": bool(d.get("verified")), "file": d.get("_file"), "guesses": guesses,
        "room_role_text": rr,
    }
    d["_info"] = out
    return out


def _as_info(d):
    """Accept a catalog entry, an info() dict, or a bare (sx, sz) size."""
    if isinstance(d, (tuple, list)):
        return {"name": f"{d[0]}x{d[1]}", "size": (int(d[0]), int(d[1])), "rotatable": True, "default_rot": 0,
                "ic": [], "bed": None}
    if "name" in d and "default_rot" in d:
        return d
    return info(d)


# ------------------------------------------------------------------------------------------------ geometry

# GenAdj.AdjustForRotation(ref center, ref size, Rot4.North, rot): the switch for reference North (GenAdj.cs:654-668)
ROT_SHIFT = {0: (0, 0), 1: (0, -1), 2: (-1, -1), 3: (-1, 0)}


def to_game(cell):
    return (cell[0], -cell[1])


def to_plan(cell):
    return (cell[0], -cell[1])


def effective_rot(d, rot):
    """The rotation the game uses: a non-rotatable def is always placed at its defaultPlacingRot (R2)."""
    n = _as_info(d)
    return n["default_rot"] if not n["rotatable"] else rot_index(rot)


def occupied_rect_game(center, rot, size):
    """GenAdj.OccupiedRect(center, rot, size) in game coordinates: (minX, minZ, maxX, maxZ)."""
    cx, cz = center
    sx, sz = size
    if not (sx == 1 and sz == 1):
        if rot in (1, 3):                 # rot.IsHorizontal: swap x and z
            sx, sz = sz, sx
        ox, oz = ROT_SHIFT[rot]
        if sx % 2 == 0:
            cx += ox
        if sz % 2 == 0:
            cz += oz
    minx, minz = cx - (sx - 1) // 2, cz - (sz - 1) // 2
    return (minx, minz, minx + sx - 1, minz + sz - 1)


def rect_plan(d, pos, rot):
    """Plan rect (x0, y0, w, h) of a def at pos/rot (x0, y0 = north-west cell)."""
    n = _as_info(d)
    r = effective_rot(n, rot)
    minx, minz, maxx, maxz = occupied_rect_game(to_game(pos), r, n["size"])
    return (minx, -maxz, maxx - minx + 1, maxz - minz + 1)


def footprint(d, pos, rot):
    """Plan cells (x, y) a def covers when placed at plan cell pos with rotation rot, row by row from the north-west
    corner. Odd sides are centred on pos; even sides shift as GenAdj does (R0)."""
    x0, y0, w, h = rect_plan(d, pos, rot)
    return [(x0 + i, y0 + j) for j in range(h) for i in range(w)]


def rect_of(cells):
    """(x0, y0, w, h) bounding rect of plan cells."""
    xs = [c[0] for c in cells]
    ys = [c[1] for c in cells]
    return (min(xs), min(ys), max(xs) - min(xs) + 1, max(ys) - min(ys) + 1)


def rotated_size(d, rot):
    n = _as_info(d)
    sx, sz = n["size"]
    return (sz, sx) if effective_rot(n, rot) in (1, 3) else (sx, sz)


def place_by_rect(d, x0, y0, rot):
    """Position cell that puts the def's north-west corner at plan cell (x0, y0) with rotation rot. Inverse of
    footprint(); equal to sim_raids.thing_position."""
    n = _as_info(d)
    r = effective_rot(n, rot)
    w, h = rotated_size(n, r)
    cx = x0 + (w - 1) // 2
    cz = -(y0 + h - 1) + (h - 1) // 2
    if not (w == 1 and h == 1):
        ox, oz = ROT_SHIFT[r]
        if w % 2 == 0:
            cx -= ox
        if h % 2 == 0:
            cz -= oz
    pos = (cx, -cz)
    assert rect_plan(n, pos, r)[:2] == (x0, y0), (n["name"], x0, y0, r, pos)
    return pos


def rotate_offset(off, rot):
    """IntVec3.RotatedBy(Rot4) on an (x, z) game offset: N (x,z), E (z,-x), S (-x,-z), W (-z,x)."""
    x, z = off
    return {0: (x, z), 1: (z, -x), 2: (-x, -z), 3: (-z, x)}[rot_index(rot)]


def interaction_cells(d, pos, rot):
    """All interaction cells (plan) of a def at pos/rot: P + offset.RotatedBy(rot) (ThingUtility.InteractionCell, R1).
    Several for defs with multipleInteractionCellOffsets (school desk: student first, teacher second)."""
    n = _as_info(d)
    r = effective_rot(n, rot)
    gx, gz = to_game(pos)
    out = []
    for off in n["ic"]:
        rx, rz = rotate_offset(off, r)
        out.append(to_plan((gx + rx, gz + rz)))
    return out


def interaction_cell(d, pos, rot):
    ics = interaction_cells(d, pos, rot)
    return ics[0] if ics else None


def bed_head_cells(d, pos, rot):
    """Sleeping-slot (pillow) cells, BedUtility.GetSleepingSlotPos for slot 0..size.x-1 (R3)."""
    return _bed_slots(d, pos, rot, head=True)


def bed_foot_cells(d, pos, rot):
    return _bed_slots(d, pos, rot, head=False)


def _bed_slots(d, pos, rot, head):
    n = _as_info(d)
    r = effective_rot(n, rot)
    minx, minz, maxx, maxz = occupied_rect_game(to_game(pos), r, n["size"])
    out = []
    for i in range(n["size"][0]):
        if r == 2:
            g = (minx + i, maxz if head else minz)
        elif r == 0:
            g = (maxx - i, minz if head else maxz)
        elif r == 3:
            g = (maxx if head else minx, maxz - i)
        else:
            g = (minx if head else maxx, minz + i)
        out.append(to_plan(g))
    return out


def bed_foot_dir(rot):
    """Plan (dx, dy) the foot of a bed points to: the bed extends from its head in its rotation direction (R3)."""
    return FACING[rot_index(rot)]


def bed_head_dir(rot):
    dx, dy = FACING[rot_index(rot)]
    return (-dx, -dy)


def side_cells(cells, vec):
    """Cells just outside a rect on the side vec points to."""
    s = set(cells)
    return sorted({(x + vec[0], y + vec[1]) for x, y in cells if (x + vec[0], y + vec[1]) not in s},
                  key=lambda c: (c[1], c[0]))


def front_side(d, pos, rot):
    """The working side of a bench (where its interaction cell is), or for things without one the side they face.
    Returns {'dir': 'S', 'vec': (0, 1), 'cells': [...]}: benches at North have the worker south of P."""
    n = _as_info(d)
    r = effective_rot(n, rot)
    cells = footprint(n, pos, r)
    vec = FACING[r]
    ics = interaction_cells(n, pos, r)
    if ics:
        x0, y0, w, h = rect_of(cells)
        ix, iy = ics[0]
        if iy > y0 + h - 1:
            vec = (0, 1)
        elif iy < y0:
            vec = (0, -1)
        elif ix > x0 + w - 1:
            vec = (1, 0)
        elif ix < x0:
            vec = (-1, 0)
    name = {(0, -1): "N", (1, 0): "E", (0, 1): "S", (-1, 0): "W"}[vec]
    return {"dir": name, "vec": vec, "cells": side_cells(cells, vec)}


def true_center(d, pos, rot):
    """GenThing.TrueCenter in plan coordinates (x + 0.5, y + 0.5 of the rect centre); facility distances use it."""
    x0, y0, w, h = rect_plan(d, pos, rot)
    return (x0 + w / 2.0, y0 + h / 2.0)


def watch_rects(d, pos, rot):
    """Watch cells rects (plan, x0, y0, w, h) of a watch building (TV, horseshoes pin): one rect in its rotation
    direction, or one per direction when it is not rotatable (WatchBuildingUtility.GetWatchCellRect, R72, R73)."""
    n = _as_info(d)
    wt = n.get("watch")
    if not wt:
        return []
    r = effective_rot(n, rot)
    dirs = [r] if n["rotatable"] else [0, 1, 2, 3]
    cx, cz = to_game(pos)
    card = {0: (0, 1), 1: (1, 0), 2: (0, -1), 3: (-1, 0)}       # GenAdj.CardinalDirections (game x, z)
    out = []
    a, b, width = wt["min"], wt["max"], wt["width"]
    for wr in dirs:
        dx, dz = card[wr]
        if wr in (1, 3):
            x1, x2 = cx + dx * a, cx + dx * b
            hi, lo = cz + width // 2, cz - width // 2
            if width % 2 == 0:
                if wr == 3:
                    lo += 1
                else:
                    hi -= 1
            minx, maxx, minz, maxz = min(x1, x2), max(x1, x2), lo, hi
        else:
            z1, z2 = cz + dz * a, cz + dz * b
            hi, lo = cx + width // 2, cx - width // 2
            if width % 2 == 0:
                if wr == 0:
                    lo += 1
                else:
                    hi -= 1
            minx, maxx, minz, maxz = lo, hi, min(z1, z2), max(z1, z2)
        out.append((minx, -maxz, maxx - minx + 1, maxz - minz + 1))
    return out


# ------------------------------------------------------------------------------------------------ stuff and value

# name: (stuff def, base MarketValue, Beauty factor, Beauty offset, WorkToBuild factor, WorkToBuild offset, HP factor)
# from Core Items_Resource_Stuff.xml and Various_Stone.xml (stuffProps statFactors / statOffsets)
STUFF = {
    "wood": ("WoodLog", 1.2, 1.0, 0.0, 0.7, 0.0, 0.65), "steel": ("Steel", 1.9, 1.0, 0.0, 1.0, 0.0, 1.0),
    "plasteel": ("Plasteel", 9.0, 1.0, 0.0, 2.2, 0.0, 2.8), "gold": ("Gold", 10.0, 4.0, 20.0, 0.9, 0.0, 0.6),
    "silver": ("Silver", 1.0, 2.0, 6.0, 1.0, 0.0, 0.7), "uranium": ("Uranium", 6.0, 0.5, 0.0, 1.9, 0.0, 2.5),
    "jade": ("Jade", 5.0, 2.5, 10.0, 5.0, 0.0, 0.5),
    "granite": ("BlocksGranite", 0.9, 1.0, 0.0, 6.0, 140.0, 1.7),
    "marble": ("BlocksMarble", 0.9, 1.35, 1.0, 5.5, 140.0, 1.2),
    "sandstone": ("BlocksSandstone", 0.9, 1.1, 0.0, 5.0, 140.0, 1.4),
    "slate": ("BlocksSlate", 0.9, 1.1, 0.0, 6.0, 140.0, 1.3),
    "limestone": ("BlocksLimestone", 0.9, 1.0, 0.0, 6.0, 140.0, 1.55),
    "cloth": ("Cloth", 1.5, 1.0, 0.0, 1.0, 0.0, 1.0), "synthread": ("Synthread", 4.0, 2.3, 0.0, 1.0, 0.0, 1.3),
    "devilstrand": ("DevilstrandCloth", 5.5, 3.2, 0.0, 1.0, 0.0, 1.3),
    "hyperweave": ("Hyperweave", 9.0, 5.5, 0.0, 1.0, 0.0, 2.4),
}
# base MarketValue of cost-list resources (Core 1.6 XML); anything else counts 2 (StatWorker_MarketValue guess value)
RESOURCE_VALUE = {"Steel": 1.9, "WoodLog": 1.2, "Plasteel": 9.0, "Gold": 10.0, "Silver": 1.0, "Uranium": 6.0,
                  "Jade": 5.0, "Cloth": 1.5, "ComponentIndustrial": 32.0, "ComponentSpacer": 200.0, "Chemfuel": 2.3,
                  "Neutroamine": 6.0, "MedicineIndustrial": 18.0, "Hyperweave": 9.0, "DevilstrandCloth": 5.5,
                  "Synthread": 4.0, "Hay": 0.36, "Kibble": 1.1}
for _k, _v in STUFF.items():
    RESOURCE_VALUE.setdefault(_v[0], _v[1])
QUALITY_VALUE = {"awful": 0.5, "poor": 0.75, "normal": 1.0, "good": 1.25, "excellent": 1.5, "masterwork": 2.5,
                 "legendary": 5.0}               # MarketValueBase StatPart_Quality (Stats_Basics_General.xml)
QUALITY_BEAUTY = {"awful": -0.1, "poor": 0.5, "normal": 1.0, "good": 2.0, "excellent": 3.0, "masterwork": 5.0,
                  "legendary": 8.0}              # Beauty StatPart_Quality


def norm_stuff(stuff):
    """'BlocksGranite', 'granite', 'WoodLog', 'wood' -> 'granite' / 'wood' (sim_raids.norm_material)."""
    if not stuff:
        return None
    sr = sim_raids()
    if sr:
        return sr.norm_material(stuff)
    s = "".join(ch for ch in str(stuff).lower() if ch.isalpha())
    for part in ("blocks", "block"):
        s = s[len(part):] if s.startswith(part) else s
        s = s[:-len(part)] if s.endswith(part) else s
    return "wood" if s in ("woodlog", "woodlogs", "log", "logs", "wooden") else s


def stuff_row(stuff):
    return STUFF.get(norm_stuff(stuff)) if stuff else None


def market_value(d, stuff=None, quality=None):
    """StatWorker_MarketValue.CalculatedBaseMarketValue (cost list + stuff + 0.0036 per unit of work), times the
    quality factor. Returns (value, guessed)."""
    n = _as_info(d)
    guessed = False
    if n.get("market_value") is not None:
        v = n["market_value"]
    else:
        v = 0.0
        for res, cnt in (n.get("cost") or {}).items():
            rv = RESOURCE_VALUE.get(res)
            if rv is None:
                rv, guessed = 2.0, True
            v += cnt * rv
        work = n.get("work") or 0.0
        sc = n.get("stuff_count") or 0
        if sc:
            row = stuff_row(stuff)
            if row:
                v += sc * row[1]
                work = work * row[4] + row[5] if work > 0 else work + row[5]
            else:
                v += sc * 2.0                      # DefaultGuessStuffCost
                guessed = True
        if work > 2:
            v += work * 0.0036
    v *= QUALITY_VALUE.get((quality or "normal").lower(), 1.0)
    return v, guessed


def beauty_of(d, stuff=None, quality=None):
    """Beauty stat with the stuff factor (only on positive values) and offset, then quality (StatWorker order)."""
    n = _as_info(d)
    b = n.get("beauty") or 0.0
    row = stuff_row(stuff) if (n.get("stuff_count") or 0) else None
    if row:
        if b > 0:
            b *= row[2]
        b += row[3]
    q = QUALITY_BEAUTY.get((quality or "normal").lower(), 1.0)
    if b > 0:
        b *= q
    return b


def hp_of(d, stuff=None):
    """MaxHitPoints x stuff factor (sim_raids.STUFF_HP_FACTOR when the def is made from stuff)."""
    n = _as_info(d)
    if n.get("hp") is None:
        return None
    if stuff and (n.get("stuff_count") or 0):
        sr = sim_raids()
        f = (sr.STUFF_HP_FACTOR.get(norm_stuff(stuff)) if sr else None)
        if f is None:
            row = stuff_row(stuff)
            f = row[6] if row else None
        if f is not None:
            return int(round(n["hp"] * f))
    return n["hp"]


# Wall and door defs touching a room count for its wealth and beauty (they register in the room's regions, R22).
WALL_DEF = {"defName": "Wall", "size": [1, 1], "extra": {"cost_stuff_count": 5, "work_to_build": 135},
            "beauty": 0, "rotatable": False, "passability": "Impassable", "fill_percent": 1}
DOOR_DEF = {"defName": "Door", "size": [1, 1], "extra": {"cost_stuff_count": 25, "work_to_build": 850},
            "beauty": 0, "rotatable": False, "passability": "Standable", "fill_percent": 1}


# ------------------------------------------------------------------------------------------------ floors

# name: (beauty, cleanliness, path cost, vanilla market value, natural). Core 1.6 Terrain_Floors*.xml and
# TerrainDefGenerator_Stone (R33 beauty, R35 cleanliness, R89 path cost). Market value = cost list + 0.0036 x work;
# with Floors Are (Absolutely) Worthless (installed, R113) every constructed floor is worth 0, smoothed stone 5.
TERRAIN = {
    "Carpet": (2, 0.0, 0, 13.38, False), "SmoothStone": (2, 0.0, 0, 5.0, False), "StoneTile": (1, 0.0, 0, 7.56, False),
    "Flagstone": (0, 0.0, 0, 5.4, False), "WoodPlankFloor": (0, 0.0, 0, 3.91, False), "MetalTile": (0, 0.2, 0, 16.18, False),
    "SilverTile": (4, 0.2, 0, 72.88, False), "GoldTile": (11, 0.2, 0, 702.88, False),
    "SterileTile": (-1, 0.6, 0, 23.46, False), "Concrete": (-1, 0.0, 0, 2.26, False), "PavedTile": (0, 0.0, 0, 4.88, False),
    "StrawMatting": (-1, -0.1, 1, 1.15, False), "Soil": (-3, -1.0, 2, 0.0, True), "RoughStone": (-1, 0.0, 2, 0.0, True),
    "RoughHewn": (-1, 0.0, 1, 0.0, True), "Sand": (-3, -1.0, 4, 0.0, True), "Mud": (-3, -2.0, 14, 0.0, True),
    "Unspecified": (0, 0.0, 0, 0.0, False),
}
STONES = ("granite", "marble", "sandstone", "slate", "limestone")


def terrain_of(name):
    """(canonical name, values, guessed) for a floor or ground name such as 'Carpet', 'CarpetRed', 'TileGranite',
    'Granite_Smooth', 'WoodPlankFloor', 'SterileTile', 'soil'. A bare stone stuff name on a floor cell reads as that
    stone's tile; anything unknown counts as an unspecified constructed floor (all zero) and is reported."""
    if not name:
        return "Unspecified", TERRAIN["Unspecified"], True
    s = re.sub(r"[^a-z]", "", str(name).lower())
    key = None
    if s.startswith("carpet"):
        key = "Carpet"
    elif "smooth" in s:
        key = "SmoothStone"
    elif s.startswith("flagstone"):
        key = "Flagstone"
    elif s.startswith("tile") and any(st in s for st in STONES) or s == "stonetile":
        key = "StoneTile"
    elif s in ("woodplankfloor", "woodfloor", "woodplank", "wood"):
        key = "WoodPlankFloor"
    elif s in ("metaltile", "steeltile"):
        key = "MetalTile"
    elif s in ("silvertile", "goldtile", "steriletile", "concrete", "pavedtile", "strawmatting"):
        key = {"silvertile": "SilverTile", "goldtile": "GoldTile", "steriletile": "SterileTile",
               "concrete": "Concrete", "pavedtile": "PavedTile", "strawmatting": "StrawMatting"}[s]
    elif s in ("soil", "dirt", "ground", "gravel", "soilrich", "richsoil", "mossyterrain", "lichen"):
        key = "Soil"
    elif "roughhewn" in s:
        key = "RoughHewn"
    elif "rough" in s:
        key = "RoughStone"
    elif s in ("sand", "softsand"):
        key = "Sand"
    elif s in ("mud", "marsh", "marshyterrain"):
        key = "Mud"
    elif s in STONES or norm_stuff(name) in STONES:
        return "StoneTile", TERRAIN["StoneTile"], True
    if key is None:
        return str(name), TERRAIN["Unspecified"], True
    return key, TERRAIN[key], False


# ------------------------------------------------------------------------------------------------ plan items

LAYERS = ("edifice", "wall_attach", "ceiling", "floor_deco", "in_wall")


def item_dict(d, pos, rot=None, room=None, phase=0, stuff=None, id=None, owned_bed=False, note=None,
              quality=None, cells=None, **extra):
    """One furniture item in the plan format sim_raids.py reads (README: furniture keys). d is a catalog entry from
    load_catalog(). pos is the plan Position cell, rot N/E/S/W (forced to the def's default when it is not
    rotatable). Extra keyword arguments are copied (medical=True, prisoner=True, guest=True, couple=True, quality,
    beauty/value overrides...). Fields the catalog cannot give are listed in 'guess'."""
    n = info(d)
    guesses = list(n["guesses"])
    r_in = rot_index(rot) if rot is not None else n["default_rot"]
    r = effective_rot(n, r_in)
    if not n["rotatable"] and rot is not None and r_in != r:
        guesses.append(f"not rotatable: rotation {ROTS[r_in]} ignored, {ROTS[r]} used")
    pos = (int(pos[0]), int(pos[1]))
    fp = footprint(n, pos, r)
    x0, y0, w, h = rect_of(fp)
    ics = interaction_cells(n, pos, r)
    hp = hp_of(n, stuff)
    if hp is None:
        guesses.append("hp: not in the catalog, sim_raids uses its own default")
    if stuff and not n["stuff_count"]:
        guesses.append(f"stuff {stuff!r} given but the def is not made from stuff")
    if n["stuff_count"] and not stuff:
        guesses.append("made from stuff but no stuff given: hp, value and beauty use the base values")
    role = n["sim_role"]
    row = n["role_row"]
    door = role in ("door", "free")
    it = {
        "id": id or f"{room or 'plan'}:{n['name']}@{pos[0]},{pos[1]}",
        "room": room, "def": n["name"], "label_ko": n["label_ko"], "label_en": n["label_en"], "source": n["source"],
        "x": x0, "y": y0, "w": w, "h": h, "rot": ROTS[r], "pos": [pos[0], pos[1]],
    }
    if cells or w * h > 1:
        it["cells"] = [list(c) for c in fp]
    it["interaction"] = list(ics[0]) if ics else None
    if len(ics) > 1:
        it["interaction_cells"] = [list(c) for c in ics]
    it.update({
        "phase": phase, "stuff": stuff, "pass": n["passability"], "path_cost": n["path_cost"], "fill": n["fill"],
        "hp": hp, "edifice": n["edifice"], "layer": n["layer"], "owned_bed": bool(owned_bed),
        "door": door, "fence": role == "fence", "trap": role == "trap", "turret": role == "turret",
    })
    if door:
        it["free_passage"] = role == "free"
    if role == "turret":
        if row and len(row) > 5:
            it["range"], it["min_range"] = row[5], row[6]
        else:
            guesses.append("turret range unknown: sim_raids uses its default")
    if n["layer"] == "in_wall":
        it["over_wall"] = True
    if n["thing_class"]:
        it["thing_class"] = n["thing_class"]
    if quality:
        it["quality"] = quality
    it["power_w"] = n["power_w"]
    if n["bed"] and n["bed"]["medical_default"] and "medical" not in extra:
        it["medical"] = True
    it.update(extra)
    if id is None and owned_bed:
        it["key"] = it["id"]                  # sim_raids names owned beds by 'key'
    notes = [note] if note else []
    if guesses:
        it["guess"] = guesses
        notes.append("guess: " + "; ".join(guesses))
    if not n["verified"]:
        notes.append(f"catalog entry not verified ({n['file']})")
    it["note"] = " | ".join(notes) if notes else None
    return it


def item_by_rect(d, x0, y0, rot=None, **kw):
    """item_dict with the north-west corner given instead of the Position cell (designers think in rectangles)."""
    n = info(d)
    r = effective_rot(n, rot if rot is not None else n["default_rot"])
    return item_dict(d, place_by_rect(n, x0, y0, r), r, **kw)


def place(catalog, def_name, pos, rot=None, **kw):
    return item_dict(catalog.get_def(def_name) if hasattr(catalog, "get_def") else catalog[def_name], pos, rot, **kw)


def place_rect(catalog, def_name, x0, y0, rot=None, **kw):
    return item_by_rect(catalog.get_def(def_name) if hasattr(catalog, "get_def") else catalog[def_name],
                        x0, y0, rot, **kw)


# ------------------------------------------------------------------------------------------------ light

def glow_at_cells(lamp_pos, glow, blocked, radius_cells=None):
    """Lamp light on cells around a lamp, as ComputeGlowGridsJob.Flood + SetGlowFromDist do it (Verse.Glow):
    a Dijkstra over cells, 100 per straight step and 141 per diagonal, the lamp cell at 100, out to
    RoundToInt(radius x 100); light blockers stop it and a diagonal step is refused only when both cardinal cells
    beside it are blockers. blocked(cell) -> True for light blockers. Returns {cell: (rgb ints, int distance)}.
    (The game keeps a stale blocker bit for already-finalised neighbours; that rare quirk is not copied.)"""
    import heapq
    r = glow["radius"]
    maxd = int(math.floor(r * 100 + 0.5))
    start = (int(lamp_pos[0]), int(lamp_pos[1]))
    dist = {start: 100}
    done = set()
    pq = [(100, start)]
    out = {}
    card = ((0, 1), (1, 0), (0, -1), (-1, 0))          # plan: S, E, N, W (game Directions[0..3]: S E N W)
    diag = (((1, 1), 0, 1), ((1, -1), 1, 2), ((-1, -1), 2, 3), ((-1, 1), 0, 3))
    neg = f32(-1.0 / f32(r))
    while pq:
        dd, c = heapq.heappop(pq)
        if c in done or dd != dist.get(c):
            continue
        done.add(c)
        num3 = f32(dd / 100.0)
        if num3 <= r:
            num4 = f32(1.0 / f32(num3 * num3))
            a = f32(1.0 + f32(neg * num3))
            num5 = f32(a + f32(f32(num4 - a) * f32(0.4)))
            rgb = tuple(int(f32(ch * num5)) for ch in glow["rgb"])
            m = max(rgb)
            if m > 255:                       # ColorInt.ProjectToColor32Fast
                rgb = tuple(v * 255 // m for v in rgb)
            if max(rgb) > 0:
                out[c] = (tuple(max(0, v) for v in rgb), int(num3))
        bl = []
        for (dx, dy) in card:
            n = (c[0] + dx, c[1] + dy)
            b = blocked(n)
            bl.append(b)
            if b or n in done:
                continue
            nd = dd + 100
            if nd <= maxd and nd < dist.get(n, 1 << 30):
                dist[n] = nd
                heapq.heappush(pq, (nd, n))
        for (dx, dy), i, j in diag:
            n = (c[0] + dx, c[1] + dy)
            if n in done or blocked(n) or (bl[i] and bl[j]):
                continue
            nd = dd + 141
            if nd <= maxd and nd < dist.get(n, 1 << 30):
                dist[n] = nd
                heapq.heappush(pq, (nd, n))
    return out


def combine_glow(contribs):
    """GlowGrid: sum the lamps' colours (each already a Color32), project to 255, then glow = min(0.5, max channel
    / 255 x 3.6); an overlit cell (distance below a lamp's overlight radius) is 1.0. contribs: [(rgb, dist, ovl)]."""
    s = [0, 0, 0]
    overlit = False
    for rgb, d, ovl in contribs:
        if max(rgb) <= 0:
            continue
        s = [s[i] + rgb[i] for i in range(3)]
        m = max(s)
        if m > 255:
            s = [v * 255 // m for v in s]
        if d < ovl:
            overlit = True
    if overlit:
        return 1.0
    return min(0.5, f32(f32(max(s) / 255.0) * 3.6))


def lit_reach(glow, straight=True):
    """How many cells from a lamp on open floor are still lit (> 30%), straight or diagonal (R57)."""
    cells = glow_at_cells((0, 0), glow, lambda c: False)
    best = 0
    for (x, y), (rgb, d) in cells.items():
        if (straight and y == 0 and x > 0) or (not straight and x == y and x > 0):
            if combine_glow([(rgb, d, glow["overlight"])]) > 0.3:
                best = max(best, x)
    return best
