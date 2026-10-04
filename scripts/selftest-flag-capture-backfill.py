#!/usr/bin/env python3
"""Tests for scripts/backfill-flag-captures-inferred.py and migration 040.

    python3 scripts/selftest-flag-capture-backfill.py

The mapping tests are pure and always run. Set KTP_SELFTEST_MYSQL_IMAGE (for
example mysql:8.0) to also run the database tests in a throwaway Docker
container: migration 040 applied twice, the daemon's own ktp_flag_captures
INSERT (lifted from hlstats.pl) against it, and a dry run plus two --apply runs
of the backfill over synthetic fixtures. Fixture ids and names are invented.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import re
import subprocess
import sys
import time
import unittest
import uuid
from datetime import datetime, timedelta
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
spec = importlib.util.spec_from_file_location("bf", HERE / "backfill-flag-captures-inferred.py")
bf = importlib.util.module_from_spec(spec)
sys.modules["bf"] = bf
spec.loader.exec_module(bf)

T0 = datetime(2026, 3, 1, 20, 0, 0)


def at(minutes, seconds=0):
    return T0 + timedelta(minutes=minutes, seconds=seconds)


def ev(i, minutes, match_id="m1", code="dod_control_point", server=7, player=101, map_name="dod_test"):
    return bf.SourceEvent(i, at(minutes), server, map_name, match_id, player, code)


MATCHES = [
    ("m1", 1, at(0), at(20)),
    ("m1", 2, at(25), None),          # open half: ends at the next half's start, or +45m
    ("m2", 1, at(100), at(120)),
    ("overlap", 1, at(200), at(230)),
    ("overlap", 2, at(220), at(250)),
]


class HalfWindows(unittest.TestCase):
    def setUp(self):
        self.w = bf.build_half_windows(MATCHES)

    def test_inside_one_window(self):
        self.assertEqual(bf.resolve_half("m1", at(10), self.w), (1, None))
        self.assertEqual(bf.resolve_half("m1", at(30), self.w), (2, None))

    def test_open_last_half_is_bounded(self):
        self.assertEqual(bf.resolve_half("m1", at(25 + 44), self.w)[0], 2)
        self.assertIsNone(bf.resolve_half("m1", at(25 + 46), self.w)[0])

    def test_open_half_ends_at_next_start(self):
        w = bf.build_half_windows([("x", 1, at(0), None), ("x", 2, at(22), at(42))])
        self.assertEqual(bf.resolve_half("x", at(21), w)[0], 1)
        self.assertEqual(bf.resolve_half("x", at(30), w)[0], 2)

    def test_halftime_gap_is_unresolved_not_guessed(self):
        half, reason = bf.resolve_half("m1", at(22), self.w)
        self.assertIsNone(half)
        self.assertIn("outside", reason)

    def test_edge_slack(self):
        self.assertEqual(bf.resolve_half("m1", at(20, 4), self.w)[0], 1)
        self.assertIsNone(bf.resolve_half("m1", at(20, 6), self.w)[0])

    def test_overlapping_windows_are_unresolved(self):
        half, reason = bf.resolve_half("overlap", at(225), self.w)
        self.assertIsNone(half)
        self.assertIn("more than one", reason)

    def test_null_match_is_half_zero_like_the_daemon(self):
        self.assertEqual(bf.resolve_half(None, at(10), self.w), (0, None))

    def test_unknown_match_is_unresolved(self):
        half, reason = bf.resolve_half("nope", at(10), self.w)
        self.assertIsNone(half)
        self.assertIn("no ktp_matches", reason)


class Teams(unittest.TestCase):
    def setUp(self):
        self.w = bf.build_half_windows(MATCHES)

    def team(self, changes, event, half):
        return bf.infer_team(event, half, self.w, bf.TeamIndex(changes))

    def test_latest_change_before_the_event(self):
        changes = [(7, 101, at(-5), "dod_test", "Axis"), (7, 101, at(2), "dod_test", "Allies")]
        self.assertEqual(self.team(changes, ev(1, 10), 1), "Allies")

    def test_change_after_the_event_is_ignored(self):
        changes = [(7, 101, at(-5), "dod_test", "Axis"), (7, 101, at(11), "dod_test", "Allies")]
        self.assertEqual(self.team(changes, ev(1, 10), 1), "Axis")

    def test_stale_change_from_before_the_half_is_null(self):
        # Joined before half 1, no new join logged for half 2: the side may have swapped.
        changes = [(7, 101, at(-5), "dod_test", "Axis")]
        self.assertIsNone(self.team(changes, ev(1, 30), 2))

    def test_other_map_other_server_other_player_are_null(self):
        e = ev(1, 10)
        self.assertIsNone(self.team([(7, 101, at(2), "dod_other", "Axis")], e, 1))
        self.assertIsNone(self.team([(8, 101, at(2), "dod_test", "Axis")], e, 1))
        self.assertIsNone(self.team([(7, 102, at(2), "dod_test", "Axis")], e, 1))

    def test_non_playing_team_is_null(self):
        for raw in ("Spectators", "Unassigned", "", "SPECTATOR"):
            self.assertIsNone(self.team([(7, 101, at(2), "dod_test", raw)], ev(1, 10), 1))
        self.assertEqual(self.team([(7, 101, at(2), "dod_test", "axis")], ev(1, 10), 1), "Axis")

    def test_outside_a_match_uses_the_nomatch_window(self):
        e = ev(1, 500, match_id=None)
        self.assertEqual(self.team([(7, 101, at(470), "dod_test", "Axis")], e, 0), "Axis")
        self.assertIsNone(self.team([(7, 101, at(440), "dod_test", "Axis")], e, 0))


class Planning(unittest.TestCase):
    def setUp(self):
        self.w = bf.build_half_windows(MATCHES)
        self.teams = bf.TeamIndex([(7, 101, at(-5), "dod_test", "Allies")])
        self.none = bf.RecordedNeighbours([], 10)
        self.before = at(1000)

    def plan(self, events, already=(), neighbours=None, cp_until=None):
        return bf.plan(events, self.w, self.teams, set(already), neighbours or self.none,
                       self.before, cp_until)

    def test_main_window_rows(self):
        rows, skipped = self.plan([ev(1, 10), ev(2, 30), ev(3, 22), ev(4, 50, match_id=None)])
        self.assertEqual([(r.source_action_id, r.half, r.match_id) for r in rows],
                         [(1, 1, "m1"), (2, 2, "m1"), (4, 0, None)])
        self.assertEqual(skipped["unresolved half: outside every half window"], 1)
        self.assertEqual(rows[0].team, "Allies")
        self.assertIsNone(rows[1].team)

    def test_rerun_plans_nothing(self):
        events = [ev(1, 10), ev(2, 30), ev(4, 50, match_id=None)]
        first, _ = self.plan(events)
        second, skipped = self.plan(events, already={r.source_action_id for r in first})
        self.assertEqual(second, [])
        self.assertEqual(skipped["already backfilled"], len(first))

    def test_extension_window_is_control_point_only(self):
        late_cp = bf.SourceEvent(10, at(1010), 7, "dod_test", None, 101, "dod_control_point")
        late_area = bf.SourceEvent(11, at(1010), 7, "dod_test", None, 101, "dod_capture_area")
        rows, skipped = self.plan([late_cp, late_area])
        self.assertEqual(rows, [])
        self.assertEqual(skipped["outside the backfill windows"], 2)
        rows, skipped = self.plan([late_cp, late_area], cp_until=at(1100))
        self.assertEqual([r.source_action_id for r in rows], [10])

    def test_recorded_neighbour_blocks_a_double_count(self):
        nb = bf.RecordedNeighbours([(7, 101, at(10, 8))], 10)
        rows, skipped = self.plan([ev(1, 10), ev(2, 10, player=102)], neighbours=nb)
        self.assertEqual([r.source_action_id for r in rows], [2])
        self.assertEqual(skipped["a recorded row already covers it"], 1)

    def test_neighbour_window_edges(self):
        nb = bf.RecordedNeighbours([(7, 101, at(10))], 10)
        self.assertTrue(nb.near(7, 101, at(10, 10)))
        self.assertFalse(nb.near(7, 101, at(10, 11)))
        self.assertTrue(nb.near(7, 101, at(9, 50)))
        self.assertFalse(nb.near(7, 101, at(9, 49)))


class Statements(unittest.TestCase):
    def test_insert_marks_inferred_and_leaves_flag_name_null(self):
        row = bf.PlannedRow(42, 7, "it's", 1, 101, None, at(0), "dod_capture_area")
        (stmt,) = list(bf.insert_statements([row]))
        self.assertIn("(7, 'it\\'s', 1, 101, NULL, NULL, '2026-03-01 20:00:00', 'inferred', 42)", stmt)
        self.assertIn("ON DUPLICATE KEY UPDATE", stmt)
        self.assertNotIn("''", stmt.split("VALUES")[1])

    def test_batches(self):
        rows = [bf.PlannedRow(i, 7, None, 0, 101, "Axis", at(0), "x") for i in range(1201)]
        self.assertEqual(len(list(bf.insert_statements(rows, batch=500))), 3)

    def test_refuses_control_characters(self):
        with self.assertRaises(ValueError):
            bf.sql_str("a\nb")

    def test_apply_needs_expect(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            bf.main(["--apply"])


# ---------------------------------------------------------------- database tests

IMAGE = os.environ.get("KTP_SELFTEST_MYSQL_IMAGE")

FIXTURE_SQL = """
CREATE TABLE hlstats_Actions (id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY, game VARCHAR(32), code VARCHAR(64));
INSERT INTO hlstats_Actions (id, game, code) VALUES (5, 'dod', 'dod_capture_area'), (6, 'dod', 'dod_control_point'),
  (9, 'dod', 'dod_test_dod_control_point');
