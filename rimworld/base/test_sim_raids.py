"""Tiny hand-made plans that pin the 1.6 rules in sim_raids.py.

Run: python -I test_sim_raids.py
"""
import importlib.util
import os
import sys
import unittest

sys.dont_write_bytecode = True       # keep the folder free of __pycache__
HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("sim_raids", os.path.join(HERE, "sim_raids.py"))
sr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sr)

LEGEND = {".": "ground", "#": "wall", "D": "door", "/": "diag", "_": "floor"}
ROOM = [".......",
        ".#####.",
        ".#___#.",
        ".#___D.",     # door at (2, 0)
        ".#___#.",
        ".#####.",
        "......."]


def make_plan(rows, material="granite", **extra):
    """New-format plan centred on (0, 0): '.' ground, '#' wall, 'D' door, '/' diagonal wall, '_' room floor."""
    h, w = len(rows), len(rows[0])
    cells = [[[LEGEND[ch], "room" if ch == "_" else None, 0, 0, material] for ch in row] for row in rows]
    plan = {"origin": [-(w // 2), -(h // 2)], "cells": cells, "features": [],
            "rooms": [{"key": "room", "kind": "bedroom", "center": [0, 0], "phase": 0}]}
    plan.update(extra)
    return plan


def world(plan, phase=99, **params):
    p = dict(sr.P)
    p.update(params)
    return sr.World(plan, map_size=21, phase=phase, params=p)


def dist_from(w, ct, cell):
    return sr.dijkstra(ct.cost, ct.blocked, ct.dblock, w.W, w.idx(*cell), ct.card, ct.diag)


def furn(d, x, y, pass_="PassThroughOnly", path_cost=0, hp=100, w=1, h=1, **extra):
    """A furniture item with the spec fields only (no role, fill or class keys)."""
    it = {"def": d, "x": x, "y": y, "w": w, "h": h, "rot": 0, "phase": 0, "pass": pass_, "path_cost": path_cost,
          "hp": hp, "owned_bed": False}
    it.update(extra)
    return it


class Rules(unittest.TestCase):
    def test_door_cost_uses_max(self):
        rows = [".....#."] * 3 + [".....D."] + [".....#."] * 3
        turret = {"kind": "turret", "phase": 0, "cells": [[0, 0]]}
        w = world(make_plan(rows, features=[turret]))
        sim = sr.Sim(w, sr.parse_args([]))
        door = w.idx(2, 0)
        self.assertEqual(sim.av[door], 45)                  # a door is walkable, so the turret prints on it
        bash = sr.ushort_cost(50, 272, 0.2)
        self.assertEqual(bash, 104)
        self.assertEqual(sr.build_costs(w, "sapper", sim.av).cost[door], max(45 * 8, bash))   # 360, not 464
        bare = world(make_plan(rows))
        self.assertEqual(sr.build_costs(bare, "sapper", [0] * bare.N).cost[bare.idx(2, 0)], 104)

    def test_known_trap_costs_800(self):
        trap = {"kind": "trap", "phase": 0, "cells": [[1, 1]]}
        w = world(make_plan(["......."] * 7, features=[trap]), KNOWN_CHANCE=1.0)
        known, k, zero = sr.known_traps(w, 0), w.idx(1, 1), [0] * w.N
        self.assertIn(k, known)
        self.assertEqual(sr.build_costs(w, "sapper", zero, known).cost[k], 800)
        self.assertEqual(sr.build_costs(w, "smart_walker", zero, known).cost[k], 800)
        self.assertEqual(sr.build_costs(w, "walker", zero, known).cost[k], 0)       # plain raiders know no traps
        self.assertEqual(sr.build_costs(w, "breach").cost[k], 20)                   # pawn-less: only the edifice offset

    def test_line_of_sight_blocked_behind_wall(self):
        rows = ["........."] * 4 + ["......#.."] + ["........."] * 4          # wall at (2, 0)
        turret = {"kind": "turret", "phase": 0, "cells": [[0, 0]]}
        w = world(make_plan(rows, features=[turret]))
        self.assertFalse(sr.los_clear(w, 4, 0, 0, 0))
        self.assertTrue(sr.los_clear(w, 0, 4, 0, 0))
        self.assertTrue(sr.los_clear(w, 2, 0, 0, 0))         # the first cell (the tile itself) is skipped
        av = sr.Sim(w, sr.parse_args([])).av
        self.assertEqual(av[w.idx(4, 0)], 0)
        self.assertEqual(av[w.idx(0, 4)], 45)
        # 4-connected walk: a diagonal gap between two walls does not let the turret see through
        corner = world(make_plan([".......", ".......", ".......", "....#..", "...#...", ".......", "......."],
                                 features=[turret]))
        self.assertFalse(sr.los_clear(corner, 1, 1, 0, 0))

    def test_breach_cost_granite_wall(self):
        w = world(make_plan(ROOM))
        wall, door = w.idx(-2, 0), w.idx(2, 0)
        offset = int(20 + 0.015 * 510)                       # (ushort) custom offset on every destroyable edifice
        expected = 20 + round(0.015 * 510) + offset          # 20 + 8 + 27 = 55
        self.assertEqual(sr.build_costs(w, "breach").cost[wall], expected)
        self.assertEqual(expected, 55)
        self.assertEqual(sr.build_costs(w, "breach", noise=frozenset([wall])).cost[wall], expected + 30)
        self.assertEqual(sr.build_costs(w, "breach").cost[door], 24)   # max(offset 24, provider 20 + 0.015 * 272)
        self.assertEqual(sr.build_costs(w, "breach").card, 18)

    def test_walkers_cannot_cross_closed_door(self):
        w = world(make_plan(ROOM, beds=[[0, 0]]))
        self.assertEqual(w.beds[0][1], (0, 0))
        outside = w.idx(-3, -3)
        for mode in ("walker", "smart_walker"):
            ct = sr.build_costs(w, mode, [0] * w.N)
            self.assertTrue(ct.blocked[w.idx(2, 0)])
            self.assertGreaterEqual(dist_from(w, ct, (0, 0))[0][outside], sr.INF)
        sapper = sr.build_costs(w, "sapper", [0] * w.N)
        dist, nxt = dist_from(w, sapper, (0, 0))
        self.assertLess(dist[outside], sr.INF)                            # sappers dig in anywhere
        beside = sr.walk(nxt, w.idx(3, 0), w.idx(0, 0))
        self.assertIn(w.idx(2, 0), beside)                                # beside it the door (104) beats a wall (172)
        opened = world(make_plan([r.replace("D", "_") for r in ROOM]))
        self.assertLess(dist_from(opened, sr.build_costs(opened, "walker"), (0, 0))[0][outside], sr.INF)

    def test_walkers_head_for_their_own_bed(self):
        w = world(make_plan(ROOM, beds=[[0, 0]]))
        sim, ct = sr.Sim(w, sr.parse_args([])), sr.build_costs(w, "walker")
        groups = {"inside": [w.idx(-1, -1), w.idx(1, 1)], "edge": [w.idx(-5, -5)]}
        res = sim.run("walker", "walker", ct, groups, [("bed1", w.idx(0, 0))])
        self.assertEqual([r["stand_in"] for r in res["inside"]["recs"]], [None, None])   # same room: the bed itself
        self.assertEqual([r["stand_in"] for r in res["edge"]["recs"]], [(0, -3)])        # sealed off: closest cell
        self.assertEqual(sim.sealing_check([("bed1", w.idx(0, 0))])["beds_reachable"], 0)

    def test_unbuilt_owned_bed_stays_a_planned_target(self):
        bed = {"def": "Bed", "x": 0, "y": -1, "w": 1, "h": 2, "rot": 0, "phase": 3, "pass": "PassThroughOnly",
               "path_cost": 42, "hp": 140, "owned_bed": True, "key": "bedA"}
        early = world(make_plan(ROOM, furniture=[bed]), phase=1)
        self.assertEqual((early.beds, early.all_beds), ([], [("bedA", (0, 0), 3)]))
        self.assertEqual(early.bed_source, "owned beds in the furniture list")
        self.assertEqual(world(make_plan(ROOM, furniture=[bed]), phase=3).beds, [("bedA", (0, 0), 3)])

    def test_fence_gate_is_a_full_fill_door(self):
        gate = {"def": "FenceGate", "x": 1, "y": 0, "w": 1, "h": 1, "rot": 0, "phase": 0, "pass": "Standable", "hp": 20}
        w = world(make_plan(["......."] * 7, furniture=[gate]))
        k = w.idx(1, 0)
        self.assertEqual((w.door[k], w.full[k], w.fence[k]), (1, 1, 0))    # DoorBase fillPercent 1, no isFence
        self.assertFalse(sr.los_clear(w, 3, 0, 0, 0))

    def test_breaks_between_castle_rooms_are_reported(self):
        w = world(make_plan([".......", ".#####.", ".#_#_#.", ".#_#_#.", ".#_#_#.", ".#####.", "......."]))
        r = sr.classify(w, [w.idx(-1, 0), w.idx(0, 0), w.idx(1, 0)], {w.idx(0, 0)})
        self.assertEqual(r["broke"], {"internal"})
        self.assertEqual(sr.summarize({"recs": [r], "unreachable": 0})["broke_pct"]["internal"], 100.0)

    def test_diag_blocks_like_wall(self):
        rows = [r.replace("#", "/").replace("D", "/") for r in ROOM]
        turret = {"kind": "turret", "phase": 0, "cells": [[0, 0]]}
        w = world(make_plan(rows, features=[turret]))
        k = w.idx(-2, 0)
        self.assertEqual(w.struct[k], sr.S_DIAG)
        walker = sr.build_costs(w, "walker")
        self.assertTrue(walker.blocked[k] and walker.dblock[k])
        self.assertGreaterEqual(dist_from(w, walker, (0, 0))[0][w.idx(-3, -3)], sr.INF)
        self.assertFalse(sr.los_clear(w, -3, 0, 0, 0))
        plain = world(make_plan(ROOM))
        self.assertEqual(sr.build_costs(w, "sapper", [0] * w.N).cost[k],
                         sr.build_costs(plain, "sapper", [0] * plain.N).cost[plain.idx(-2, 0)])
        self.assertEqual(sr.build_costs(w, "breach").cost[k], 55)

    def test_fences_block_diagonals_and_pass_through_things_do_not(self):
        feats = [{"kind": "fence", "phase": 0, "cells": [[1, 0]]}, {"kind": "sandbags", "phase": 0, "cells": [[-1, 0]]}]
        w = world(make_plan(["......."] * 7, features=feats))
        ct = sr.build_costs(w, "walker")
        self.assertEqual((ct.cost[w.idx(1, 0)], ct.dblock[w.idx(1, 0)]), (80, 1))
        self.assertEqual((ct.cost[w.idx(-1, 0)], ct.dblock[w.idx(-1, 0)]), (42, 0))

    def test_old_format_phases(self):
        rows = [[["ground", None, 0, 0]] * 3, [["wall", None, 1, 0], ["door", None, 1, 3], ["wall", None, 2, 0]],
                [["ground", None, 0, 0]] * 3]
        plan = {"origin": [-1, -1], "cells": rows, "rooms": [], "features": [
            {"kind": "lane", "phase": 5, "cells": [[0, 1]]}]}
        early, late = world(plan, phase=2), world(plan, phase=5)
        self.assertEqual(early.struct[early.idx(0, 0)], sr.S_WALL)      # door slot still walled up
        self.assertEqual(late.struct[late.idx(0, 0)], sr.S_DOOR)
        self.assertEqual(world(plan, phase=1).struct[early.idx(1, 0)], sr.S_NONE)   # not built yet
        self.assertNotEqual(early.zone[early.idx(0, 1)], sr.Z_LANE)     # the lane exists only from phase 5
        self.assertEqual(late.zone[late.idx(0, 1)], sr.Z_LANE)

    def test_materials_and_furniture(self):
        w = world(make_plan(ROOM, material="BlocksLimestone"))
        self.assertEqual((w.hp[w.idx(-2, 0)], w.hp[w.idx(2, 0)]), (465, 248))
        self.assertEqual(world(make_plan(ROOM, material="wood")).hp[w.idx(2, 0)], 104)
        custom = world(make_plan(ROOM, materials={"granite": 600}))
        self.assertEqual((custom.hp[w.idx(-2, 0)], custom.hp[w.idx(2, 0)]), (600, 320))
        furniture = [{"def": "Turret_Autocannon", "x": 3, "y": 3, "w": 2, "h": 2, "rot": 0, "phase": 0,
                      "pass": "PassThroughOnly", "path_cost": 50, "hp": 380},
                     {"def": "Bed", "x": -1, "y": -1, "w": 1, "h": 2, "rot": 0, "phase": 0, "pass": "PassThroughOnly",
                      "path_cost": 42, "hp": 140, "owned_bed": True},
                     {"def": "Shelf", "x": 1, "y": -1, "w": 1, "h": 1, "rot": 0, "phase": 0, "pass": "Impassable",
                      "path_cost": 0, "hp": 100}]
        f = world(make_plan(ROOM, furniture=furniture))
        t = f.turrets[0]
        self.assertEqual((t["pos"], t["range"], t["min_range"]), ((3, 4), 32.9, 8.9))
        self.assertEqual(f.beds, [("Bed#1", (-1, 0), 0)])
        sapper = sr.build_costs(f, "sapper", [0] * f.N)
        self.assertEqual(sapper.cost[f.idx(-1, -1)], 42)                 # bed: walkable, its path cost
        self.assertEqual(sapper.cost[f.idx(1, -1)], 70 + 20)             # impassable furniture is dug like a wall
        self.assertTrue(sr.build_costs(f, "walker").blocked[f.idx(1, -1)])


class FurnitureRoles(unittest.TestCase):
    """Plans whose furniture names only the def: the role comes from the 1.6 defs, not from the name."""

    def test_barricade_and_mod_fences_block_diagonals(self):
        items = [furn("Barricade", 1, 0, path_cost=42, hp=300), furn("VFEArch_ChainlinkFence", -2, 2, path_cost=140)]
        w = world(make_plan(["......."] * 7, furniture=items))
        b = w.idx(1, 0)
        self.assertEqual((w.fence[b], w.fence[w.idx(-2, 2)]), (1, 1))          # building.isFence in both defs
        walker = sr.build_costs(w, "walker")
        self.assertEqual((walker.cost[b], walker.dblock[b]), (42, 1))
        self.assertEqual(dist_from(w, walker, (0, 0))[0][w.idx(1, 1)], 26)      # no diagonal step past it: 13 + 13
        self.assertEqual(w.notes, [])                                          # nothing had to be guessed

    def test_fsf_stone_spike_is_a_trap_and_look_alikes_are_not(self):
        items = [furn("FSFStoneTrapSpike", 1, 1, "Standable", hp=40), furn("HunterDroneTrap", -1, 1, "Standable"),
                 furn("AncientTankTrap", 2, -2, path_cost=50, hp=500), furn("VFEPD_HunterDroneTrap", -2, -2, path_cost=42)]
        w = world(make_plan(["......."] * 7, furniture=items), KNOWN_CHANCE=1.0)
        self.assertEqual(sorted(w.xy(k) for k in w.trap_cells), [(-1, 1), (1, 1)])   # Building_Trap subclasses only
        known, zero = sr.known_traps(w, 0), [0] * w.N
        self.assertEqual(sr.build_costs(w, "sapper", zero, known).cost[w.idx(1, 1)], 800)
        self.assertEqual(sr.build_costs(w, "smart_walker", zero, known).cost[w.idx(1, 1)], 800)

    def test_doors_by_def_not_by_name(self):
        items = [furn("DoorSaloon", -2, -2, "Standable", hp=40), furn("ToiletStallDoor", -1, -2, "Standable", hp=250),
                 furn("VFEPD_FakeDoor", 0, -2, path_cost=50), furn("VacBarrier", 1, -2, "Standable")]
        w = world(make_plan(["......."] * 7, furniture=items))
        walker = sr.build_costs(w, "walker")
        saloon, stall, fake, vac = (w.idx(x, -2) for x in (-2, -1, 0, 1))
        self.assertTrue(walker.blocked[saloon])                    # its 'new' FreePassage is never called
        self.assertEqual(sr.build_costs(w, "sapper", [0] * w.N).cost[saloon], sr.ushort_cost(50, 40, 0.2))
        self.assertFalse(walker.blocked[stall] or walker.blocked[fake])          # not Building_Door subclasses
        self.assertFalse(walker.blocked[vac])                      # FreePassage: walkable for everyone
        self.assertTrue(walker.dblock[vac])                        # still a full-fill edifice for diagonal steps
        self.assertTrue(sr.los_clear(w, 1, -3, 1, 0))              # always open, so it can be seen over
        self.assertFalse(sr.los_clear(w, -2, -3, -2, 0))           # a closed door blocks sight

    def test_mod_turrets_print_and_look_alikes_do_not(self):
        items = [furn("PPCHEL", 0, 0, path_cost=150, hp=200, w=3, h=3), furn("Turret_Mortar", -6, -6, w=2, h=2),
                 furn("APM_GazerEmplacement", 5, -6, "Impassable", 90, 400, w=2, h=3),
                 furn("VFEPD_AncientAutocannonTurret", -6, 5), furn("ModWallTurret", 6, 6)]
        w = sr.World(make_plan(["......."] * 7, furniture=items), map_size=131, phase=99, params=dict(sr.P))
        self.assertEqual([(t["def"], t["pos"], t["range"]) for t in w.turrets],
                         [("PPCHEL", (1, 1), 55.0), ("ModWallTurret", (6, 6), 28.9)])
        self.assertTrue(w.turrets[1]["guess"])
        self.assertTrue(any("ModWallTurret as turret" in n for n in w.notes))   # the guess is reported
        self.assertTrue(any("PPCHEL as turret" in n for n in w.notes))          # so is the unchecked mod class
        av = sr.Sim(w, sr.parse_args([])).av
        self.assertEqual((av[w.idx(1, -50)], av[w.idx(1, -62)]), (45, 0))       # 51 and 63 cells out: range 55 + 4

    def test_fill_percent_alias_and_partial_fill(self):
        items = [furn("TallCabinet", 1, 0, fill_percent=1.0), furn("LowShelf", -1, 0, "Impassable", fill_percent=0.5)]
        w = world(make_plan(["......."] * 7, furniture=items))
        full, part = w.idx(1, 0), w.idx(-1, 0)
        self.assertEqual((w.full[full], w.opaque[full], w.imp[full]), (1, 1, 0))
        self.assertEqual((w.full[part], w.opaque[part], w.imp[part]), (0, 0, 1))
        self.assertTrue(sr.build_costs(w, "sapper", [0] * w.N).blocked[part])   # partial fill: never dug
        self.assertFalse(sr.los_clear(w, 3, 0, 0, 0))
        self.assertTrue(sr.los_clear(w, -3, 0, 0, 0))
        self.assertFalse(any(n.startswith("fill guessed") for n in w.notes))

    def test_door_furniture_replaces_wall_and_door_cells(self):
        items = [furn("Autodoor", -2, 0, "Standable", hp=440), furn("Autodoor", 2, 0, "Standable", hp=440),
                 furn("ToiletStallDoor", 0, 2, "Standable", hp=250), furn("Bed", 0, -2, path_cost=42, hp=140)]
        w = world(make_plan(ROOM, furniture=items))         # (-2, 0) a granite wall cell, (2, 0) a granite door cell
        for c in ((-2, 0), (2, 0)):
            k = w.idx(*c)
            self.assertEqual((w.struct[k], w.door[k], w.hp[k]), (sr.S_DOOR, 1, 440))
        self.assertEqual(sr.build_costs(w, "sapper", [0] * w.N).cost[w.idx(-2, 0)], sr.ushort_cost(50, 440, 0.2))
        stall = w.idx(0, 2)                                 # canPlaceOverWall, but not a door: the wall line is open
        self.assertFalse(sr.build_costs(w, "walker").blocked[stall])
        self.assertEqual(w.struct[w.idx(0, -2)], sr.S_WALL)  # a bed cannot stand on a wall
        self.assertTrue(any(n.startswith("furniture on a wall") and "Bed" in n for n in w.notes))


if __name__ == "__main__":
    unittest.main()
