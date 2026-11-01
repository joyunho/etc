"""Simulate how RimWorld 1.6 raiders path into a base plan.

Reads plan.json / plan_hard.json from gen_base.py and the furnished format (cells with a material,
diagonal walls, furniture, owned beds). The plan sits in the middle of a square map of open ground.
Raiders spawn on the map edge (or, with --spawns, where drop pods could land) and plan their route
to an owned bed, the raid destination of GenAI.RandomRaidDest (Verse.AI/GenAI.cs:118-135). Walkers
cannot open doors: each one heads for the bed when the area it can walk in (walls and closed doors seal
areas) holds the bed, else for the cell of its own area closest to the bed, a castle cell if the area has one.

Every rule follows the decompiled RimWorld 1.6.9371 code; comments cite file:line.

Raid types (--modes)
  sapper        ImmediateAttackSappers (RaidStrategyWorker_ImmediateAttackSappers.cs:34): digs walls
                and doors, avoids turret cover, knows 30% of the traps
  breach        ImmediateAttackBreaching: the breach line of BreachingGrid.CreateBreachPath
  smart_breach  alias of breach: the breach line is a pawn-less path request, so it never uses the
                avoid grid or known traps (BreachingGrid.cs:308-309, PathFinder.cs:106-118)
  walker        ImmediateAttack: cannot pass walls or closed doors (PathUtility.cs:73-90)
  smart_walker  ImmediateAttackSmart (RaidStrategyWorker_ImmediateAttackSmart.cs:11): a walker that
                avoids turret cover and knows 30% of the traps

Cell cost: IndexCost = max(grid cost, provider cost) (Verse/PathFinderJob.cs:204-211)
  step          pawn 13 / 18 ticks (cardinal / diagonal); the pawn-less breach request uses 18 / 18
                (PathFinder.cs:726-735)
  wall (dig)    70 + RoundToInt(0.2 * HP) on full-fill impassable edifices (PathGridJob.cs:93-116, 141)
  door (bash)   max(grid, (ushort)(50 + 0.2 * HP)) (PathUtility.cs:47-62, PathGridDoorsBlockedJob.cs:46-56)
  turret cover  + 8 x avoid grid (PathGridJob.cs:146-149): 45 per turret on every walkable tile within
                range + 4 that sees the turret, capped at 255, then copied into neighbouring edifices
                (AvoidGrid.cs:98-138); unpowered turrets count (AvoidGrid.cs:58-72)
  known trap    max(grid, 800) (Building_Trap.cs:186-193); smart lords know each trap with p = 0.3
                (LordJob_AssaultColony.cs:34-43, Building_Trap.cs:174)
  things        impassable things are dug like walls if full-fill, else they block; pass-through things
                (solar panels, generators, turrets, sandbags, fences) cost their path cost; only
                full-fill edifices and fences block a diagonal step (PathFinderJob.cs:147-155,
                BuildingSource.cs:96-115)
  breach line   BreachingGrid tuning (BreachingGrid.cs:196-230, 295-326): walls 20 + RoundToInt(0.015 * HP),
                doors max(grid, 20 + 0.015 * HP), a custom offset (ushort)(20 + 0.015 * HP) on every
                destroyable edifice and +30 on Perlin-noise cells (BreachingGrid.cs:43-90)

Search: exact reverse Dijkstra from each target (default). The 1.6 A* at heuristic weight 1 finds almost
the same routes (within about 0.2% of the optimal cost here): its octile heuristic, 13 per straight step
and 18.4 per diagonal, slightly overestimates the 18-tick diagonal step. --astar runs the 1.6 forward
weighted A*, --replan the sapper dig-and-re-plan loop.

Plan format (old and new)
  origin, cells    rows of [type, room, phase, door_phase] or [..., material]; type ground, floor, wall,
                   door, gate or diag (Vanilla Diagonal Walls: a wall for paths and sight). A cell is built
                   from its phase; a door slot stays wall until door_phase.
  materials        optional {material: wall HP} or {material: {"wall": hp, "door": hp}}; else built-in
                   stuff factors (wall 300, door 160 x factor). Cells without a material: WALL_HP / DOOR_HP.
  furniture        optional [{def, x, y, w, h, rot, phase, pass, path_cost, hp, owned_bed}]; x, y is the
                   top-left cell, w, h the rotated size; pass may be written passability, hp max_hit_points.
                   Optional: fill (or fill_percent), door, free_passage, fence, trap, turret with range and
                   min_range, over_wall, edifice, thing_class, stuff, key. Defs in DEF_ROLES (Core, Biotech,
                   Odyssey and the user's mods) need none of them; for other defs the role is guessed from the
                   def or class name and the run lists the guesses in a note. A door, or an edifice that may be
                   built over walls, replaces the wall cell it is placed on and takes its own hp.
  beds             optional [[x, y] or [x, y, phase] or {x, y, phase, key}]: raid targets. Without it: owned
                   beds in the furniture, else the centres of bedroom, prison and school rooms. If none is
                   built by --phase, the planned spots are targeted anyway (with a note).
  features         {kind, phase, cells}. Buildings: turret, trap, fence, sandbags, solar, generator, graves,
                   wastepack, centrepiece, anchor, engine, console, tank, thruster. Zones that name the
                   routes: hole, gategap, court, lane, maint and store (trap block), postern; without any of
                   them the outer route prints as unlabelled. hole + court are the intended entry for the
                   margin (--entry). rooms: key, kind, center, phase; outdoor kinds (court, yard, field, ...)
                   are open ground, the other rooms are the castle.

Usage: python -I sim_raids.py <plan.json> [--map 250] [--step 10] [--phase N] [--params params.json]
         [--png out.png] [--out report.json] [--modes sapper,breach,walker,smart_walker]
         [--spawns edge|yard|court|lane|inside|all] [--kill "x,y;x,y"] [--kill-pairs] [--kill-each]
         [--noise libnoise|audit|off] [--noise-seeds none,0,1,2,3] [--seed 0] [--seeds 1]
         [--astar] [--replan] [--replan-ticks 500] [--beds key,key] [--entry hole,court] [--no-margin]
         [--png-paths 300]
"""
import collections
import heapq
import json
import math
import random
import re
import struct
import sys
import time

INF = 1 << 60

P = {
    "CARD": 13, "DIAG": 18,                   # move ticks of a 4.6 c/s human, rounded (PathFinder.cs:726-730)
    "WALL_BASE": 70, "WALL_PER_HP": 0.2,      # PathFinderCostTuning.DefaultTuning (PathFinderCostTuning.cs:42)
    "DOOR_BASE": 50, "DOOR_PER_HP": 0.2,      # 1.6 multiplies door HP by WALL_PER_HP (PathUtility.cs:62)
    "WALL_HP": 510, "DOOR_HP": 272,           # cells without a material: granite blocks (300 x 1.7, 160 x 1.7)
    "AVOID_PER_TURRET": 45, "AVOID_CAP": 255, "AVOID_FACTOR": 8,     # AvoidGrid.cs:108, 116; PathGridJob.cs:148
    "TURRET_RANGE": 28.9, "RANGE_EXTRA": 4,   # mini-turret gun; the avoid grid reaches range + 4 (AvoidGrid.cs:102)
    "TRAP_KNOWN": 800, "KNOWN_CHANCE": 0.3,   # Building_Trap.cs:27; LordJob_AssaultColony.cs:42
    "FENCE": 80, "SANDBAG": 42,               # path costs from the Fence and Sandbags defs
    "BREACH_BASE": 20, "BREACH_PER_HP": 0.015, "BREACH_NOISE": 30, "BREACH_STEP": 18,   # BreachingGrid.cs:197-206
    "REPLAN_TICKS": 500,                      # the sapper's Goto job expires after 500 ticks (JobGiver_AISapper.cs:61)
}

# MaxHitPoints = base x stuff factor. Bases: Wall 300, DoorBase 160 (Buildings_Structure.xml). Factors:
# Items_Resource_Stuff.xml (WoodLog 0.65, Steel 1, Plasteel 2.8, ...) and Various_Stone.xml (BlocksGranite
# 1.7, BlocksMarble 1.2, BlocksLimestone 1.55, BlocksSandstone 1.4, BlocksSlate 1.3). Walls: wood 195,
# granite 510, marble 360, limestone 465 (not 455), sandstone 420, slate 390, steel 300, plasteel 840.
WALL_BASE_HP, DOOR_BASE_HP = 300, 160
STUFF_HP_FACTOR = {"wood": 0.65, "granite": 1.7, "marble": 1.2, "limestone": 1.55, "sandstone": 1.4, "slate": 1.3,
                   "steel": 1.0, "plasteel": 2.8, "silver": 0.7, "gold": 0.6, "uranium": 2.5, "jade": 0.5}

# Old plans name buildings by feature kind; values from the 1.6 defs (audit S8).
FEATURE_THINGS = {
    "solar": dict(pass_="PassThroughOnly", path_cost=50, hp=300, fill=0.5),       # SolarGenerator
    "generator": dict(pass_="PassThroughOnly", path_cost=50, hp=300, fill=0.9),   # WoodFiredGenerator
    "turret": dict(pass_="PassThroughOnly", path_cost=50, hp=100, fill=0.4),      # Turret_MiniTurret
    "sandbags": dict(pass_="PassThroughOnly", path_cost="SANDBAG", hp=300, fill=0.55),
    "fence": dict(pass_="PassThroughOnly", path_cost="FENCE", hp=40, fill=0.25, fence=True),
    "trap": dict(pass_="Standable", path_cost=0, hp=40, fill=0.0, trap=True),     # TrapSpike
    "graves": dict(pass_="Standable", path_cost=0, hp=0, fill=0.0),               # Grave: useHitPoints false
}
BLOCK_FEATURES = ("centrepiece", "anchor", "engine", "console", "tank", "thruster")   # impassable, full-fill