CREATE TABLE hlstats_Events_PlayerActions (id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY, eventTime DATETIME,
  serverId INT UNSIGNED, map VARCHAR(64), match_id VARCHAR(64), playerId INT, actionId INT, bonus INT) ENGINE=MyISAM;
CREATE TABLE hlstats_Events_ChangeTeam (id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY, eventTime DATETIME,
  serverId INT UNSIGNED, map VARCHAR(64), match_id VARCHAR(64), playerId INT, team VARCHAR(64)) ENGINE=MyISAM;
CREATE TABLE ktp_matches (id INT AUTO_INCREMENT PRIMARY KEY, match_id VARCHAR(64) NOT NULL, server_id INT UNSIGNED,
  map_name VARCHAR(32), half TINYINT NOT NULL, start_time DATETIME NOT NULL, end_time DATETIME NULL,
  UNIQUE KEY (match_id, half));
INSERT INTO ktp_matches (match_id, server_id, map_name, half, start_time, end_time) VALUES
  ('fx-1', 7, 'dod_test', 1, '2026-03-01 20:00:00', '2026-03-01 20:20:00'),
  ('fx-1', 7, 'dod_test', 2, '2026-03-01 20:25:00', '2026-03-01 20:45:00'),
  ('fx-live', 7, 'dod_test', 1, '2026-08-20 20:00:00', '2026-08-20 20:20:00');