# Furniture roles. The 1.6 path code knows what a building is from its def and class, never from its name (audit S8,
# S9). An item that names only its def takes its role from this table: the 1.6 def XML of Core, Biotech, Odyssey and
# the mods in the user's list, and the class tree of Assembly-CSharp 1.6.4871 (Building_TurretRocket and
# Building_TurretFoam : Building_TurretGun; Building_MultiTileDoor and Building_VacBarrier : Building_SupportedDoor :
# Building_Door; Building_TrapDamager, Building_TrapExplosive and Building_TrapReleaseEntity : Building_Trap).
#   door    a Building_Door: closed to hostile walkers, bashed by diggers (PathUtility.cs:35-91)
#   free    a door with FreePassage: everyone walks through, and it is always open, so it never blocks sight
#           (Building_VacBarrier: FreePassage => true, AlwaysOpen => true; PathUtility.cs:42, 54)
#   fence   building.isFence (FenceSource.cs:19): no raider can step diagonally past it (PathFinderJob.cs:151)
#   trap    a Building_Trap, a path cost provider (Building_Trap.cs:9, 186-193)
#   turret  an ai_combatDangerous Building_TurretGun, with the range and minRange of its turretGunDef verb
#           (AvoidGrid.cs:66-68, 100-101)
#   wall    not a door, but an edifice that may be built over a wall and then replaces it (canPlaceOverWall)
#   none    looks like one of the above, but is not
# Columns: role, passability, path cost, base MaxHitPoints (None: not in the local defs), fillPercent, then range and
# min range for a turret. "inf": the mod's class could not be read here, so the role is inferred from its def.
_ST, _PT, _IM = "Standable", "PassThroughOnly", "Impassable"
DEF_ROLES = {
    # doors: DoorBase is a Building_Door with fillPercent 1 and canPlaceOverWall (Core Buildings_Structure.xml:7-39)
    "Door": ("door", _ST, 0, 160, 1.0), "Autodoor": ("door", _ST, 0, 160, 1.0),    # Buildings_Structure.xml:66, 89
    "AnimalFlap": ("door", _ST, 0, 20, 1.0), "OrnateDoor": ("door", _ST, 0, 250, 1.0),   # :127, 161
    "FenceGate": ("door", _ST, 0, 20, 1.0),            # :430, a door without isFence
    "VacBarrier": ("free", _ST, 0, None, 1.0),         # Odyssey, Building_VacBarrier
    "DoorSaloon": ("door", _ST, 0, 40, 1.0),           # VFE Settlers DoorSaloon.xml:5. Building_SaloonDoor declares
    # FreePassage, CanPhysicallyPass and PawnCanOpen with 'new' (Building_SaloonDoor.cs:8-13); the path code calls
    # the Building_Door members, so it is an ordinary door
    "VFEArch_SingleDoor": ("door", _ST, 0, 120, 1.0), "VFEArch_ArmoredDoor": ("door", _ST, 0, 450, 1.0),
    "VFEArch_CellDoor": ("door", _ST, 0, 80, 1.0), "VFEArch_AnimalGate": ("door", _ST, 0, 40, 1.0),
    # VFE Architect Buildings_Structure.xml:856, 813, 684, 901 (Building_DoorSingle : Building_Door)
    "RB_GlassAutodoor": ("door", _ST, 0, 80, 1.0), "RB_ReinforcedGlassAutodoor": ("door", _ST, 0, 160, 1.0),
    "RB_DoubleDoor": ("door", _ST, 0, 160, 1.0), "RB_LargeOrnateDoor": ("door", _ST, 0, 350, 1.0),
    "RB_CellDoor": ("door", _ST, 0, 80, 1.0),          # ReBuild Buildings_Structure_Doors.xml:6, 72, 127, 233, 298
    "RB_DoubleAutodoor": ("door", _ST, 0, 160, 1.0, "inf"),   # :173, Building_MultiTileDoorStuffColor
    "DU_Blastdoor": ("door", _ST, 0, 1000, 1.0),       # Rimatomics Buildings_D_Env.xml:275
    "VGE_VacBarrierDouble": ("free", _ST, 0, 150, 1.0, "inf"),     # VGE Buildings_VacBarriers.xml:4, 50, 90, 130:
    "VGE_VacBarrierTriple": ("free", _ST, 0, 200, 1.0, "inf"),     # DoorBase with Building_VacBarrier_Recolorable
    "VGE_VacBarrierQuintuple": ("free", _ST, 0, 300, 1.0, "inf"),
    "VGE_VacCheckpoint": ("none", _ST, 0, 0, 0.0),     # Buildings_VacCheckpoint.xml:5: a Standable marker, no hit points
    "ToiletStallDoor": ("wall", _ST, 0, 250, 0.15),    # Dubs Bad Hygiene BuildingsB_Hygiene.xml:57, 104
    # (canPlaceOverWall); Building_StallDoor : Verse.Building (BadHygiene.dll), so it does not close the wall line
    "sbz_SingleWallFridge": ("wall", _IM, 0, 100, 1.0), "sbz_DoubleWallFridge": ("wall", _IM, 0, 200, 1.0),
    # [sbz] Fridge Buildings_Fridge.xml:536, 653
    # fences: building.isFence
    "Fence": ("fence", _PT, 80, 40, 0.25),             # Core Buildings_Structure.xml:336, 413
    "Barricade": ("fence", _PT, 42, 300, 0.55),        # Core Buildings_Security.xml:70, 106
    "AncientFence": ("fence", _PT, 60, 50, 0.55),      # Core Buildings_Ancient_Outdoors.xml:254, 290
    "VFEArch_ChainlinkFence": ("fence", _PT, 140, 100, 0.25), "VFEArch_PicketFence": ("fence", _PT, 70, 40, 0.25),
    "VFEArch_BrickFence": ("fence", _PT, 140, 100, 0.25), "VFEArch_LowFence": ("fence", _PT, 80, 40, 0.25),
    "VFEArch_InvisibleFence": ("fence", _PT, 0, 20, 0.0),   # VFE Architect Buildings_Structure.xml:93-495
    "VFEPD_AncientFence": ("fence", _PT, 30, 50, 0.25),     # VFE Props, Ideology Buildings_Ideology.xml:1235, 1270
    "VQE_AncientChainlinkFence": ("fence", _PT, 60, 40, 0.55),   # VQE The Generator Buildings_Misc.xml:688, 724
    "Sandbags": ("none", _PT, 42, 300, 0.55),          # Core Buildings_Security.xml:7, no isFence
    # traps: Building_Trap
    "TrapSpike": ("trap", _ST, 0, 40, 0.0),            # Core Buildings_Security.xml:134, Building_TrapDamager
    "TrapIED_HighExplosive": ("trap", _ST, 0, 40, 0.0), "TrapIED_Incendiary": ("trap", _ST, 0, 40, 0.0),
    "TrapIED_EMP": ("trap", _ST, 0, 40, 0.0), "TrapIED_Smoke": ("trap", _ST, 0, 40, 0.0),
    "TrapIED_Firefoam": ("trap", _ST, 0, 40, 0.0), "TrapIED_AntigrainWarhead": ("trap", _ST, 0, 40, 0.0),
    # TrapIEDBase, Building_TrapExplosive (Buildings_Security.xml:185-206)
    "TrapIED_ToxGas": ("trap", _ST, 0, 40, 0.0),       # Biotech Buildings_Misc.xml:944, TrapIEDBase
    "HunterDroneTrap": ("trap", _ST, 0, None, 0.0), "WaspDroneTrap": ("trap", _ST, 0, None, 0.0),
    # Odyssey: Building_TrapReleaseHunter / Building_TrapReleaseWasp
    "FSFStoneTrapSpike": ("trap", _ST, 0, 40, 0.0),    # [FSF] Stone_Spike_Traps.xml:6, Building_TrapDamager
    "GR_TrapIED_Boom": ("trap", _ST, 0, 40, 0.0),      # Vanilla Genetics Expanded Buildings_Security.xml:45
    "AncientTankTrap": ("none", _PT, 50, 500, 0.5),    # Core Buildings_Ancient_Outdoors.xml:325, a plain Building
    # turrets on the avoid grid
    "Turret_MiniTurret": ("turret", _PT, 50, 100, 0.4, 28.9, 0.0),     # Core Buildings_Security_Turrets.xml:112
    "Turret_Autocannon": ("turret", _PT, 50, 380, 0.5, 32.9, 8.9),     # :325
    "Turret_Sniper": ("turret", _PT, 50, 380, 0.5, 45.9, 11.9),        # :428
    "Turret_RocketswarmLauncher": ("turret", _PT, 50, 200, 0.4, 29.9, 0.0),    # :833, Building_TurretRocket
    "Turret_GatlingGun": ("turret", _PT, 50, 100, 0.4, 22.9, 0.0),     # VFE Settlers TurretGatlingGun.xml:55
    # Rimatomics Buildings_E_Weapons.xml:200, 319, 432, 555, 735: ai_combatDangerous with a turretGunDef
    "PPCADS": ("turret", _PT, 150, 300, 0.4, 31.0, 0.0, "inf"),
    "PPCTeslaCoil": ("turret", _PT, 150, 300, 0.4, 19.9, 0.0, "inf"),
    "PPCHEL": ("turret", _PT, 150, 200, 0.4, 55.0, 0.0, "inf"),
    "PPCRailgun": ("turret", _PT, 50, 480, 0.4, 400.0, 9.8, "inf"),
    "PPCObelisk": ("turret", _PT, 150, 420, 0.4, 45.0, 0.0, "inf"),
    # VGE Buildings_Artillery.xml:229, 362, 521: gravship guns, ai_combatDangerous with a turretGunDef
    "VGE_GaussGun": ("turret", _PT, 0, 400, 1.0, 99999.0, 14.9, "inf"),
    "VGE_JavelinPod": ("turret", _PT, 0, 400, 1.0, 99999.0, 14.0, "inf"),
    "VGE_AnticraftCaster": ("turret", _PT, 0, 400, 1.0, 9999.0, 14.0, "inf"),
    # never on the avoid grid
    "Turret_Mortar": ("none", _PT, 50, 180, 0.4),      # Core Buildings_Security_Turrets.xml:532, no ai_combatDangerous
    "Turret_FoamTurret": ("none", _PT, 50, 100, 0.4),  # :646, ai_combatDangerous false (:747)
    "VFEP_Turret_FieldGun": ("none", _PT, 50, 180, 0.4), "VFEP_Turret_Cannon": ("none", _PT, 50, 180, 0.4),
    # VFE Pirates Buildings_Security_Turrets.xml:7, 103, no ai_combatDangerous
    "VGE_PointDefenseTurret": ("none", _PT, 0, 400, 1.0),   # VGE Buildings_Artillery.xml:85, no ai_combatDangerous
    "PPCMarauder": ("none", _PT, 50, 700, 0.4),        # Rimatomics Buildings_E_Weapons.xml:854, no ai_combatDangerous
    "PPC": ("none", _PT, 150, 200, 0.6), "PPCWeaponsConsole": ("none", _PT, 150, 250, 1.0),   # :53, 95, no turretGunDef
    "APM_GazerEmplacement": ("none", _IM, 90, 400, 1.0),    # Apex GazerEmplacement.xml:4: aimed by hand, no turretGunDef
    "AncientSecurityTurret": ("none", _PT, 50, 100, 0.5),   # Core Buildings_Ancient_Indoors.xml:471, a plain Building
}
# thing_class -> role, for items that give their class (namespace optional for vanilla classes)
CLASS_ROLES = {"Building_Door": "door", "Building_SupportedDoor": "door", "Building_MultiTileDoor": "door",
               "Building_HackableDoor": "door", "Building_JammedDoor": "door", "Building_VacBarrier": "free",
               "VFEArchitect.Building_DoorSingle": "door", "VFEArchitect.Building_DoorSingleFlipped": "door",
               "VFE_Settlers.Buildings.Building_SaloonDoor": "door", "Building_Trap": "trap",
               "Building_TrapDamager": "trap", "Building_TrapExplosive": "trap", "Building_TrapReleaseEntity": "trap",
               "Building_TrapReleaseHunter": "trap", "Building_TrapReleaseWasp": "trap", "Building_TurretGun": "turret",
               "Building_TurretRocket": "turret", "Building_TurretFoam": "none",
               "DubsBadHygiene.Building_StallDoor": "wall", "VanillaGravshipExpanded.Building_VacCheckpoint": "none"}
# Things that are not edifices (building.isEdifice false in their defs): wall lamps, conduits, pipes, rugs, fans.
NOT_EDIFICE = {"WallLamp", "TorchWallLamp", "PowerConduit", "WaterproofConduit", "HiddenConduit", "CeilingFan",
               "CeilingFanS", "AirconIndoorUnit", "Thermostat", "SkyLightA", "SkyLightB", "SkyLightC", "SkyLightD",
               "VFE_RugSmall", "VFE_RugLarge", "VFE_RugGrand", "VFE_FloorLamp", "VFE_DeskLamp", "RB_FloorLamp",
               "RB_OverwallFireplace", "RB_OverwallArmor", "VFES_WallMountedTelevision", "VGE_WallToolCabinet",
               "VGE_WallFirefoamPopper", "VGE_WallOrbitalTradeBeacon", "Chemlamp"}
MAX_HP_DEFAULT = 100        # StatDef MaxHitPoints defaultBaseValue (Core Stats_Basics_General.xml:9)
BED_ROOM_KINDS = ("bedroom", "prison", "school")
OUTDOOR_ROOM_KINDS = {"court", "yard", "outdoor", "outside", "field", "farm", "garden", "lane"}

S_NONE, S_WALL, S_DOOR, S_DIAG, S_BLOCK, S_THING = range(6)
S_NAME = ("ground", "wall", "door", "diag", "thing", "thing")

# Zones: what a broken wall separates, used to name the route a raider takes.
Z_OUT, Z_YARD, Z_COURT, Z_LANE, Z_BLOCK, Z_GAP, Z_HOLE, Z_CASTLE, Z_SOLID = range(9)
ZONE_NAME = ("outside", "yard", "court", "lane", "trap block", "gate gap", "hole", "castle", "solid")
ZONE_FEATURES = (("hole", Z_HOLE), ("gategap", Z_GAP), ("court", Z_COURT), ("lane", Z_LANE),
                 ("maint", Z_BLOCK), ("store", Z_BLOCK))
OUTER_SIDE = frozenset((Z_OUT, Z_LANE, Z_BLOCK, Z_GAP))
INNER_SIDE = frozenset((Z_YARD, Z_COURT, Z_HOLE, Z_CASTLE))

ROUTE_ZONES = ("hole", "gategap", "court", "lane", "maint", "store", "postern")
OUTER_LABEL = {"lane": "trap lane", "trapblock": "trap block walls/doors", "curtain": "curtain/outer wall",
               "postern": "postern/side door", "gategap": "gate gap (no lane)", "none": "no outer wall",
               "inside": "spawned inside", "unlabelled": "unlabelled outer wall (no route zones)"}
INNER_LABEL = {"hole": "hole/gate tunnel", "wall": "castle side wall", "gap": "open castle gap",
               "inside": "spawned inside", "none": "did not enter"}
BROKE_ORDER = ("trapblock", "curtain", "unlabelled", "postern", "courtwall", "castle", "internal", "other")
BROKE_LABEL = {"trapblock": "trap block", "curtain": "curtain", "unlabelled": "unlabelled outer wall",
               "postern": "postern", "courtwall": "court wall", "castle": "castle wall",
               "internal": "castle interior wall/door", "other": "other"}
DIGGERS = ("sapper", "breach")


def f32(v):
    """Round to a C# float."""
    return struct.unpack("f", struct.pack("f", v))[0]


_GRID_COST, _USHORT_COST = {}, {}


def grid_cost(base, hp, per):
    """costBlockedWallBase + Mathf.RoundToInt((float)hp * perHP) (PathGridJob.cs:141); round half to even."""
    key = (base, hp, per)
    if key not in _GRID_COST:
        _GRID_COST[key] = base + int(round(f32(f32(float(hp)) * f32(per))))
    return _GRID_COST[key]


def ushort_cost(base, hp, per):
    """(ushort)((float)base + (float)hp * per), truncated (PathUtility.cs:62, BreachingGrid.cs:84)."""
    key = (base, hp, per)
    if key not in _USHORT_COST:
        _USHORT_COST[key] = int(f32(f32(float(base)) + f32(f32(float(hp)) * f32(per))))
    return _USHORT_COST[key]


def norm_material(m):
    s = "".join(ch for ch in str(m).lower() if ch.isalpha())
    for part in ("blocks", "block"):
        if s.startswith(part):
            s = s[len(part):]
        if s.endswith(part):
            s = s[:-len(part)]
    return "wood" if s in ("woodlog", "woodlogs", "log", "logs", "wooden") else s


def rot_index(rot):
    if isinstance(rot, str):
        return {"n": 0, "e": 1, "s": 2, "w": 3}.get(rot.strip().lower()[:1], 0)
    return int(rot or 0) % 4


def thing_position(x, y, w, h, rot):
    """Plan cell of a thing's Position, given its rotated footprint with top-left (x, y) (y grows south).
    Inverse of GenAdj.OccupiedRect / AdjustForRotation (GenAdj.cs:606-610, 637-754): north is +z, z = -y."""
    cx = x + (w - 1) // 2
    cz = -(y + h - 1) + (h - 1) // 2
    if rot in (2, 3) and w % 2 == 0:
        cx += 1
    if rot in (1, 2) and h % 2 == 0:
        cz += 1
    return (cx, -cz)


def _first(it, *keys):
    """The value of the first key the item sets (None counts as not set)."""
    for key in keys:
        if it.get(key) is not None:
            return it[key]
    return None


def _flag(v):
    return v.strip().lower() in ("1", "true", "yes") if isinstance(v, str) else bool(v)


def name_words(name):
    """Lower-case words of a def or class name, split at '_', '.' and CamelCase: FSFStoneTrapSpike -> fsf stone trap
    spike, Spacer_OutdoorLamp -> spacer outdoor lamp."""
    return [m.lower() for m in re.findall(r"[A-Z]+(?![a-z])|[A-Z]?[a-z]+|[0-9]+", name)]


def _has(words, word, unless=()):
    return any((x.startswith(word) or x.endswith(word)) and x not in unless for x in words)


def guess_role(d, cls):
    """Role guessed from a thing_class or def name that DEF_ROLES and CLASS_ROLES do not know; None: a plain thing.
    Doors, traps and turrets are classes, so a given class decides those; isFence is a def flag, so a fence is
    always guessed from the def name. Whole words only, so OutdoorLamp is no door and Defence no fence."""
    dw = name_words(d)
    fence = _has(dw, "fence", ("defence", "offence")) or _has(dw, "barricade")
    words = name_words(cls.rsplit(".", 1)[-1]) if cls else dw
    if "vac" in words and _has(words, "barrier"):
        return "free"
    if _has(words, "door", ("outdoor", "outdoors", "indoor", "indoors", "trapdoor")) or (not cls and "gate" in words):
        if not any(x in words for x in ("stall", "fake", "frame")):
            return "door"
    if _has(words, "trap", ("strap", "straps")) and "tank" not in words:
        return "trap"
    if _has(words, "turret") and not any(x in words for x in ("foam", "mortar", "broken", "ruined", "ammo")):
        return "turret"
    return "fence" if fence else None


def furniture_spec(it, params):
    """What the path code needs to know about one furniture item. Item keys come first: door, free_passage, fence,
    trap, turret (+ range, min_range), over_wall, edifice; pass or passability, path_cost, hp or max_hit_points,
    fill or fill_percent, stuff. Then DEF_ROLES by def, CLASS_ROLES by thing_class, the VFE Props rule, and last a
    guess from the names. 'guessed' and 'missing' name what had to be guessed, for the notes."""
    d = str(it.get("def", "thing"))
    dl = d.lower()
    row = DEF_ROLES.get(d)
    cls = str(_first(it, "thing_class", "thingClass", "class") or "")
    short = cls.split(".", 1)[1] if cls.startswith(("RimWorld.", "Verse.")) else cls
    if row:
        role, how = row[0], ("inferred" if row[-1] == "inf" else "table")
    elif short in CLASS_ROLES:
        role, how = CLASS_ROLES[short], "class"
    elif d.startswith("VFEPD_"):
        # VFE Props and Decor: every VFEPD_ def is a VFEProps.Building_* prop or a plain Building, never a door, trap
        # or turret (VFE Props 1.6 Defs); its fences are in DEF_ROLES
        role, how = None, "props"
    else:
        role, how = guess_role(d, cls), "guess"
    flags = {"door": role in ("door", "free"), "free": role == "free", "fence": role == "fence",
             "trap": role == "trap", "turret": role == "turret", "over_wall": role in ("door", "free", "wall")}
    given = set()
    for key, flag in (("door", "door"), ("free_passage", "free"), ("fence", "fence"), ("trap", "trap"),
                      ("turret", "turret"), ("over_wall", "over_wall")):
        if it.get(key) is not None:
            flags[flag] = _flag(it[key])
            given.add(flag)
    if "turret" not in given and it.get("range") is not None:
        flags["turret"] = True                      # an item with a gun range is a turret
        given.add("turret")
    if "door" in given and not flags["door"]:
        flags["free"] = False
    flags["door"] = flags["door"] or flags["free"]
    if flags["door"] and "over_wall" not in given:
        flags["over_wall"] = True                   # every door may be built over a wall
    guessed = [f for f in ("door", "fence", "trap", "turret") if how == "guess" and flags[f] and f not in given]
    if "door" in guessed and flags["free"] and "free" not in given:
        guessed[guessed.index("door")] = "free-passage door"
    missing = []
    turret = None
    if flags["turret"]:
        trow = row if row and row[0] == "turret" else None
        rng = _first(it, "range")
        if rng is None:
            rng = trow[5] if trow else params["TURRET_RANGE"]
            if not trow:
                guessed.append("range")
        mrng = _first(it, "min_range")
        turret = (float(rng), float(mrng if mrng is not None else (trow[6] if trow else 0.0)))
    pass_ = _first(it, "pass", "passability")
    if pass_ is None:
        pass_ = row[1] if row else "Standable"
        if not row:
            missing.append("pass")
    pass_ = {"impassable": _IM, "passthroughonly": _PT, "standable": _ST}.get(str(pass_).lower(), str(pass_))
    cost = _first(it, "path_cost", "pathCost")
    if cost is None:
        cost = row[2] if row else 0
    hp = _first(it, "hp", "max_hit_points", "MaxHitPoints", "hit_points")
    if hp is None:
        base = row[3] if row else None
        stuff = _first(it, "stuff", "material")
        factor = STUFF_HP_FACTOR.get(norm_material(stuff)) if stuff else None
        missing.append("hp" if base is None else "hp_base")
        hp = int(round((MAX_HP_DEFAULT if base is None else base) * (factor or 1.0)))
    fill = _first(it, "fill", "fill_percent", "fillPercent")
    if fill is None:
        if row:
            fill = row[4]
        else:   # every door, FenceGate included, has DoorBase fillPercent 1 (Buildings_Structure.xml:11)
            fill = 1.0 if flags["door"] or pass_ == "Impassable" else (0.5 if pass_ == "PassThroughOnly" else 0.0)
            missing.append("fill")
    edifice = it.get("edifice")
    if edifice is None:
        edifice = not (d in NOT_EDIFICE or dl.endswith(("conduit", "pipe", "pipehidden", "rug"))
                       or dl.startswith(("vfepd_decal", "vfepd_largedecal", "vfepd_filth")))
    if how == "inferred" and {"door": "door", "free": "free", "fence": "fence", "trap": "trap", "turret": "turret",
                              "wall": "over_wall"}.get(role) in given:
        how = "item"                                # the item states the role itself
    return {"def": d, "role": role, "how": how, "door": flags["door"], "free": flags["free"], "fence": flags["fence"],
            "trap": flags["trap"], "turret": turret, "over_wall": flags["over_wall"], "pass_": pass_,
            "path_cost": int(cost or 0), "hp": int(hp or 0), "fill": float(fill), "edifice": _flag(edifice),
            "guessed": guessed, "missing": missing}