INSERT INTO hlstats_Events_ChangeTeam (eventTime, serverId, map, playerId, team) VALUES
  ('2026-03-01 19:58:00', 7, 'dod_test', 101, 'Allies'),
  ('2026-03-01 20:24:00', 7, 'dod_test', 101, 'Axis'),
  ('2026-08-20 19:59:00', 7, 'dod_test', 101, 'Axis');
INSERT INTO hlstats_Events_PlayerActions (eventTime, serverId, map, match_id, playerId, actionId) VALUES
  ('2026-03-01 20:05:00', 7, 'dod_test', 'fx-1', 101, 5),
  ('2026-03-01 20:05:00', 7, 'dod_test', 'fx-1', 101, 9),
  ('2026-03-01 20:30:00', 7, 'dod_test', 'fx-1', 101, 6),
  ('2026-03-01 20:22:00', 7, 'dod_test', 'fx-1', 102, 6),
  ('2026-03-02 10:00:00', 7, 'dod_test', NULL,   103, 6),
  ('2026-08-20 20:05:00', 7, 'dod_test', 'fx-live', 101, 6),
  ('2026-08-20 20:06:00', 7, 'dod_test', 'fx-live', 101, 6);
"""


def lift_daemon_insert():
    src = (HERE / "hlstats.pl").read_text(encoding="utf-8", errors="replace")
    m = re.search(r"INSERT INTO ktp_flag_captures\s*\(([^)]*)\)\s*VALUES\s*\(([^)]*NOW\(\))\)", src)
    if not m:
        raise AssertionError("could not find the daemon's ktp_flag_captures INSERT in hlstats.pl")
    values = (m.group(2).replace("$server_id", "7").replace("$match_id_sql", "'fx-live'")
              .replace("$half", "1").replace("$player_id", "101").replace("$team_sql", "'Axis'")
              .replace("$flag_sql", "'POINT_FIXTURE'"))
    if "$" in values:
        raise AssertionError(f"unsubstituted daemon variable in: {values}")
    return f"INSERT INTO ktp_flag_captures ({m.group(1)}) VALUES ({values});"


@unittest.skipUnless(IMAGE, "set KTP_SELFTEST_MYSQL_IMAGE to run the database tests")
class Database(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.name = f"ktp-selftest-flagbf-{uuid.uuid4().hex[:8]}"
        subprocess.run(["docker", "run", "-d", "--rm", "--name", cls.name, "-e", "MYSQL_ROOT_PASSWORD=selftest",
                        "-e", "MYSQL_DATABASE=hlstatsx", IMAGE], check=True, capture_output=True)
        cls.mysql = f"docker exec -i {cls.name} mysql -h127.0.0.1 -uroot -pselftest"
        deadline = time.time() + 120
        while time.time() < deadline:
            r = subprocess.run(cls.mysql.split() + ["hlstatsx", "-e", "SELECT 1"], capture_output=True, text=True)
            if r.returncode == 0:
                break
            time.sleep(2)
        else:
            raise RuntimeError("mysql container never became ready")

    @classmethod
    def tearDownClass(cls):
        subprocess.run(["docker", "stop", cls.name], capture_output=True)

    def sql(self, text):
        r = subprocess.run(self.mysql.split() + ["--batch", "--skip-column-names", "hlstatsx"],
                           input=text, capture_output=True, text=True)
        if r.returncode != 0:
            raise AssertionError(r.stderr)
        return r.stdout.strip()

    def load(self, name):
        self.sql((ROOT / "sql" / name).read_text(encoding="utf-8"))

    def run_tool(self, *args):
        out, err = io.StringIO(), io.StringIO()
        code = 0
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                code = bf.main(["--mysql", self.mysql, "--pause", "0", "--chunk", "2", *args]) or 0
            except SystemExit as e:
                code = e.code
                if isinstance(code, str):
                    print(code, file=err)
        return code, out.getvalue() + err.getvalue()

    def test_migration_daemon_insert_and_backfill(self):
        self.load("migrate_010_flag_captures.sql")
        self.sql(FIXTURE_SQL)
        self.sql(lift_daemon_insert())  # a pre-040 live row

        code, out = self.run_tool("--apply", "--expect", "0")
        self.assertNotEqual(code, 0)
        self.assertIn("migration 040 is not applied", out)

        self.load("migrate_040_flag_captures_provenance.sql")
        self.load("migrate_040_flag_captures_provenance.sql")
        self.sql(lift_daemon_insert())  # the daemon's INSERT, unchanged, after 040
        self.assertEqual(self.sql("SELECT provenance, COUNT(*), SUM(source_action_id IS NULL) "
                                  "FROM ktp_flag_captures GROUP BY provenance"), "recorded\t2\t2")
        self.sql("UPDATE ktp_flag_captures SET event_time = '2026-08-20 20:05:03'")

        code, out = self.run_tool()
        self.assertEqual(code, 0, out)
        self.assertIn("planned inserts: 3", out)
        self.assertIn("unresolved half: outside every half window): 1", out)
        self.assertIn("DRY RUN", out)
        self.assertEqual(self.sql("SELECT COUNT(*) FROM ktp_flag_captures"), "2")

        code, out = self.run_tool("--apply", "--expect", "2")
        self.assertNotEqual(code, 0)
        self.assertIn("does not match", out)

        code, out = self.run_tool("--control-point-until", "2026-09-01 00:00:00")
        self.assertIn("planned inserts: 4", out)
        self.assertIn("a recorded row already covers it): 1", out)
        self.assertIn("half: agree 2, DISAGREE 0", out)
        self.assertIn("team: agree 2, DISAGREE 0", out)

        code, out = self.run_tool("--control-point-until", "2026-09-01 00:00:00", "--apply", "--expect", "4")
        self.assertEqual(code, 0, out)
        got = self.sql("SELECT source_action_id, match_id, half, player_id, IFNULL(team,'<null>'), "
                       "IFNULL(flag_name,'<null>'), event_time FROM ktp_flag_captures "
                       "WHERE provenance='inferred' ORDER BY source_action_id")
        self.assertEqual(got.splitlines(), [
            "1\tfx-1\t1\t101\tAllies\t<null>\t2026-03-01 20:05:00",
            "3\tfx-1\t2\t101\tAxis\t<null>\t2026-03-01 20:30:00",
            "5\tNULL\t0\t103\t<null>\t<null>\t2026-03-02 10:00:00",
            "7\tfx-live\t1\t101\tAxis\t<null>\t2026-08-20 20:06:00",
        ])

        code, out = self.run_tool("--control-point-until", "2026-09-01 00:00:00", "--apply", "--expect", "0")
        self.assertEqual(code, 0, out)
        self.assertIn("already backfilled): 4", out)
        self.assertEqual(self.sql("SELECT COUNT(*) FROM ktp_flag_captures WHERE provenance='inferred'"), "4")


if __name__ == "__main__":
    unittest.main(verbosity=2)