class World:
    """The map at one build phase: walls, doors, things, turrets, traps, owned beds and zones."""

    def __init__(self, plan, map_size=250, phase=99, params=None, kill=()):
        self.P = params if params is not None else P
        self.phase = phase
        n = self.n = int(map_size)
        self.half = n // 2
        self.xmin, self.xmax = -self.half, n - self.half - 1
        W = self.W = n + 2                      # padded: a ring of off-map cells around the map
        N = self.N = W * W
        self.notes = []
        self.offmap = bytearray(N)
        for k in range(W):
            self.offmap[k] = self.offmap[N - W + k] = self.offmap[k * W] = self.offmap[k * W + W - 1] = 1
        self.imp = bytearray(self.offmap)       # pathGridDirect >= 10000 (walls, impassable things)
        self.door = bytearray(N)                # closed player door (a free-passage door is not one)
        self.full = bytearray(N)                # full-fill edifice: blocks diagonal steps (BuildingSource.cs:101)
        self.opaque = bytearray(N)              # blocks sight: full fill and not an open door (GenGrid.cs:241-252)
        self.edif = bytearray(N)                # any edifice
        self.fence = bytearray(N)
        self.trap = bytearray(N)
        self.struct = bytearray(N)
        self.hp = [0] * N
        self.pcost = [0] * N                    # path cost of walkable cells
        self.room = [None] * N
        self.kill = [tuple(c) for c in kill]
        self.killed, self.turrets, self.bed_things = [], [], []
        self.thing_phase, self.cell_phase = {}, {}
        self.room_kind = {r.get("key"): r.get("kind") for r in plan.get("rooms") or []}
        self.materials = {norm_material(k): v for k, v in (plan.get("materials") or {}).items()}
        self._load_cells(plan)
        self._load_features(plan)
        self._load_furniture(plan)
        self._load_beds(plan)
        unmatched = [c for c in self.kill if c not in self.killed]
        if unmatched:
            self.notes.append(f"--kill: no turret at {unmatched}")
        self.solid = bytearray(N)
        for k in range(N):
            if (self.imp[k] or self.door[k]) and not self.offmap[k]:
                self.solid[k] = 1
        self.trap_cells = [k for k in range(N) if self.trap[k]]
        self.postern = {self.idx(*c) for c in self.feats.get("postern", [])}
        self._zones()

    def idx(self, x, y):
        return (y + self.half + 1) * self.W + (x + self.half + 1)

    def xy(self, k):
        r, c = divmod(k, self.W)
        return (c - self.half - 1, r - self.half - 1)

    def inside(self, x, y):
        return self.xmin <= x <= self.xmax and self.xmin <= y <= self.xmax

    def edge_cells(self, step=1):
        pts = set()
        for v in range(self.xmin, self.xmax + 1, max(1, step)):
            pts.update(((v, self.xmin), (v, self.xmax), (self.xmin, v), (self.xmax, v)))
        return [self.idx(x, y) for (x, y) in sorted(pts)]

    def mat_hp(self, mat, base):
        if mat in (None, ""):
            return self.P["WALL_HP"] if base == WALL_BASE_HP else self.P["DOOR_HP"]
        key = norm_material(mat)
        v = self.materials.get(key)
        if v is not None:
            if isinstance(v, dict):
                name = "door" if base == DOOR_BASE_HP else "wall"
                if name in v:
                    return int(v[name])
                if "factor" in v:
                    return int(round(base * float(v["factor"])))
                if "wall" in v:
                    return int(round(float(v["wall"]) * base / WALL_BASE_HP))
            else:
                return int(round(float(v) * base / WALL_BASE_HP))     # a plain number is that stuff's wall HP
        f = STUFF_HP_FACTOR.get(key)
        if f is None:
            note = f"unknown material {mat!r}: used the default HP"
            if note not in self.notes:
                self.notes.append(note)
            return self.P["WALL_HP"] if base == WALL_BASE_HP else self.P["DOOR_HP"]
        return int(round(base * f))

    def _set_wall(self, k, hp, s):
        self.imp[k] = self.full[k] = self.opaque[k] = self.edif[k] = 1
        self.door[k] = 0
        self.hp[k] = hp
        self.struct[k] = s

    def _set_door(self, k, hp):
        self.door[k] = self.full[k] = self.opaque[k] = self.edif[k] = 1
        self.imp[k] = 0
        self.hp[k] = hp
        self.struct[k] = S_DOOR

    def _load_cells(self, plan):
        ox, oy = plan["origin"]
        rows = plan["cells"]
        width = max((len(r) for r in rows), default=0)
        if not (self.inside(ox, oy) and self.inside(ox + width - 1, oy + len(rows) - 1)):
            raise SystemExit(f"the plan does not fit a {self.n}x{self.n} map; use a larger --map")
        unknown = collections.Counter()
        for j, row in enumerate(rows):
            for i, c in enumerate(row):
                t, rm = c[0], c[1]
                ph = c[2] if len(c) > 2 else 0
                dph = c[3] if len(c) > 3 else 0
                mat = c[4] if len(c) > 4 else None
                x, y = ox + i, oy + j
                k = self.idx(x, y)
                self.room[k] = rm
                self.cell_phase[(x, y)] = ph or 0
                if t in ("ground", "floor"):
                    continue
                if ph and ph > self.phase:        # not built yet: open ground (a room floor stays walkable)
                    continue
                if t in ("wall", "diag"):         # diag: Vanilla Diagonal Walls, a wall for paths and sight
                    self._set_wall(k, self.mat_hp(mat, WALL_BASE_HP), S_DIAG if t == "diag" else S_WALL)
                elif t in ("door", "gate"):
                    if dph and dph > self.phase:  # door slot still walled up
                        self._set_wall(k, self.mat_hp(mat, WALL_BASE_HP), S_WALL)
                    else:
                        self._set_door(k, self.mat_hp(mat, DOOR_BASE_HP))
                else:
                    unknown[t] += 1
        if unknown:
            self.notes.append(f"unknown cell types treated as open ground: {dict(unknown)}")

    def _put(self, k, pass_="Standable", path_cost=0, hp=0, fill=0.0, fence=False, trap=False, door=False,
             free=False, edifice=True, over_wall=False):
        """Place a building on a cell. An impassable thing makes the cell impassable, otherwise the highest path
        cost of the cell's things counts (PathGrid.CalculatedCostAt, PathGrid.cs:139-158). Only the edifice gives
        the cell hit points, sight and diagonal blocking (BuildingSource.cs:96-115, GenGrid.cs:231-252). A door, or
        another edifice that may be built over walls (DoorBase canPlaceOverWall, Buildings_Structure.xml:39),
        replaces the wall it stands on; a door also replaces a door. Returns "dropped" for any other edifice on a
        wall, diagonal wall or door cell: the cell keeps its wall or door."""
        if self.offmap[k]:
            return None
        s = self.struct[k]
        if s in (S_WALL, S_DIAG, S_DOOR):
            if not edifice:
                return None                       # wall lamps, conduits and other attachments leave the wall as it is
            if not (over_wall and (s == S_WALL or (s == S_DOOR and door))):
                return "dropped"
            self.imp[k] = self.door[k] = self.full[k] = self.opaque[k] = self.edif[k] = 0
            self.hp[k] = 0
            self.struct[k] = S_NONE
        if isinstance(path_cost, str):
            path_cost = self.P[path_cost]
        if door:
            self.door[k] = 0 if free else 1       # FreePassage: walkable for everyone (PathUtility.cs:42, 54)
            self.imp[k] = 0
            self.struct[k] = S_DOOR
        elif pass_ == "Impassable":
            self.imp[k] = 1
            self.struct[k] = S_BLOCK
        elif self.struct[k] == S_NONE:
            self.struct[k] = S_THING
        if not self.imp[k]:
            self.pcost[k] = max(self.pcost[k], int(path_cost or 0))
        if edifice:
            self.edif[k] = 1
            self.hp[k] = max(self.hp[k], int(hp or 0))
            if fill is not None and float(fill) > 0.99:   # ThingDef.Fillage: Full above 0.99
                self.full[k] = 1
                # an AlwaysOpen door is opened at spawn and never closes, so it can be seen over (GenGrid.cs:247;
                # Building_Door.cs:187-193, 283-286)
                self.opaque[k] = 0 if free else 1
        if fence:
            self.fence[k] = 1
        if trap:
            self.trap[k] = 1
        return "placed"

    def _load_features(self, plan):
        feats = {}
        for f in plan.get("features") or []:
            if (f.get("phase") or 0) <= self.phase:   # zones too: a lane or court exists once built (audit S12)
                cells = [tuple(c[:2]) for c in f.get("cells") or [] if self.inside(c[0], c[1])]
                feats.setdefault(f.get("kind"), []).extend(cells)
        self.feats = feats
        self.route_zones = [kind for kind in ROUTE_ZONES if feats.get(kind)]
        for kind, spec in FEATURE_THINGS.items():
            for (x, y) in feats.get(kind, []):
                if kind == "turret" and (x, y) in self.kill:
                    continue
                self._put(self.idx(x, y), **spec)
        for kind in BLOCK_FEATURES:
            for (x, y) in feats.get(kind, []):
                self._put(self.idx(x, y), "Impassable", 0, self.P["WALL_HP"], 1.0)
        wp = feats.get("wastepack", [])
        if wp:   # wastepack freezer: a stone-walled room, walls on the edge and open inside (as audit_sim/sim16.py)
            xs, ys = [c[0] for c in wp], [c[1] for c in wp]
            for (x, y) in wp:
                k = self.idx(x, y)
                if (x in (min(xs), max(xs)) or y in (min(ys), max(ys))) and self.struct[k] in (S_NONE, S_THING):
                    self._set_wall(k, self.P["WALL_HP"], S_WALL)
        for (x, y) in feats.get("turret", []):
            if (x, y) in self.kill:
                self.killed.append((x, y))
                continue
            self.turrets.append({"def": "Turret_MiniTurret", "pos": (x, y), "cells": [(x, y)],
                                 "range": float(self.P["TURRET_RANGE"]), "min_range": 0.0, "guess": False})

    def _load_furniture(self, plan):
        fn = collections.defaultdict(collections.Counter)      # what had to be guessed, for the notes
        for i, it in enumerate(plan.get("furniture") or []):
            sp = furniture_spec(it, self.P)
            d = sp["def"]
            x, y = int(it["x"]), int(it["y"])
            w, h = int(it.get("w", 1)), int(it.get("h", 1))
            ph = it.get("phase") or 0
            cells = [(x + a, y + b) for b in range(h) for a in range(w)]
            for c in cells:
                self.thing_phase[c] = min(ph, self.thing_phase.get(c, ph))
            pos = thing_position(x, y, w, h, rot_index(it.get("rot", 0)))
            if it.get("owned_bed"):           # kept with its phase even if not built yet: the planned bed spot
                self.bed_things.append((str(it.get("key") or f"{d}#{i}"), pos, ph))
            if ph > self.phase:
                continue
            if sp["turret"] and any(c in self.kill for c in [pos] + cells):
                self.killed.extend(c for c in dict.fromkeys([pos] + cells) if c in self.kill)
                continue
            roles = [g for g in sp["guessed"] if g != "range"]      # a guessed range is printed with the turrets
            if roles:
                fn["guessed"][f"{d} as {' + '.join(roles)}"] += 1
            if sp["how"] == "inferred":
                fn["inferred"][f"{d} as {sp['role']}"] += 1
            for m in sp["missing"]:
                fn[m][d] += 1
            put = {k: sp[k] for k in ("pass_", "path_cost", "hp", "fill", "fence", "trap", "door", "free", "edifice",
                                      "over_wall")}
            dropped = [c for c in cells if self.inside(*c) and self._put(self.idx(*c), **put) == "dropped"]
            if dropped:
                fn["dropped"][d] += 1
            if sp["turret"]:
                self.turrets.append({"def": d, "pos": pos, "cells": cells, "range": sp["turret"][0],
                                     "min_range": sp["turret"][1], "guess": "range" in sp["guessed"]})

        def names(c, n=8):
            out = [f"{k} x{v}" if v > 1 else k for k, v in c.most_common()]
            return ", ".join(out[:n]) + (f" and {len(out) - n} more" if len(out) > n else "")
        if fn["guessed"]:
            self.notes.append("furniture roles guessed from the def or thing_class name (give the item door, fence, "
                              "trap or turret keys, or a thing_class, to be sure): " + names(fn["guessed"], 12))
        if fn["inferred"]:
            self.notes.append("furniture roles taken from the def, but the mod's class could not be checked: "
                              + names(fn["inferred"]))
        if fn["fill"]:
            self.notes.append("fill guessed (no fill or fill_percent; doors and Impassable 1, PassThroughOnly 0.5, "
                              "Standable 0): " + names(fn["fill"]))
        if fn["pass"]:
            self.notes.append("no pass or passability, Standable assumed: " + names(fn["pass"]))
        if fn["hp_base"]:
            self.notes.append("no hp: the def's base MaxHitPoints used (times the stuff factor if stuff is given): "
                              + names(fn["hp_base"]))
        if fn["hp"]:
            self.notes.append(f"no hp and an unknown def: the MaxHitPoints default {MAX_HP_DEFAULT} used: "
                              + names(fn["hp"]))
        if fn["dropped"]:
            self.notes.append("furniture on a wall, diagonal wall or door cell left the cell as it was (only doors, "
                              "and edifices with canPlaceOverWall on walls, replace it): " + names(fn["dropped"]))

    def _load_beds(self, plan):
        beds = []
        if plan.get("beds"):
            for i, b in enumerate(plan["beds"]):
                if isinstance(b, dict):
                    x, y, ph, key = b["x"], b["y"], b.get("phase"), str(b.get("key") or f"bed{i + 1}")
                else:
                    x, y, ph, key = b[0], b[1], (b[2] if len(b) > 2 else None), f"bed{i + 1}"
                if ph is None:
                    ph = self.thing_phase.get((x, y), self.cell_phase.get((x, y), 0))
                beds.append((key, (int(x), int(y)), ph or 0))
            self.bed_source = "plan beds"
        elif self.bed_things:
            beds = list(self.bed_things)
            self.bed_source = "owned beds in the furniture list"
        else:
            beds = [(r["key"], tuple(r["center"]), r.get("phase") or 0) for r in plan.get("rooms") or []
                    if r.get("kind") in BED_ROOM_KINDS]
            self.bed_source = ("centres of bedroom, prison and school rooms" if beds else
                               "none: no plan beds, no owned_bed furniture and no bedroom, prison or school room")
        self.all_beds = [b for b in beds if self.inside(*b[1])]
        if beds and not self.all_beds:
            self.bed_source += ", none of them on the map"
        self.beds = [b for b in self.all_beds if b[2] <= self.phase]

    def _zones(self):
        N, W = self.N, self.W
        zone = bytearray([255]) * N
        for k in range(N):
            if self.offmap[k] or self.solid[k]:
                zone[k] = Z_SOLID
        for kind, z in ZONE_FEATURES:
            for (x, y) in self.feats.get(kind, []):
                k = self.idx(x, y)
                if zone[k] == 255:
                    zone[k] = z
        for k in range(N):
            rm = self.room[k]
            if zone[k] == 255 and rm is not None and self.room_kind.get(rm) not in OUTDOOR_ROOM_KINDS:
                zone[k] = Z_CASTLE
        # outside: open cells reached from the map edge without crossing a wall, a door or a zone (4-connected)
        dq = collections.deque(k for k in self.edge_cells() if zone[k] == 255)
        for k in dq:
            zone[k] = Z_OUT
        while dq:
            e = dq.popleft()
            for ni in (e - W, e + W, e - 1, e + 1):
                if zone[ni] == 255:
                    zone[ni] = Z_OUT
                    dq.append(ni)
        for k in range(N):
            if zone[k] == 255:
                zone[k] = Z_YARD                  # enclosed open ground outside any room
        self.zone = zone


# ---------------------------------------------------------------------------------------------- avoid grid

def los_clear(w, sx, sy, ex, ey):
    """GenSight.LineOfSight(start, end, skipFirstCell: true) (GenSight.cs:20-68): a 4-connected walk from
    start to end; the start is skipped and the end never checked. Game z points north (z = -y). A cell
    blocks if it holds a full-fill edifice that is not an open door (GenGrid.cs:231-252): w.opaque."""
    s_z, e_z = -sy, -ey
    flag = (sx < ex) if sx != ex else (s_z < e_z)
    a, b = abs(ex - sx), abs(e_z - s_z)
    stx = 1 if ex > sx else -1
    stz = -w.W if e_z > s_z else w.W          # z + 1 is one row up
    a4, b4 = 4 * a, 4 * b
    err = 2 * a - 2 * b
    k = w.idx(sx, sy)
    blk = w.opaque
    for i in range(a + b):
        if i and blk[k]:
            return False
        if err > 0 or (err == 0 and flag):
            k += stx
            err -= b4
        else:
            k += stz
            err += a4
    return True


def turret_sight(w, t):
    """Cells a turret prints on the avoid grid (AvoidGrid.PrintAvoidGridAroundTurret, AvoidGrid.cs:98-111):
    every walkable cell (doors, traps, fences and pass-through buildings included) from the minimum range
    to range + 4 that has line of sight to the turret. Powered or not does not matter."""
    tx, ty = t["pos"]
    rad = t["range"] + w.P["RANGE_EXTRA"]
    # GenRadial.RadialPattern holds 20000 cells, out to d^2 = 6370 (radius 79.81); a longer reach prints all of it
    # (GenRadial.cs:17, 166-172). The game takes 11 of the 16 cells at d^2 = 6370, in an unstable-sort order; all 16
    # are used here.
    r2 = min(rad * rad, 6370.0)
    m2 = t["min_range"] ** 2 if t["min_range"] >= 1.0 else -1.0
    R = int(math.sqrt(r2)) + 1
    out = []
    for dy in range(-R, R + 1):
        y = ty + dy
        if not w.xmin <= y <= w.xmax:
            continue
        for dx in range(-R, R + 1):
            d2 = dx * dx + dy * dy
            if d2 > r2 or d2 <= m2:
                continue
            x = tx + dx
            if not w.xmin <= x <= w.xmax:
                continue
            k = w.idx(x, y)
            if not w.imp[k] and los_clear(w, x, y, tx, ty):
                out.append(k)
    return out


def avoid_grid(w, sights):
    """45 per turret, capped at 255 (AvoidGrid.cs:108-118), then ExpandAvoidGridIntoEdifices: every edifice
    takes the highest value of its non-edifice neighbours (AvoidGrid.cs:120-138)."""
    per, cap = w.P["AVOID_PER_TURRET"], w.P["AVOID_CAP"]
    g = [0] * w.N
    for cells in sights:
        for k in cells:
            g[k] = min(cap, g[k] + per)
    out = list(g)
    W, edif = w.W, w.edif
    offs = (-W - 1, -W, -W + 1, -1, 1, W - 1, W, W + 1)
    for k in {k for cells in sights for k in cells}:
        v = g[k]
        if v and not edif[k]:
            for o in offs:
                kk = k + o
                if edif[kk] and out[kk] < v:
                    out[kk] = v
    return out


def known_traps(w, seed):
    """KnowsOfTrap for a smart lord: each trap is known with p = AvoidTrapRatio 0.3, decided once per faction
    and trap by a hash (Building_Trap.cs:174). Here: a fixed pseudo-random set per run seed."""
    chance = w.P["KNOWN_CHANCE"]
    out = set()
    for k in w.trap_cells:
        x, y = w.xy(k)
        if random.Random(f"trap:{seed}:{x}:{y}").random() < chance:
            out.add(k)
    return frozenset(out)


# --------------------------------------------------------------------------------------------- breach noise

_GRAD = [  # libnoise gradient table, Verse.Noise.Utils._randoms (Utils.cs:23-128), LGPL libnoise
    -.763874, -.596439, -.246489, .0, .396055, .904518, -.158073, .0, -.499004, -.8665, -.0131631, .0, .468724, -.824756, .316346, .0,
    .829598, .43195, .353816, .0, -.454473, .629497, -.630228, .0, -.162349, -.869962, -.465628, .0, .932805, .253451, .256198, .0,
    -.345419, .927299, -.144227, .0, -.715026, -.293698, -.634413, .0, -.245997, .717467, -.651711, .0, -.967409, -.250435, -.037451, .0,
    .901729, .397108, -.170852, .0, .892657, -.0720622, -.444938, .0, .0260084, -.0361701, .999007, .0, .949107, -.19486, .247439, .0,
    .471803, -.807064, -.355036, .0, .879737, .141845, .453809, .0, .570747, .696415, .435033, .0, -.141751, -.988233, -.0574584, .0,
    -.58219, -.0303005, .812488, .0, -.60922, .239482, -.755975, .0, .299394, -.197066, -.933557, .0, -.851615, -.220702, -.47544, .0,
    .848886, .341829, -.403169, .0, -.156129, -.687241, .709453, .0, -.665651, .626724, .405124, .0, .595914, -.674582, .43569, .0,
    .171025, -.509292, .843428, .0, .78605, .536414, -.307222, .0, .18905, -.791613, .581042, .0, -.294916, .844994, .446105, .0,
    .342031, -.58736, -.7335, .0, .57155, .7869, .232635, .0, .885026, -.408223, .223791, .0, -.789518, .571645, .223347, .0,
    .774571, .31566, .548087, .0, -.79695, -.0433603, -.602487, .0, -.142425, -.473249, -.869339, .0, -.0698838, .170442, .982886, .0,
    .687815, -.484748, .540306, .0, .543703, -.534446, -.647112, .0, .97186, .184391, -.146588, .0, .707084, .485713, -.513921, .0,
    .942302, .331945, .043348, .0, .499084, .599922, .625307, .0, -.289203, .211107, .9337, .0, .412433, -.71667, -.56239, .0,
    .87721, -.082816, .47291, .0, -.420685, -.214278, .881538, .0, .752558, -.0391579, .657361, .0, .0765725, -.996789, .0234082, .0,
    -.544312, -.309435, -.779727, .0, -.455358, -.415572, .787368, .0, -.874586, .483746, .0330131, .0, .245172, -.0838623, .965846, .0,
    .382293, -.432813, .81641, .0, -.287735, -.905514, .311853, .0, -.667704, .704955, -.239186, .0, .717885, -.464002, -.518983, .0,
    .976342, -.214895, .0240053, .0, -.0733096, -.921136, .382276, .0, -.986284, .151224, -.0661379, .0, -.899319, -.429671, .0812908, .0,
    .652102, -.724625, .222893, .0, .203761, .458023, -.865272, .0, -.030396, .698724, -.714745, .0, -.460232, .839138, .289887, .0,
    -.0898602, .837894, .538386, .0, -.731595, .0793784, .677102, .0, -.447236, -.788397, .422386, .0, .186481, .645855, -.740335, .0,
    -.259006, .935463, .240467, .0, .445839, .819655, -.359712, .0, .349962, .755022, -.554499, .0, -.997078, -.0359577, .0673977, .0,
    -.431163, -.147516, -.890133, .0, .299648, -.63914, .708316, .0, .397043, .566526, -.722084, .0, -.502489, .438308, -.745246, .0,
    .0687235, .354097, .93268, .0, -.0476651, -.462597, .885286, .0, -.221934, .900739, -.373383, .0, -.956107, -.225676, .186893, .0,
    -.187627, .391487, -.900852, .0, -.224209, -.315405, .92209, .0, -.730807, -.537068, .421283, .0, -.0353135, -.816748, .575913, .0,
    -.941391, .176991, -.287153, .0, -.154174, .390458, .90762, .0, -.283847, .533842, .796519, .0, -.482737, -.850448, .209052, .0,
    -.649175, .477748, .591886, .0, .885373, -.405387, -.227543, .0, -.147261, .181623, -.972279, .0, .0959236, -.115847, -.988624, .0,
    -.89724, -.191348, .397928, .0, .903553, -.428461, -.00350461, .0, .849072, -.295807, -.437693, .0, .65551, .741754, -.141804, .0,
    .61598, -.178669, .767232, .0, .0112967, .932256, -.361623, .0, -.793031, .258012, .551845, .0, .421933, .454311, .784585, .0,
    -.319993, .0401618, -.946568, .0, -.81571, .551307, -.175151, .0, -.377644, .00322313, .925945, .0, .129759, -.666581, -.734052, .0,
    .601901, -.654237, -.457919, .0, -.927463, -.0343576, -.372334, .0, -.438663, -.868301, -.231578, .0, -.648845, -.749138, -.133387, .0,
    .507393, -.588294, .629653, .0, .726958, .623665, .287358, .0, .411159, .367614, -.834151, .0, .806333, .585117, -.0864016, .0,
    .263935, -.880876, .392932, .0, .421546, -.201336, .884174, .0, -.683198, -.569557, -.456996, .0, -.117116, -.0406654, -.992285, .0,
    -.643679, -.109196, -.757465, .0, -.561559, -.62989, .536554, .0, .0628422, .104677, -.992519, .0, .480759, -.2867, -.828658, .0,
    -.228559, -.228965, -.946222, .0, -.10194, -.65706, -.746914, .0, .0689193, -.678236, .731605, .0, .401019, -.754026, .52022, .0,
    -.742141, .547083, -.387203, .0, -.00210603, -.796417, -.604745, .0, .296725, -.409909, -.862513, .0, -.260932, -.798201, .542945, .0,
    -.641628, .742379, .192838, .0, -.186009, -.101514, .97729, .0, .106711, -.962067, .251079, .0, -.743499, .30988, -.592607, .0,
    -.795853, -.605066, -.0226607, .0, -.828661, -.419471, -.370628, .0, .0847218, -.489815, -.8677, .0, -.381405, .788019, -.483276, .0,
    .282042, -.953394, .107205, .0, .530774, .847413, .0130696, .0, .0515397, .922524, .382484, .0, -.631467, -.709046, .313852, .0,
    .688248, .517273, .508668, .0, .646689, -.333782, -.685845, .0, -.932528, -.247532, -.262906, .0, .630609, .68757, -.359973, .0,
    .577805, -.394189, .714673, .0, -.887833, -.437301, -.14325, .0, .690982, .174003, .701617, .0, -.866701, .0118182, .498689, .0,
    -.482876, .727143, .487949, .0, -.577567, .682593, -.447752, .0, .373768, .0982991, .922299, .0, .170744, .964243, -.202687, .0,
    .993654, -.035791, -.106632, .0, .587065, .4143, -.695493, .0, -.396509, .26509, -.878924, .0, -.0866853, .83553, -.542563, .0,
    .923193, .133398, -.360443, .0, .00379108, -.258618, .965972, .0, .239144, .245154, -.939526, .0, .758731, -.555871, .33961, .0,
    .295355, .309513, .903862, .0, .0531222, -.91003, -.411124, .0, .270452, .0229439, -.96246, .0, .563634, .0324352, .825387, .0,
    .156326, .147392, .976646, .0, -.0410141, .981824, .185309, .0, -.385562, -.576343, -.720535, .0, .388281, .904441, .176702, .0,
    .945561, -.192859, -.262146, .0, .844504, .520193, .127325, .0, .0330893, .999121, -.0257505, .0, -.592616, -.482475, -.644999, .0,
    .539471, .631024, -.557476, .0, .655851, -.027319, -.754396, .0, .274465, .887659, .369772, .0, -.123419, .975177, -.183842, .0,
    -.223429, .708045, .66989, .0, -.908654, .196302, .368528, .0, -.95759, -.00863708, .288005, .0, .960535, .030592, .276472, .0,
    -.413146, .907537, .0754161, .0, -.847992, .350849, -.397259, .0, .614736, .395841, .68221, .0, -.503504, -.666128, -.550234, .0,
    -.268833, -.738524, -.618314, .0, .792737, -.60001, -.107502, .0, -.637582, .508144, -.579032, .0, .750105, .282165, -.598101, .0,
    -.351199, -.392294, -.850155, .0, .250126, -.960993, -.118025, .0, -.732341, .680909, -.0063274, .0, -.760674, -.141009, .633634, .0,
    .222823, -.304012, .926243, .0, .209178, .505671, .836984, .0, .757914, -.56629, -.323857, .0, -.782926, -.339196, .52151, .0,
    -.462952, .585565, .665424, .0, .61879, .194119, -.761194, .0, .741388, -.276743, .611357, .0, .707571, .702621, .0752872, .0,
    .156562, .819977, .550569, .0, -.793606, .440216, .42, .0, .234547, .885309, -.401517, .0, .132598, .80115, -.58359, .0,
    -.377899, -.639179, .669808, .0, -.865993, -.396465, .304748, .0, -.624815, -.44283, .643046, .0, -.485705, .825614, -.287146, .0,
    -.971788, .175535, .157529, .0, -.456027, .392629, .798675, .0, -.0104443, .521623, -.853112, .0, -.660575, -.74519, .091282, .0,
    -.0157698, -.307475, -.951425, .0, -.603467, -.250192, .757121, .0, .506876, .25006, .824952, .0, .255404, .966794, .00884498, .0,
    .466764, -.874228, -.133625, .0, .475077, -.0682351, -.877295, .0, -.224967, -.938972, -.260233, .0, -.377929, -.814757, -.439705, .0,
    -.305847, .542333, -.782517, .0, .26658, -.902905, -.337191, .0, .0275773, .322158, -.946284, .0, .0185422, .716349, .697496, .0,
    -.20483, .978416, .0273371, .0, -.898276, .373969, .230752, .0, -.00909378, .546594, .837349, .0, .6602, -.751089, .000959236, .0,
    .855301, -.303056, .420259, .0, .797138, .0623013, -.600574, .0, .48947, -.866813, .0951509, .0, .251142, .674531, .694216, .0,
    -.578422, -.737373, -.348867, .0, -.254689, -.514807, .818601, .0, .374972, .761612, .528529, .0, .640303, -.734271, -.225517, .0,
    -.638076, .285527, .715075, .0, .772956, -.15984, -.613995, .0, .798217, -.590628, .118356, .0, -.986276, -.0578337, -.154644, .0,
    -.312988, -.94549, .0899272, .0, -.497338, .178325, .849032, .0, -.101136, -.981014, .165477, .0, -.521688, .0553434, -.851339, .0,
    -.786182, -.583814, .202678, .0, -.565191, .821858, -.0714658, .0, .437895, .152598, -.885981, .0, -.92394, .353436, -.14635, .0,
    .212189, -.815162, -.538969, .0, -.859262, .143405, -.491024, .0, .991353, .112814, .0670273, .0, .0337884, -.979891, -.196654, .0,
]


def libnoise_cells(w, seed, freq=0.06581, lac=1.5516, pers=1.6569, octaves=4, thres=0.5):
    """Cells where BreachingGrid.WithinNoise is true (BreachingGrid.cs:275-293): Verse.Noise.Perlin with the
    breach tweak values (BreachingGrid.cs:218-230), QualityMode.Medium, sampled at (x, 0, z). Exact port of
    Perlin.GetValue and Utils.GradientCoherentNoise3D (Perlin.cs:148-186, Utils.cs:130-188, 198-219). With y = 0
    only the y = 0 lattice layer contributes, so four of the eight corners are evaluated."""
    freq, lac, pers, thres = f32(freq), f32(lac), f32(pers), f32(thres)
    n = w.n
    axis = []
    for v in range(n):
        c, row = v * freq, []
        for _ in range(octaves):
            i0 = int(c) if c > 0.0 else int(c) - 1
            t = c - i0
            row.append((i0, t * t * (3.0 - 2.0 * t), c))
            c *= lac
        axis.append(row)
    seeds = [1013 * ((seed + o) & 0xFFFFFFFF) for o in range(octaves)]
    amps, a = [], 1.0
    for _ in range(octaves):
        amps.append(a)
        a *= pers
    R = _GRAD
    out = set()
    for Z in range(n):
        az = axis[Z]
        y = w.xmax - Z                            # game z = n - 1 - (y + half)
        for X in range(n):
            ax = axis[X]
            total = 0.0
            for o in range(octaves):
                x0, px, fx = ax[o]
                z0, pz, fz = az[o]
                hb = 1619 * x0 + 6971 * z0 + seeds[o]
                h = hb & 0xFFFFFFFF
                h = (h ^ (h >> 8)) & 0xFF
                g00 = (R[h * 4] * (fx - x0) + R[h * 4 + 2] * (fz - z0)) * 2.12
                h = (hb + 1619) & 0xFFFFFFFF
                h = (h ^ (h >> 8)) & 0xFF
                g10 = (R[h * 4] * (fx - x0 - 1) + R[h * 4 + 2] * (fz - z0)) * 2.12
                h = (hb + 6971) & 0xFFFFFFFF
                h = (h ^ (h >> 8)) & 0xFF
                g01 = (R[h * 4] * (fx - x0) + R[h * 4 + 2] * (fz - z0 - 1)) * 2.12
                h = (hb + 8590) & 0xFFFFFFFF
                h = (h ^ (h >> 8)) & 0xFF
                g11 = (R[h * 4] * (fx - x0 - 1) + R[h * 4 + 2] * (fz - z0 - 1)) * 2.12
                lo = (1.0 - px) * g00 + px * g10
                hi = (1.0 - px) * g01 + px * g11
                total += ((1.0 - pz) * lo + pz * hi) * amps[o]
            if f32(total) >= thres:
                out.add(w.idx(X + w.xmin, y))
    return frozenset(out)


def audit_perlin_cells(w, seed, freq=0.06581, lac=1.5516, pers=1.6569, octaves=4, thres=0.5):
    """The audit's stand-in for the game noise (audit_sim/sim16.py perlin_cells): random unit gradients from
    random.Random(seed). Kept to reproduce the audit numbers (its seeds 1-3)."""
    rnd = random.Random(seed)
    grads = {}

    def grad(ix, iy, o):
        key = (ix, iy, o)
        if key not in grads:
            a = rnd.random() * 2 * math.pi
            grads[key] = (math.cos(a), math.sin(a))
        return grads[key]

    def noise(x, y, o):
        x0, y0 = math.floor(x), math.floor(y)
        fx, fy = x - x0, y - y0
        u = fx * fx * fx * (fx * (fx * 6 - 15) + 10)
        v = fy * fy * fy * (fy * (fy * 6 - 15) + 10)

        def dot(ix, iy):
            gx, gy = grad(ix, iy, o)
            return gx * (x - ix) + gy * (y - iy)
        n00, n10, n01, n11 = dot(x0, y0), dot(x0 + 1, y0), dot(x0, y0 + 1), dot(x0 + 1, y0 + 1)
        a = n00 + u * (n10 - n00)
        b = n01 + u * (n11 - n01)
        return (a + v * (b - a)) * 1.4

    out = set()
    half = w.half
    for y in range(-half, half):
        for x in range(-half, half):
            val, f, amp = 0.0, freq, 1.0
            for o in range(octaves):
                val += noise(x * f, y * f, o) * amp
                f *= lac
                amp *= pers
            if val >= thres:
                out.add(w.idx(x, y))
    return frozenset(out)


# ----------------------------------------------------------------------------------------------- path costs

Costs = collections.namedtuple("Costs", "cost blocked dblock card diag known")


def build_costs(w, mode, av=None, known=frozenset(), noise=frozenset()):
    """IndexCost of every cell for one raid type (PathFinderJob.cs:204-211), the impassable map
    (IndexCost >= 10000) and the diagonal-block map (PathFinderJob.cs:147-155: an impassable corner, a
    full-fill building or a fence - no raider can bash fences, TraverseParms.cs:56-65)."""
    Pm = w.P
    N = w.N
    cost = [0] * N
    blocked = bytearray(w.offmap)
    imp, door, full, hp, pcost, edif = w.imp, w.door, w.full, w.hp, w.pcost, w.edif
    if mode == "breach":
        # BreachingGrid.CreateBreachPath: pawn-less PassAllDestroyableThings request with the breach tuning
        # (BreachingGrid.cs:295-309); no avoid grid (PathFinder.cs:106-118), no trap costs (traps are cost
        # providers only for a pawn, PathGridDoorsBlockedJob.cs:58-70), 18 / 18 ticks (PathFinder.cs:731-735).
        bb, bph, bn = Pm["BREACH_BASE"], Pm["BREACH_PER_HP"], Pm["BREACH_NOISE"]
        for k in range(N):
            if blocked[k]:
                continue
            h = hp[k]
            c = bn if k in noise else 0                       # +30 on noise cells (BreachingGrid.cs:73-78)
            if edif[k] and h > 0:
                c += ushort_cost(bb, h, bph)                  # every destroyable edifice (BreachingGrid.cs:79-88)
            if imp[k]:
                if not (full[k] and h > 0):
                    blocked[k] = 1
                    continue
                c += grid_cost(bb, h, bph)                    # PathGridJob.cs:141 with the breach tuning
            else:
                c += pcost[k]
                if door[k]:
                    c = max(c, ushort_cost(bb, h, bph))       # door provider cost (PathUtility.cs:47-62)
            cost[k] = c
        card = diag = Pm["BREACH_STEP"]
    else:
        smart = mode in ("sapper", "smart_walker")
        dig = mode == "sapper"
        f = Pm["AVOID_FACTOR"] if smart else 0
        wb, wph, db, tk = Pm["WALL_BASE"], Pm["WALL_PER_HP"], Pm["DOOR_BASE"], Pm["TRAP_KNOWN"]
        for k in range(N):
            if blocked[k]:
                continue
            a = av[k] * f if f else 0
            if imp[k]:
                if not (dig and full[k] and hp[k] > 0):       # only full-fill destroyable buildings can be dug
                    blocked[k] = 1                            # (PathGridJob.cs:93-137)
                    continue
                c = grid_cost(wb, hp[k], wph) + a
            elif door[k]:
                if not dig:                                   # ByPawn, hostile, cannot bash (PathUtility.cs:73-90)
                    blocked[k] = 1
                    continue
                c = max(pcost[k] + a, ushort_cost(db, hp[k], wph))   # PathUtility.cs:62 uses the wall per-HP value
            else:
                c = pcost[k] + a
                if smart and k in known:
                    c = max(c, tk)                            # known trap: provider cost 800 (Building_Trap.cs:186-193)
            if c >= 10000:
                blocked[k] = 1
                continue
            cost[k] = c
        card, diag = Pm["CARD"], Pm["DIAG"]
    fence = w.fence
    dblock = bytearray(N)
    for k in range(N):
        if blocked[k] or full[k] or fence[k]:
            dblock[k] = 1
    return Costs(cost, blocked, dblock, card, diag, known)


# ------------------------------------------------------------------------------------------------ searches

def dijkstra(cost, blocked, dblock, W, src, card, diag):
    """Exact reverse search from src. dist[k] is the cheapest forward cost from k to src, paying the IndexCost
    of every cell entered plus the move ticks (PathFinderJob.cs:142-157); nxt[k] is the next cell toward src."""
    N = len(cost)
    dist = [INF] * N
    nxt = [-1] * N
    if blocked[src]:
        return dist, nxt
    dist[src] = 0
    heap = [(0, src)]
    pop, push = heapq.heappop, heapq.heappush
    while heap:
        d, e = pop(heap)
        if d != dist[e]:
            continue
        base = d + cost[e]
        nd = base + card
        for ni in (e - W, e + W, e + 1, e - 1):
            if nd < dist[ni] and not blocked[ni]:
                dist[ni] = nd
                nxt[ni] = e
                push(heap, (nd, ni))
        nd = base + diag
        if not dblock[e + 1]:
            if not dblock[e - W]:
                ni = e + 1 - W
                if nd < dist[ni] and not blocked[ni]:
                    dist[ni] = nd
                    nxt[ni] = e
                    push(heap, (nd, ni))
            if not dblock[e + W]:
                ni = e + 1 + W
                if nd < dist[ni] and not blocked[ni]:
                    dist[ni] = nd
                    nxt[ni] = e
                    push(heap, (nd, ni))
        if not dblock[e - 1]:
            if not dblock[e + W]:
                ni = e - 1 + W
                if nd < dist[ni] and not blocked[ni]:
                    dist[ni] = nd
                    nxt[ni] = e
                    push(heap, (nd, ni))
            if not dblock[e - W]:
                ni = e - 1 - W
                if nd < dist[ni] and not blocked[ni]:
                    dist[ni] = nd
                    nxt[ni] = e
                    push(heap, (nd, ni))
    return dist, nxt


def walk(nxt, s, t):
    cells = [s]
    while cells[-1] != t:
        cells.append(nxt[cells[-1]])
    return cells


def heuristic_strength(w, s, t, pawn=True):
    """PathFinder.DetermineHeuristicStrength (PathFinder.cs:588-608): 1 without a pawn, else for a non-colonist
    human RoundToInt of the curve 40 -> 1, 120 -> 2 over the start-target distance (PathFinder.cs:280-284)."""
    if not pawn:
        return 1.0
    (x0, y0), (x1, y1) = w.xy(s), w.xy(t)
    d = math.hypot(x1 - x0, y1 - y0)
    v = 1.0 if d <= 40 else (2.0 if d >= 120 else 1.0 + (d - 40) / 80.0)
    return float(round(v))                         # Mathf.RoundToInt rounds half to even, like round()


def astar(cost, blocked, dblock, W, s, t, strength, card, diag):
    """Verse.PathFinderJob.Execute (PathFinderJob.cs:90-202): f = g + h, h = octile * 13 * strength (set when a
    cell is first opened), closed cells are never reopened, neighbours in the game order N S E W NE SE SW NW.
    Returns (cells from s to t, cost) or (None, None)."""
    N = len(cost)
    st = bytearray(N)
    gc = [0] * N
    fc = [0.0] * N
    hc = [0.0] * N
    par = [-1] * N
    tx, ty = t % W, t // W
    st[s] = 1
    par[s] = s
    heap = [(0.0, 0, s)]
    seq = 1
    closed = 0
    nbrs = ((-W, card, 0, 0), (W, card, 0, 0), (1, card, 0, 0), (-1, card, 0, 0),
            (1 - W, diag, 1, -W), (1 + W, diag, 1, W), (W - 1, diag, -1, W), (-1 - W, diag, -1, -W))
    pop, push = heapq.heappop, heapq.heappush
    found = False
    while heap:
        f, _, e = pop(heap)
        if st[e] == 2 or f != fc[e]:
            continue
        if e == t:
            found = True
            break
        if closed >= N:
            break
        ge = gc[e]
        for o, step, c1, c2 in nbrs:
            ni = e + o
            if st[ni] == 2 or blocked[ni]:
                continue
            if c1 and (dblock[e + c1] or dblock[e + c2]):
                continue
            ng = ge + cost[ni] + step
            sn = st[ni]
            if sn == 1 and gc[ni] <= ng:
                continue
            if sn == 0:
                dx, dy = abs(tx - ni % W), abs(ty - ni // W)
                if dx or dy:
                    hc[ni] = ((dx + dy) - 0.58579004 * (dx if dx < dy else dy)) * 13.0 * strength
            nf = ng + hc[ni]
            gc[ni], fc[ni], par[ni], st[ni] = ng, nf, e, 1
            push(heap, (nf, seq, ni))
            seq += 1
        closed += 1
        st[e] = 2
    if not found:
        return None, None
    path = [t]
    while path[-1] != s:
        path.append(par[path[-1]])
    path.reverse()
    return path, gc[t]


def sapper_loop(w, ct, av, s, t, replan_ticks, max_jobs=400):
    """JobGiver_AISapper (JobGiver_AISapper.cs:26-62): path from the current cell, break the first blocking
    building (PawnPathUtility.cs:8-53), re-path; while walking the Goto job expires after replan_ticks.
    A broken cell keeps its old avoid value (the game would regenerate the avoid grid)."""
    cost, blocked, dblock = ct.cost, ct.blocked, ct.dblock
    W, fac = w.W, w.P["AVOID_FACTOR"]
    cardinal = (1, -1, W, -W)
    pos, visited, broken, changed = s, [s], [], []
    gone = set()
    arrived = False
    for _ in range(max_jobs):
        path, _ = astar(cost, blocked, dblock, W, pos, t, heuristic_strength(w, pos, t), ct.card, ct.diag)
        if path is None:
            break
        blk = next((i for i in range(1, len(path)) if w.solid[path[i]] and path[i] not in gone), None)
        end = blk - 1 if blk is not None else len(path) - 1
        ticks, i = 0, 0
        while i < end and ticks < replan_ticks:
            a, b = path[i], path[i + 1]
            ticks += (ct.card if (b - a) in cardinal else ct.diag) + w.pcost[b]
            i += 1
            visited.append(b)
        pos = path[i]
        if blk is None and i == end:
            arrived = True
            break
        if blk is not None and i == end:
            k = path[blk]
            broken.append(k)
            gone.add(k)
            changed.append((k, cost[k], blocked[k], dblock[k]))
            cost[k], blocked[k], dblock[k] = av[k] * fac, 0, w.fence[k]
    for k, c, b, d in reversed(changed):
        cost[k], blocked[k], dblock[k] = c, b, d
    return visited, broken, arrived


def label_areas(blocked, dblock, W):
    """Number the areas a walker can move in: area[k] for every open cell, -1 for blocked ones. Moves are the
    search's own (8-connected, a diagonal needs both corner cells free), and they are symmetric, so two cells
    share an area exactly when a walker can go from one to the other."""
    N = len(blocked)
    area = [-1] * N
    n = 0
    for k0 in range(N):
        if blocked[k0] or area[k0] >= 0:
            continue
        area[k0] = n
        stack = [k0]
        while stack:
            e = stack.pop()
            cand = [e - W, e + W, e + 1, e - 1]
            if not dblock[e + 1]:
                if not dblock[e - W]:
                    cand.append(e + 1 - W)
                if not dblock[e + W]:
                    cand.append(e + 1 + W)
            if not dblock[e - 1]:
                if not dblock[e + W]:
                    cand.append(e - 1 + W)
                if not dblock[e - W]:
                    cand.append(e - 1 - W)
            for ni in cand:
                if area[ni] < 0 and not blocked[ni]:
                    area[ni] = n
                    stack.append(ni)
        n += 1
    return area


# ------------------------------------------------------------------------------------------ classification

def crossing_kind(before, after, run, postern):
    """What a run of broken cells crossed, from the zones on either side."""
    if any(r in postern for r in run):
        return "postern"
    if before == Z_CASTLE and after == Z_CASTLE:
        return "internal"
    if Z_CASTLE in (before, after):
        return "castle"
    if (before in OUTER_SIDE) != (after in OUTER_SIDE):
        return "curtain"
    if before in (Z_LANE, Z_BLOCK) or after in (Z_LANE, Z_BLOCK):
        return "trapblock"
    if {before, after} == {Z_YARD, Z_COURT}:
        return "courtwall"
    return "other"


def classify(w, cells, broken, known=frozenset()):
    """Name the route: how the path got past the outer defence and into the castle."""
    zone, post = w.zone, w.postern
    z = zone[cells[0]]
    outer = "inside" if z in INNER_SIDE else None
    inner = "inside" if z in (Z_HOLE, Z_CASTLE) else None
    cur, run, kinds = z, [], set()
    tb, lane_seen = False, z == Z_LANE
    first_break = castle_break = None
    seen = {cells[0]}
    for k in cells[1:]:
        if k in broken or zone[k] == Z_SOLID:
            if first_break is None and k in broken:
                first_break = k
            run.append(k)
            continue
        z, prev = zone[k], cur
        if run:
            kind = crossing_kind(prev, z, run, post)
            kinds.add(kind)
            if kind == "trapblock":
                tb = True
        if outer is None and prev not in INNER_SIDE and z in INNER_SIDE:
            if run:
                outer = "postern" if any(r in post for r in run) else ("curtain" if z != Z_CASTLE else "none")
            elif prev == Z_GAP:
                outer = "trapblock" if tb else ("lane" if lane_seen else "gategap")
            else:
                outer = "none"
        if inner is None and z in (Z_HOLE, Z_CASTLE) and prev not in (Z_HOLE, Z_CASTLE):
            inner = "hole" if z == Z_HOLE else ("wall" if run else "gap")
            if inner == "wall":
                castle_break = run[-1]
        if z == Z_LANE:
            lane_seen = True
        run, cur = [], z
        seen.add(k)
    outer, inner = outer or "none", inner or "none"
    if not w.route_zones:       # no zone features: a wall into enclosed open ground is not known to be a curtain
        outer = "unlabelled" if outer == "curtain" else outer
        kinds = {"unlabelled" if kind == "curtain" else kind for kind in kinds}
    trap, fence = w.trap, w.fence

    def where(k):
        return None if k is None else (*w.xy(k), S_NAME[w.struct[k]])
    return {"outer": outer, "inner": inner, "route": f"{outer}>{inner}", "broke": kinds,
            "first_break": where(first_break), "castle_break": where(castle_break),
            "broken": [where(k) for k in dict.fromkeys(k for k in cells if k in broken)],
            "lane": sum(1 for k in seen if zone[k] == Z_LANE), "traps": sum(1 for k in seen if trap[k]),
            "known_traps": sum(1 for k in seen if trap[k] and k in known),
            "fences": sum(1 for k in seen if fence[k])}


def summarize(o):
    recs = o["recs"]
    n = len(recs)
    s = {"paths": n, "unreachable": o["unreachable"]}
    if o.get("known") is not None:
        s["traps_known"] = list(o["known"])               # [traps this smart lord knows, traps on the map]
    if o.get("not_arrived"):
        s["did_not_arrive"] = o["not_arrived"]
    if not n:
        return s
    stand = collections.Counter(r["stand_in"] for r in recs if r.get("stand_in"))
    if stand:                                             # walkers sealed off from their bed
        s["to_bed"] = n - sum(stand.values())
        s["stand_in"] = sum(stand.values())
        s["stand_in_cells"] = [[*c, v] for c, v in stand.most_common(6)]

    def pct(c):
        return round(100.0 * c / n, 1)
    s["castle_entry_pct"] = {k: pct(v) for k, v in collections.Counter(r["inner"] for r in recs).most_common()}
    s["outer_route_pct"] = {k: pct(v) for k, v in collections.Counter(r["outer"] for r in recs).most_common()}
    s["route_pct"] = {k: pct(v) for k, v in collections.Counter(r["route"] for r in recs).most_common()}
    s["broke_pct"] = {kind: pct(sum(1 for r in recs if kind in r["broke"])) for kind in BROKE_ORDER}
    s["through_hole_pct"] = s["castle_entry_pct"].get("hole", 0.0)
    margins = [r["margin"] for r in recs if "margin" in r]
    if margins:
        finite = sorted(m for m in margins if m != math.inf)
        s["margin"] = {"paths": len(margins), "min": round(finite[0], 3) if finite else None,
                       "median": round(finite[len(finite) // 2], 3) if finite else None,
                       "no_other_way": sum(1 for m in margins if m == math.inf)}
    for key, name in (("lane", "lane_tiles"), ("traps", "traps_on_path"), ("known_traps", "known_traps_on_path"),
                      ("fences", "fences_on_path")):
        vals = [r[key] for r in recs]
        s[name] = [min(vals), max(vals), round(sum(vals) / n, 2)]
    s["lane_tiles_min_max"] = s["lane_tiles"][:2]
    s["first_break"] = [[*c, v] for c, v in collections.Counter(r["first_break"] for r in recs
                                                              if r["first_break"]).most_common(6)]
    s["castle_broken_at"] = [[*c, v] for c, v in collections.Counter(r["castle_break"] for r in recs
                                                                   if r["castle_break"]).most_common(6)]
    s["most_broken"] = [[*c, v] for c, v in collections.Counter(c for r in recs for c in r["broken"]).most_common(6)]
    over = [r["cost"] / r["best"] for r in recs if r.get("cost") is not None and r.get("best")]
    if over and any(abs(v - 1.0) > 1e-9 for v in over):
        s["astar_cost_over_best"] = [round(min(over), 3), round(sum(over) / len(over), 3), round(max(over), 3)]
    return s


def fmt_margin(m):
    if not m:
        return ""
    if m["min"] is None:
        return " [no other way in]"
    txt = f" [margin x{m['min']:.2f} min, x{m['median']:.2f} median"
    if m["no_other_way"]:
        txt += f", {m['no_other_way']} with no other way"
    return txt + "]"


def print_summary(label, group, s, n_spawns, n_targets, hole=True):
    head = f"{label} | {group} {n_spawns} spawns x {n_targets} targets: {s['paths']} paths"
    if s.get("stand_in"):
        head += f" ({s['to_bed']} reach the bed)"
    if s["unreachable"]:
        head += f", {s['unreachable']} unreachable"
    if s.get("did_not_arrive"):
        head += f", {s['did_not_arrive']} did not arrive"
    if s.get("traps_known") and s["traps_known"][1]:
        head += f"; knows {s['traps_known'][0]} of {s['traps_known'][1]} traps"
    print(head)
    if not s["paths"]:
        return
    if s.get("stand_in"):
        print(f"    sealed off   : {s['stand_in']} of {s['paths']} paths cannot reach the bed and end at the closest"
              " cell they can reach: " + ", ".join(f"({x},{y}) x{v}" for x, y, v in s["stand_in_cells"]))
    ce, orr = s["castle_entry_pct"], s["outer_route_pct"]
    parts = []
    if hole or "hole" in ce:                              # plans without a hole zone skip the 0% hole entry
        parts.append(f"{INNER_LABEL['hole']} {ce.get('hole', 0.0)}%{fmt_margin(s.get('margin'))}")
    parts += [f"{INNER_LABEL[k]} {v}%" for k, v in ce.items() if k != "hole"]
    print("    castle entry : " + " | ".join(parts))
    print("    outer route  : " + " | ".join(f"{OUTER_LABEL[k]} {v}%" for k, v in orr.items()))
    print("    routes       : " + ", ".join(f"{k} {v}%" for k, v in list(s["route_pct"].items())[:6]))
    broke = [f"{BROKE_LABEL[k]} {v}%" for k, v in s["broke_pct"].items() if v]
    print("    broke        : " + (" | ".join(broke) if broke else "nothing"))
    lt, tr, kt, fe = s["lane_tiles"], s["traps_on_path"], s["known_traps_on_path"], s["fences_on_path"]
    # a trap known to a raider of another faction never springs for him (Building_Trap.cs:117-142)
    known = f", {kt[2]} of them known and harmless" if kt[1] else ""
    print(f"    on the path  : lane tiles {lt[0]}-{lt[1]} (mean {lt[2]}) | traps {tr[0]}-{tr[1]} (mean {tr[2]}{known})"
          f" | fences {fe[0]}-{fe[1]}")
    if s["first_break"]:
        print("    first break  : " + ", ".join(f"({x},{y}) {k} x{v}" for x, y, k, v in s["first_break"]))
    if s["most_broken"]:
        print("    most broken  : " + ", ".join(f"({x},{y}) {k} x{v}" for x, y, k, v in s["most_broken"]))
    if s["castle_broken_at"]:
        print("    castle broken: " + ", ".join(f"({x},{y}) {k} x{v}" for x, y, k, v in s["castle_broken_at"]))
    if s.get("astar_cost_over_best"):
        a = s["astar_cost_over_best"]
        print(f"    A* cost / optimal: min {a[0]}, mean {a[1]}, max {a[2]}")


# ------------------------------------------------------------------------------------------------- runner

def spawn_groups(w, names, step):
    groups = collections.OrderedDict()
    zones = {"yard": Z_YARD, "court": Z_COURT, "lane": Z_LANE, "inside": Z_CASTLE}
    for name in names:
        if name == "edge":
            cells = [k for k in w.edge_cells(step) if not w.solid[k]]
        else:
            z = zones[name]
            cells = [k for k in range(w.N) if w.zone[k] == z][::max(1, step)]
        if cells:
            groups[name] = cells
        else:
            w.notes.append(f"spawn group {name!r} is empty at phase {w.phase}: skipped")
    return groups


class Sim:
    def __init__(self, world, opts):
        self.w = world
        self.o = opts
        self.sights = [turret_sight(world, t) for t in world.turrets]
        self.av = avoid_grid(world, self.sights)
        seeds = range(opts["seed"], opts["seed"] + max(1, opts["seeds"]))
        self.known_sets = [(s, known_traps(world, s)) for s in seeds]
        self.entry = set()
        for kind in [k for k in opts["entry"].split(",") if k]:
            self.entry.update(world.idx(x, y) for (x, y) in world.feats.get(kind, []))
        self.paths = collections.defaultdict(list)
        self._areas = {}

    def areas(self, ct):
        """Walker areas of one cost table (cached): the area of every cell, the cells of each area and the
        castle and hole cells of each area, plus a cache of stand-in targets."""
        key = (bytes(ct.blocked), bytes(ct.dblock))
        if key not in self._areas:
            zone = self.w.zone
            area = label_areas(ct.blocked, ct.dblock, self.w.W)
            cells, castle = collections.defaultdict(list), collections.defaultdict(list)
            for k, a in enumerate(area):
                if a >= 0:
                    cells[a].append(k)
                    if zone[k] in (Z_CASTLE, Z_HOLE):
                        castle[a].append(k)
            self._areas[key] = (area, cells, castle, {})
        return self._areas[key]

    def stand_in(self, ct, s, t):
        """Where a walker spawned at s heads when the raid targets bed t: the bed itself when s's area holds it,
        else the cell of s's own area closest to the bed, a castle cell if the area has one (where the walkers
        meet the defenders). None when s is blocked for this raid type."""
        area, cells, castle, cache = self.areas(ct)
        a = area[s]
        if a < 0:
            return None
        if area[t] == a:
            return t
        if (a, t) not in cache:
            W = self.w.W
            bx, by = t % W, t // W
            cache[(a, t)] = min(castle.get(a) or cells[a], key=lambda k: ((k % W - bx) ** 2 + (k // W - by) ** 2, k))
        return cache[(a, t)]

    def sealing_check(self, targets):
        """Flood fill on the walker grid (walls and closed doors block) from the whole map edge: which zones and
        rooms a walker reaches without opening a door, how many beds, and where the sealed-off ones send them."""
        w = self.w
        ct = build_costs(w, "walker")
        area, cells, _, _ = self.areas(ct)
        edge = sorted({area[k] for k in w.edge_cells() if area[k] >= 0})
        reached = [k for a in edge for k in cells[a]]
        zc = collections.Counter(w.zone[k] for k in reached)
        rooms = collections.Counter(w.room[k] for k in reached if w.zone[k] == Z_CASTLE)
        subs = {self.stand_in(ct, cells[a][0], t) for a in edge for _, t in targets if area[t] != a}
        return {"reachable_by_zone": {ZONE_NAME[z]: c for z, c in sorted(zc.items())},
                "castle_rooms_reached": dict(rooms.most_common()),
                "beds_reachable": sum(1 for _, t in targets if area[t] in edge), "beds": len(targets),
                "walker_stand_in_targets": sorted({w.xy(k) for k in subs})}

    def noise_variants(self):
        out, seen = [], set()
        for tok in [t.strip() for t in self.o["noise_seeds"].split(",") if t.strip()]:
            if tok in ("none", "off") or self.o["noise"] == "off":
                name, cells = "none", frozenset()
            else:
                seed = int(tok)
                name = str(seed)
                make = libnoise_cells if self.o["noise"] == "libnoise" else audit_perlin_cells
                cells = make(self.w, seed)
            if name not in seen:
                seen.add(name)
                out.append((name, cells))
        return out

    def run(self, label, mode, ct, groups, targets):
        """A path from every spawn to every target bed. Diggers path to the bed; walkers to the cell stand_in
        picks for their own spawn. One reverse search per distinct target cell, in the order first needed."""
        w, o = self.w, self.o
        smart = mode in ("sapper", "smart_walker")
        res = {g: {"recs": [], "unreachable": 0, "not_arrived": 0,
                   "known": (len(ct.known), len(w.trap_cells)) if smart else None} for g in groups}
        closed = self.entry if (o["margin"] and self.entry) else None
        if closed:
            b2, d2 = bytearray(ct.blocked), bytearray(ct.dblock)
            for k in closed:
                b2[k] = d2[k] = 1
        dig = mode in DIGGERS
        replan = o["replan"] and mode == "sapper"
        forward = o["astar"] or replan
        jobs = collections.OrderedDict()          # target cell -> [(bed key, bed cell, group, spawn)]
        for key, t in targets:
            if dig and ct.blocked[t]:
                w.notes.append(f"{label}: target {key} at {w.xy(t)} is impassable for this raid type")
                for g in groups:
                    res[g]["unreachable"] += len(groups[g])
                continue
            for g, spawns in groups.items():
                for s in spawns:
                    tt = t if dig else self.stand_in(ct, s, t)
                    if tt is None:
                        res[g]["unreachable"] += 1
                    else:
                        jobs.setdefault(tt, []).append((key, t, g, s))
        total = len(targets) * sum(len(v) for v in groups.values())
        stride = max(1, total // max(1, o["png_paths"])) if o["png"] else 0
        count = 0
        for tt, items in jobs.items():
            dist, nxt = dijkstra(ct.cost, ct.blocked, ct.dblock, w.W, tt, ct.card, ct.diag)
            dist2 = None
            if closed and tt not in closed:
                dist2 = dijkstra(ct.cost, b2, d2, w.W, tt, ct.card, ct.diag)[0]
            for key, t, g, s in items:
                r_out = res[g]
                if dist[s] >= INF:
                    r_out["unreachable"] += 1
                    continue
                pc = dist[s]
                if replan:
                    cells, broken, arrived = sapper_loop(w, ct, self.av, s, tt, o["replan_ticks"])
                    r_out["not_arrived"] += not arrived
                    pc = None
                elif forward:
                    strength = heuristic_strength(w, s, tt, pawn=(mode != "breach"))
                    cells, pc = astar(ct.cost, ct.blocked, ct.dblock, w.W, s, tt, strength, ct.card, ct.diag)
                    if cells is None:
                        r_out["unreachable"] += 1
                        continue
                    broken = [k for k in cells if w.solid[k]] if dig else []
                else:
                    cells = walk(nxt, s, tt)
                    broken = [k for k in cells if w.solid[k]] if dig else []
                r = classify(w, cells, set(broken), ct.known)
                r["key"], r["cost"], r["best"] = key, pc, dist[s]
                r["stand_in"] = None if tt == t else w.xy(tt)
                if dist2 is not None and r["inner"] == "hole" and s not in closed and dist[s] > 0:
                    r["margin"] = dist2[s] / dist[s] if dist2[s] < INF else math.inf
                r_out["recs"].append(r)
                if stride and count % stride == 0:
                    self.paths[label].append([w.xy(k) for k in cells])
                count += 1
        return res


def turret_scenarios(base, opts):
    """Turrets to remove: each ring turret alone (--kill-each) and every pair of neighbours by angle around
    the plan centre (--kill-pairs). Ring turrets: at least half as far out as the farthest turret."""
    ts = sorted(base.turrets, key=lambda t: math.atan2(-t["pos"][1], t["pos"][0]))
    if not ts:
        return []
    rmax = max(math.hypot(*t["pos"]) for t in ts)
    ring = [t["pos"] for t in ts if math.hypot(*t["pos"]) >= 0.5 * rmax]
    scen = []
    if opts["kill_each"]:
        scen += [[p] for p in ring]
    if opts["kill_pairs"]:
        if len(ring) >= 3:
            scen += [[ring[i], ring[(i + 1) % len(ring)]] for i in range(len(ring))]
        elif len(ring) == 2:
            scen.append(list(ring))
    return scen


def parse_cells(text):
    return [tuple(int(v) for v in p.split(",")) for p in (text or "").split(";") if p.strip()]


def parse_args(argv):
    o = {"map": 250, "step": 10, "phase": 99, "params": None, "png": None, "out": None,
         "modes": "sapper,breach,walker,smart_walker", "seeds": 1, "seed": 0, "noise": "libnoise",
         "noise_seeds": "none,0,1,2,3", "spawns": "edge", "kill": "", "kill_pairs": False, "kill_each": False,
         "astar": False, "replan": False, "replan_ticks": None, "beds": None, "entry": "hole,court",
         "margin": True, "png_paths": 300}
    valued = {"--map": ("map", int), "--step": ("step", int), "--phase": ("phase", int), "--params": ("params", str),
              "--png": ("png", str), "--out": ("out", str), "--modes": ("modes", str), "--seeds": ("seeds", int),
              "--seed": ("seed", int), "--noise": ("noise", str), "--noise-seeds": ("noise_seeds", str),
              "--spawns": ("spawns", str), "--kill": ("kill", str), "--replan-ticks": ("replan_ticks", int),
              "--beds": ("beds", str), "--entry": ("entry", str), "--png-paths": ("png_paths", int)}
    flags = {"--kill-pairs": ("kill_pairs", True), "--kill-each": ("kill_each", True), "--astar": ("astar", True),
             "--replan": ("replan", True), "--no-margin": ("margin", False)}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in valued:
            if i + 1 >= len(argv):
                raise SystemExit(f"{a} needs a value")
            key, typ = valued[a]
            o[key] = typ(argv[i + 1])
            i += 2
        elif a in flags:
            key, val = flags[a]
            o[key] = val
            i += 1
        else:
            raise SystemExit(f"unknown option {a!r} (see --help)")
    if o["noise"] not in ("libnoise", "audit", "off"):
        raise SystemExit("--noise must be libnoise, audit or off")
    return o


def parse_modes(text, notes):
    out = []
    for m in [m.strip() for m in text.split(",") if m.strip()]:
        if m == "smart_breach":
            notes.append("smart_breach runs as breach: in 1.6 the breach line is a pawn-less path request, so the "
                         "avoid grid and known traps never reach it (BreachingGrid.cs:308-309, PathFinder.cs:106-118, "
                         "PathFinderMapData.cs:366); only the escorts walk with the avoid grid")
            m = "breach"
        if m not in ("sapper", "breach", "walker", "smart_walker"):
            raise SystemExit(f"unknown mode {m!r}")
        if m not in out:
            out.append(m)
    return out


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return None
    plan_path = argv[0]
    o = parse_args(argv[1:])
    params = dict(P)
    if o["params"]:
        params.update(json.load(open(o["params"], encoding="utf-8")))
    if o["replan_ticks"] is None:
        o["replan_ticks"] = params["REPLAN_TICKS"]
    if o["replan"]:
        o["astar"] = True
    t0 = time.time()
    plan = json.load(open(plan_path, encoding="utf-8"))
    w = World(plan, o["map"], o["phase"], params, parse_cells(o["kill"]))
    modes = parse_modes(o["modes"], w.notes)
    names = ["edge", "yard", "court", "lane", "inside"] if o["spawns"] == "all" else \
        [s.strip() for s in o["spawns"].split(",") if s.strip()]
    for s in names:
        if s not in ("edge", "yard", "court", "lane", "inside"):
            raise SystemExit(f"unknown spawn group {s!r}")
    sim = Sim(w, o)
    groups = spawn_groups(w, names, o["step"])
    beds = w.beds
    if not beds and w.all_beds:
        w.notes.append(f"no owned bed is built by phase {o['phase']} ({w.bed_source}): targeting the planned "
                       "bed spots anyway")
        beds = w.beds = list(w.all_beds)
    if not beds:
        raise SystemExit(f"no owned beds to target at phase {o['phase']} (bed source: {w.bed_source})")
    if o["beds"]:
        keep = set(o["beds"].split(","))
        picked = [b for b in beds if b[0] in keep]
        if not picked:
            raise SystemExit(f"--beds {o['beds']}: no such bed; the {w.bed_source} are {[b[0] for b in beds]}")
        beds = picked
    targets = [(key, w.idx(*c)) for key, c, _ in beds]
    sim.sealing = sim.sealing_check(targets)

    tdefs = collections.Counter(t["def"] for t in w.turrets)
    print(f"sim_raids.py: {plan_path} at phase {o['phase']}, {w.n}x{w.n} map, RimWorld 1.6 path rules")
    print(f"  targets : {len(targets)} owned beds ({w.bed_source})")
    print(f"  turrets : {len(w.turrets)} ({', '.join(f'{d} x{c}' for d, c in tdefs.items()) or 'none'})"
          + (f", removed {w.killed}" if w.killed else ""))
    guessed = sorted({t["def"] for t in w.turrets if t.get("guess")})
    if guessed:
        print(f"            range {params['TURRET_RANGE']} assumed for {', '.join(guessed)}")
    print(f"  traps   : {len(w.trap_cells)}; smart lords know "
          + ", ".join(f"{len(k)} (trap seed {s})" for s, k in sim.known_sets) + f", chance {params['KNOWN_CHANCE']}")
    print("  spawns  : " + ", ".join(f"{g} {len(v)}" for g, v in groups.items()) + f" (step {o['step']})")
    if "breach" in modes:
        print(f"  noise   : {o['noise']}, breach runs: {o['noise_seeds']}")
    if not w.route_zones:
        print(f"  routes  : no route zones ({', '.join(ROUTE_ZONES)}) at phase {o['phase']}: the outer wall a raider"
              " breaks is printed as unlabelled")
    sl = sim.sealing
    print("sealing (walkers; walls and closed doors block): from the map edge a walker reaches "
          + " | ".join(f"{z} {c}" for z, c in sl["reachable_by_zone"].items())
          + f" | owned beds {sl['beds_reachable']} of {sl['beds']}")
    if sl["castle_rooms_reached"]:
        print("    castle rooms reached: " + ", ".join(f"{r} {c}" for r, c in sl["castle_rooms_reached"].items()))
    if sl["walker_stand_in_targets"]:
        print(f"    sealed beds: walkers from the edge end at the closest cell they reach, "
              f"{sl['walker_stand_in_targets'][:6]}")
    print()

    report = {"plan": plan_path, "phase": o["phase"], "map": w.n, "model": "RimWorld 1.6 (decompiled 1.6.9371)",
              "params": params, "options": {k: v for k, v in o.items()}, "targets": [[k, *w.xy(t)] for k, t in targets],
              "bed_source": w.bed_source, "turrets": [{"def": t["def"], "pos": list(t["pos"])} for t in w.turrets],
              "killed": [list(c) for c in w.killed], "traps": len(w.trap_cells),
              "known_traps": {str(s): sorted(list(w.xy(k)) for k in kn) for s, kn in sim.known_sets},
              "spawns": {g: len(v) for g, v in groups.items()}, "sealing": sl, "modes": {}, "notes": w.notes}

    def emit(label, mode, ct, tg):
        res = sim.run(label, mode, ct, groups, tg)
        out = {}
        for g, r in res.items():
            s = summarize(r)
            out[g] = s
            print_summary(label, g, s, len(groups[g]), len(tg), hole="hole" in w.route_zones)
        report["modes"][label] = out
        return out

    for mode in modes:
        if mode == "breach":
            spread = collections.defaultdict(list)
            for name, cells in sim.noise_variants():
                ct = build_costs(w, "breach", noise=cells)
                label = f"breach noise {name}"
                if cells:
                    frac = round(len(cells) / (w.n * w.n), 3)
                    report.setdefault("noise_cell_fraction", {})[name] = frac
                    print(f"breach noise {name}: noise covers {100 * frac:.1f}% of the map")
                out = emit(label, "breach", ct, targets)
                for g, s in out.items():
                    if s["paths"]:
                        spread[g].append(s)
            for g, ss in spread.items():
                if len(ss) > 1:
                    def rng(f):
                        vals = [f(s) for s in ss]
                        return f"{min(vals)}-{max(vals)}%"
                    parts = [f"hole {rng(lambda s: s['through_hole_pct'])}"] if "hole" in w.route_zones else []
                    outer = [k for k in OUTER_LABEL if k != "inside" and any(k in s["outer_route_pct"] for s in ss)]
                    parts += [f"{OUTER_LABEL[k].split(' (')[0]} {rng(lambda s, k=k: s['outer_route_pct'].get(k, 0.0))}"
                              for k in outer]
                    parts.append(f"castle side wall {rng(lambda s: s['castle_entry_pct'].get('wall', 0.0))}")
                    print(f"breach spread | {g} over {len(ss)} noise runs: " + " | ".join(parts))
        elif mode == "walker":
            emit("walker", "walker", build_costs(w, "walker"), targets)
        else:
            for seed, known in sim.known_sets:
                label = mode if len(sim.known_sets) == 1 else f"{mode} trap seed {seed}"
                ct = build_costs(w, mode, sim.av, known)
                emit(label, mode, ct, targets)
        print()

    scen = turret_scenarios(w, o)
    if scen:
        print(f"turret loss (sapper, trap seed {o['seed']}): {len(scen)} cases")
        rows = []
        for kill in scen:
            w2 = World(plan, o["map"], o["phase"], params, list(w.kill) + kill)
            sim2 = Sim(w2, dict(o, png=None))
            g2 = spawn_groups(w2, names, o["step"])
            ct = build_costs(w2, "sapper", sim2.av, sim2.known_sets[0][1])
            res = sim2.run("sapper", "sapper", ct, g2, targets)   # same map size: the same cells and beds
            for g, r in res.items():
                s = summarize(r)
                if not s["paths"]:
                    continue
                m = (s.get("margin") or {}).get("min")
                rows.append((kill, g, s, m))
                where = " + ".join(f"({x},{y})" for x, y in kill)
                print(f"    killed {where:<22} {g:<6} hole {s['through_hole_pct']:5.1f}%"
                      f"  margin min {('x%.2f' % m) if m else '-':>6}  routes "
                      + ", ".join(f"{k} {v}%" for k, v in list(s["route_pct"].items())[:3]))
        if rows:
            worst = min(rows, key=lambda r: (r[2]["through_hole_pct"], r[3] if r[3] else 0.0))
            print(f"    worst: killed {' + '.join(f'({x},{y})' for x, y in worst[0])} ({worst[1]}): hole "
                  f"{worst[2]['through_hole_pct']}%, outer route {worst[2]['outer_route_pct']}")
        report["turret_loss"] = [{"killed": [list(c) for c in k], "spawns": g, **s} for k, g, s, _ in rows]
        print()

    for note in w.notes:
        print("note:", note)
    out_path = o["out"] or plan_path.rsplit(".", 1)[0] + "_sim.json"
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump({"report": report, "cover": None}, fh, ensure_ascii=False, default=list)
    if o["png"]:
        draw(w, sim.av, sim.paths, o["png"])
    print(f"wrote {out_path} in {time.time() - t0:.0f} s")
    return report


def draw(w, av, paths, out_png):
    from PIL import Image, ImageDraw
    T = 4
    img = Image.new("RGB", (w.n * T, w.n * T), (214, 199, 168))
    d = ImageDraw.Draw(img)
    for y in range(w.xmin, w.xmax + 1):
        for x in range(w.xmin, w.xmax + 1):
            k = w.idx(x, y)
            s = w.struct[k]
            px, py = (x - w.xmin) * T, (y - w.xmin) * T
            color = None
            if s in (S_WALL, S_DIAG):
                color = (70, 74, 80)
            elif s == S_DOOR:
                color = (214, 150, 44)
            elif s == S_BLOCK:
                color = (120, 110, 100)
            elif w.trap[k]:
                color = (150, 40, 40)
            elif w.fence[k]:
                color = (140, 110, 70)
            elif s == S_THING:
                color = (175, 168, 150)
            elif av[k]:
                shade = max(120, 214 - 30 * (av[k] // 45))
                color = (214, shade, shade)
            if color:
                d.rectangle([px, py, px + T - 1, py + T - 1], fill=color)
    colors = {"sapper": (30, 60, 200), "breach": (200, 40, 40), "walker": (20, 140, 60), "smart_walker": (0, 150, 150)}
    for label, plist in paths.items():
        c = colors.get(label.split()[0], (0, 0, 0))
        for cells in plist:
            pts = [((x - w.xmin) * T + T // 2, (y - w.xmin) * T + T // 2) for (x, y) in cells]
            if len(pts) > 1:
                d.line(pts, fill=c, width=1)
    for t in w.turrets:
        x, y = t["pos"]
        px, py = (x - w.xmin) * T, (y - w.xmin) * T
        d.rectangle([px - 2, py - 2, px + T + 1, py + T + 1], outline=(0, 0, 0))
    img.save(out_png)
    print("saved", out_png)


if __name__ == "__main__":
    main(sys.argv[1:])
