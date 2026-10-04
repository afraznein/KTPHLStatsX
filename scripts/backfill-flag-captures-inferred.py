#!/usr/bin/env python3
"""Backfill ktp_flag_captures with INFERRED rows from hlstats_Events_PlayerActions.

ktp_flag_captures starts at its own go-live. Earlier captures survive only as
generic player actions (codes dod_capture_area and dod_control_point), which
carry server, map, player, time and the daemon's own match_id tag, but no half,
no side and no flag name. This tool derives what it can and writes the result
with provenance = 'inferred' and source_action_id = the PlayerActions id.

DRY RUN BY DEFAULT. Nothing is written without --apply, and --apply also needs
--expect N, where N is the planned-insert count a dry run printed. Requires
sql/migrate_040_flag_captures_provenance.sql to be applied before --apply.

    # on the data server, read-only:
    python3 backfill-flag-captures-inferred.py --defaults-file ~/.my.cnf
    # after reviewing the counts:
    python3 backfill-flag-captures-inferred.py --defaults-file ~/.my.cnf --apply --expect 123456

What each inferred column means:
  match_id   copied from the source row. The daemon tags a player action with
             the same live-round gate it uses for a capture, so this is the tag
             the capture would have carried. NULL source -> NULL, half 0.
  half       the ktp_matches half of that match_id whose window contains the
             event. Zero or several candidate windows -> the event is SKIPPED
             and counted as unresolved, never written with a guessed half.
  team       the player's latest hlstats_Events_ChangeTeam on the same server
             and map, at or before the event, and no older than the half's
             start minus --team-slack-minutes (outside a match: no older than
             --nomatch-team-minutes). Anything else, or a non-playing team -> NULL.
  flag_name  always NULL: the source never stored it. NULL is absent, not blank.
  event_time the source eventTime (log clock). Recorded rows use the daemon's
             NOW(), so the two clocks can differ by the daemon's ingest lag.

Windows:
  main      both codes, eventTime < --before (default: the earliest recorded row).
  extension dod_control_point only, --before <= eventTime < --control-point-until.
            The daemon wrote dod_capture_area captures from go-live but only began
            writing dod_control_point captures later, so that code has a second gap.
            Off unless --control-point-until is given.
Every candidate is also dropped if a RECORDED row exists for the same server and
player within --neighbour-seconds, so the two populations cannot double-count.

The dry run ends with a positive control: it re-derives half and team for recent
RECORDED rows, whose true values the daemon measured, and reports agreement.
"""
from __future__ import annotations

import argparse
import bisect
import shlex
import subprocess
import sys
import time
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Iterable, Optional

CODES = ("dod_capture_area", "dod_control_point")
PLAYING_TEAMS = {"allies": "Allies", "axis": "Axis"}
TS_FMT = "%Y-%m-%d %H:%M:%S"


@dataclass(frozen=True)
class SourceEvent:
    id: int
    event_time: datetime
    server_id: int
    map: str
    match_id: Optional[str]
    player_id: int
    code: str


@dataclass(frozen=True)
class HalfWindow:
    half: int
    lo: datetime
    hi: datetime


@dataclass(frozen=True)
class TeamChange:
    event_time: datetime
    map: str
    team: str


@dataclass(frozen=True)
class PlannedRow:
    source_action_id: int
    server_id: int
    match_id: Optional[str]
    half: int
    player_id: int
    team: Optional[str]
    event_time: datetime
    code: str


# ---------------------------------------------------------------- pure logic

def build_half_windows(match_rows, max_half_minutes=45, edge_slack_seconds=5):
    """match_rows: (match_id, half, start_time, end_time|None) -> {match_id: [HalfWindow]}.

    An open half (end_time NULL) ends at the next half's start, else after
    max_half_minutes -- NULL end_time is common and must not read as endless.
    """
    by_match = defaultdict(list)
    for match_id, half, start, end in match_rows:
        by_match[match_id].append((int(half), start, end))
    slack = timedelta(seconds=edge_slack_seconds)
    out = {}
    for match_id, rows in by_match.items():
        rows.sort(key=lambda r: (r[1], r[0]))
        windows = []
        for i, (half, start, end) in enumerate(rows):
            if end is None or end < start:
                nxt = rows[i + 1][1] if i + 1 < len(rows) else None
                end = nxt if nxt is not None else start + timedelta(minutes=max_half_minutes)
            windows.append(HalfWindow(half, start - slack, end + slack))
        out[match_id] = windows
    return out


def resolve_half(match_id, event_time, windows_by_match):
    """-> (half, None) or (None, reason). A NULL match_id is half 0, as the daemon writes it."""
    if match_id is None:
        return 0, None
    windows = windows_by_match.get(match_id)
    if not windows:
        return None, "match_id has no ktp_matches row"
    hits = {w.half for w in windows if w.lo <= event_time <= w.hi}
    if len(hits) == 1:
        return hits.pop(), None
    if not hits:
        return None, "outside every half window"
    return None, "inside more than one half window"


def half_anchor(match_id, half, windows_by_match):
    if match_id is None or not half:
        return None
    starts = [w.lo for w in windows_by_match.get(match_id, []) if w.half == half]
    return min(starts) if starts else None


def normalise_team(raw):
    if raw is None:
        return None
    return PLAYING_TEAMS.get(raw.strip().lower())


class TeamIndex:
    """Latest ChangeTeam per (server, player), looked up by time."""

    def __init__(self, rows):
        grouped = defaultdict(list)
        for server_id, player_id, event_time, map_name, team in rows:
            grouped[(int(server_id), int(player_id))].append(TeamChange(event_time, map_name, team))
        self._changes = {}
        self._times = {}
        for key, changes in grouped.items():
            changes.sort(key=lambda c: c.event_time)
            self._changes[key] = changes
            self._times[key] = [c.event_time for c in changes]

    def team_at(self, server_id, player_id, map_name, event_time, not_before):
        key = (server_id, player_id)
        times = self._times.get(key)
        if not times:
            return None
        i = bisect.bisect_right(times, event_time) - 1
        if i < 0:
            return None
        change = self._changes[key][i]
        if change.map != map_name or change.event_time < not_before:
            return None
        return normalise_team(change.team)


def infer_team(ev, half, windows_by_match, teams, team_slack_minutes=15, nomatch_team_minutes=45):
    anchor = half_anchor(ev.match_id, half, windows_by_match)
    if anchor is not None:
        not_before = anchor - timedelta(minutes=team_slack_minutes)
    else:
        not_before = ev.event_time - timedelta(minutes=nomatch_team_minutes)
    return teams.team_at(ev.server_id, ev.player_id, ev.map, ev.event_time, not_before)


class RecordedNeighbours:
    """Recorded rows by (server, player), for the double-count guard."""

    def __init__(self, rows, seconds):
        self._times = defaultdict(list)
        for server_id, player_id, event_time in rows:
            self._times[(int(server_id), int(player_id))].append(event_time)
        for t in self._times.values():
            t.sort()
        self._delta = timedelta(seconds=seconds)

    def near(self, server_id, player_id, event_time):
        times = self._times.get((server_id, player_id))
        if not times:
            return False
        i = bisect.bisect_left(times, event_time - self._delta)
        return i < len(times) and times[i] <= event_time + self._delta


def plan(events, windows_by_match, teams, already_inferred, neighbours, before,
         control_point_until=None, team_slack_minutes=15, nomatch_team_minutes=45):
    """-> (planned rows, Counter of skip reasons). Pure; every decision is counted."""
    rows, skipped = [], Counter()
    for ev in events:
        if ev.event_time < before:
            pass
        elif (control_point_until is not None and ev.code == "dod_control_point"
              and ev.event_time < control_point_until):
            pass
        else:
            skipped["outside the backfill windows"] += 1
            continue
        if ev.id in already_inferred:
            skipped["already backfilled"] += 1
            continue
        if neighbours.near(ev.server_id, ev.player_id, ev.event_time):
            skipped["a recorded row already covers it"] += 1
            continue
        half, reason = resolve_half(ev.match_id, ev.event_time, windows_by_match)
        if half is None:
            skipped["unresolved half: " + reason] += 1
            continue
        team = infer_team(ev, half, windows_by_match, teams, team_slack_minutes, nomatch_team_minutes)
        rows.append(PlannedRow(ev.id, ev.server_id, ev.match_id, half, ev.player_id, team,
                               ev.event_time, ev.code))
    return rows, skipped


def sql_str(value):
    if value is None:
        return "NULL"
    if any(c in value for c in "\x00\n\r\x1a"):
        raise ValueError(f"refusing to quote control characters: {value!r}")
    return "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"


def insert_statements(rows, batch=500):
    for i in range(0, len(rows), batch):
        values = ",\n".join(
            "({}, {}, {}, {}, {}, NULL, '{}', 'inferred', {})".format(
                r.server_id, sql_str(r.match_id), r.half, r.player_id, sql_str(r.team),
                r.event_time.strftime(TS_FMT), r.source_action_id)
            for r in rows[i:i + batch])
        # ON DUPLICATE KEY on uk_source_action keeps a re-run inert without INSERT IGNORE's
        # habit of swallowing every other error too.
        yield ("INSERT INTO ktp_flag_captures\n"
               "  (server_id, match_id, half, player_id, team, flag_name, event_time, provenance, source_action_id)\n"
               "VALUES\n" + values + "\nON DUPLICATE KEY UPDATE id = id;")


def summarise(rows, skipped, out=None):
    out = out or sys.stdout
    print(f"planned inserts: {len(rows)}", file=out)
    for reason, n in sorted(skipped.items()):
        print(f"  skipped ({reason}): {n}", file=out)
    by_code = Counter(r.code for r in rows)
    by_half = Counter(r.half for r in rows)
    teamed = sum(1 for r in rows if r.team is not None)
    print(f"  by code: {dict(sorted(by_code.items()))}", file=out)
    print(f"  by half: {dict(sorted(by_half.items()))}", file=out)
    print(f"  with team: {teamed}  team NULL: {len(rows) - teamed}", file=out)
    for half in sorted(by_half):
        n = by_half[half]
        t = sum(1 for r in rows if r.half == half and r.team is not None)
        print(f"    half {half}: {t}/{n} with team", file=out)
    print(f"  distinct match_ids: {len({r.match_id for r in rows if r.match_id})}", file=out)
    by_month = Counter(r.event_time.strftime("%Y-%m") for r in rows)
    print(f"  by month: {dict(sorted(by_month.items()))}", file=out)
    by_server = Counter(r.server_id for r in rows)
    print(f"  by server_id: {dict(sorted(by_server.items()))}", file=out)


# ---------------------------------------------------------------- database

_ESC = {"t": "\t", "n": "\n", "0": "\0", "\\": "\\"}


def _unescape(f):
    """Undo mysql --batch escaping, so a tab or newline inside a value cannot split a row."""
    if "\\" not in f:
        return f
    out, i = [], 0
    while i < len(f):
        if f[i] == "\\" and i + 1 < len(f):
            out.append(_ESC.get(f[i + 1], f[i + 1]))
            i += 2
        else:
            out.append(f[i])
            i += 1
    return "".join(out)


class MysqlCli:
    """Thin wrapper over the mysql client so the tool needs no Python driver."""

    def __init__(self, command, database):
        self.command = command
        self.database = database

    def _run(self, sql):
        proc = subprocess.run(
            self.command + ["--batch", "--skip-column-names", self.database],
            input=sql.encode("utf-8"), capture_output=True)
        if proc.returncode != 0:
            raise RuntimeError(f"mysql failed ({proc.returncode}): {proc.stderr.decode('utf-8', 'replace').strip()}\n-- SQL:\n{sql[:2000]}")
        return proc.stdout.decode("utf-8", "replace")  # bytes: text mode would turn a \r in a value into a newline

    def rows(self, sql):
        out = []
        for line in self._run(sql).split("\n")[:-1]:
            out.append([None if f == "NULL" else _unescape(f) for f in line.split("\t")])
        return out

    def scalar(self, sql):
        r = self.rows(sql)
        return r[0][0] if r and r[0] else None

    def execute(self, sql):
        self._run(sql)


def ts(value):
    return datetime.strptime(value, TS_FMT) if value is not None else None


def first_id_at_or_after(db, table, when):
    """Binary search on the PK for the first row at/after `when`; eventTime is not indexed."""
    lo = int(db.scalar(f"SELECT MIN(id) FROM {table}") or 0)
    hi = int(db.scalar(f"SELECT MAX(id) FROM {table}") or 0)
    if hi == 0:
        return 0
    stamp = when.strftime(TS_FMT)
    while lo < hi:
        mid = (lo + hi) // 2
        t = db.scalar(f"SELECT eventTime FROM {table} WHERE id >= {mid} ORDER BY id LIMIT 1")
        if t is not None and t >= stamp:
            hi = mid
        else:
            lo = mid + 1
    return lo


def scan_by_id(db, table, columns, where, id_lo, id_hi, chunk, pause):
    """Short PK-range reads: these tables are MyISAM, and a long scan stalls the daemon."""
    out = []
    a = id_lo
    while a <= id_hi:
        b = min(a + chunk - 1, id_hi)
        out.extend(db.rows(f"SELECT {columns} FROM {table} WHERE id BETWEEN {a} AND {b} AND ({where})"))
        a = b + 1
        if pause:
            time.sleep(pause)
    return out


def chunks(seq, n):
    seq = list(seq)
    for i in range(0, len(seq), n):
        yield seq[i:i + n]


def has_column(db, table, column):
    return int(db.scalar(
        "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() "
        f"AND TABLE_NAME='{table}' AND COLUMN_NAME='{column}'")) > 0


def load_windows(db, match_ids, args):
    rows = []
    for part in chunks(sorted(match_ids), 500):
        in_list = ",".join(sql_str(m) for m in part)
        for match_id, half, start, end in db.rows(
                f"SELECT match_id, half, start_time, end_time FROM ktp_matches WHERE match_id IN ({in_list})"):
            rows.append((match_id, int(half), ts(start), ts(end)))
    return build_half_windows(rows, args.max_half_minutes, args.edge_slack_seconds)


def load_teams(db, t_lo, t_hi, args):
    id_lo = first_id_at_or_after(db, "hlstats_Events_ChangeTeam", t_lo)
    id_hi = first_id_at_or_after(db, "hlstats_Events_ChangeTeam", t_hi + timedelta(days=1))
    raw = scan_by_id(db, "hlstats_Events_ChangeTeam", "serverId, playerId, eventTime, map, team",
                     f"eventTime >= '{t_lo:%Y-%m-%d %H:%M:%S}' AND eventTime <= '{t_hi:%Y-%m-%d %H:%M:%S}'",
                     id_lo, id_hi, args.chunk, args.pause)
    return TeamIndex((int(s), int(p), ts(t), m, team) for s, p, t, m, team in raw)


def run_control(db, args, out=None):
    """Re-derive half and team for recent RECORDED rows and score against the daemon's values."""
    out = out or sys.stdout
    until = ts(db.scalar("SELECT MAX(event_time) FROM ktp_flag_captures"))
    if until is None:
        print("CONTROL: ktp_flag_captures is empty -- no control possible", file=out)
        return
    since = until - timedelta(days=args.control_days)
    prov = " AND provenance = 'recorded'" if has_column(db, "ktp_flag_captures", "provenance") else ""
    recorded = db.rows(
        "SELECT server_id, player_id, match_id, half, team, event_time FROM ktp_flag_captures "
        f"WHERE event_time >= '{since:%Y-%m-%d %H:%M:%S}' AND match_id IS NOT NULL AND half > 0{prov}")
    if not recorded:
        print("CONTROL IS BLIND: no recorded in-match rows in the control window", file=out)
        return
    windows = load_windows(db, {r[2] for r in recorded}, args)
    teams = load_teams(db, since - timedelta(hours=2), until, args)
    maps = {}
    for match_id, map_name in db.rows(
            "SELECT DISTINCT match_id, map_name FROM ktp_matches WHERE match_id IN ("
            + ",".join(sql_str(m) for m in {r[2] for r in recorded}) + ")"):
        maps[match_id] = map_name
    half_agree = half_wrong = half_unres = team_agree = team_wrong = team_null = 0
    for server_id, player_id, match_id, half, team, event_time in recorded:
        t = ts(event_time)
        got, _ = resolve_half(match_id, t, windows)
        if got is None:
            half_unres += 1
            continue
        if got == int(half):
            half_agree += 1
        else:
            half_wrong += 1
        ev = SourceEvent(0, t, int(server_id), maps.get(match_id, ""), match_id, int(player_id), "")
        inferred_team = infer_team(ev, got, windows, teams, args.team_slack_minutes, args.nomatch_team_minutes)
        if inferred_team is None:
            team_null += 1
        elif inferred_team == team:
            team_agree += 1
        else:
            team_wrong += 1
    print(f"CONTROL over {len(recorded)} recorded in-match rows since {since:%Y-%m-%d}:", file=out)
    print(f"  half: agree {half_agree}, DISAGREE {half_wrong}, unresolved {half_unres}", file=out)
    print(f"  team: agree {team_agree}, DISAGREE {team_wrong}, NULL {team_null}", file=out)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--mysql", default="mysql", help="client command prefix (default: mysql)")
    p.add_argument("--defaults-file", help="passed as --defaults-extra-file to the client")
    p.add_argument("--database", default="hlstatsx")
    p.add_argument("--before", help="main-window cutoff (default: earliest recorded row)")
    p.add_argument("--since", help="ignore source rows earlier than this")
    p.add_argument("--control-point-until", help="also fill dod_control_point up to this time")
    p.add_argument("--neighbour-seconds", type=int, default=10)
    p.add_argument("--team-slack-minutes", type=int, default=15)
    p.add_argument("--nomatch-team-minutes", type=int, default=45)
    p.add_argument("--max-half-minutes", type=int, default=45)
    p.add_argument("--edge-slack-seconds", type=int, default=5)
    p.add_argument("--chunk", type=int, default=50000, help="PK ids per source read")
    p.add_argument("--pause", type=float, default=0.2, help="seconds between source reads")
    p.add_argument("--control-days", type=int, default=14)
    p.add_argument("--no-control", action="store_true")
    p.add_argument("--apply", action="store_true", help="WRITE the planned rows")
    p.add_argument("--expect", type=int, help="with --apply: the planned count the dry run printed")
    args = p.parse_args(argv)
    if args.apply and args.expect is None:
        p.error("--apply needs --expect N (the planned-insert count from a dry run)")

    command = shlex.split(args.mysql)
    if args.defaults_file:
        command.insert(1, f"--defaults-extra-file={args.defaults_file}")
    db = MysqlCli(command, args.database)

    migrated = (has_column(db, "ktp_flag_captures", "provenance")
                and has_column(db, "ktp_flag_captures", "source_action_id"))
    if not migrated:
        if args.apply:
            sys.exit("migration 040 is not applied (provenance/source_action_id missing) -- refusing to write")
        print("NOTE: migration 040 not applied; dry run assumes no earlier backfill")

    actions = db.rows("SELECT id, game, code FROM hlstats_Actions WHERE code IN ("
                      + ",".join(sql_str(c) for c in CODES) + ")")
    code_by_action = {int(i): code for i, _game, code in actions}
    print(f"source actions: {[(int(i), g, c) for i, g, c in actions]}")
    missing = set(CODES) - set(code_by_action.values())
    if missing:
        sys.exit(f"QUERY IS BLIND: no hlstats_Actions row for {sorted(missing)}")

    recorded_filter = " WHERE provenance = 'recorded'" if migrated else ""
    first_recorded = ts(db.scalar(f"SELECT MIN(event_time) FROM ktp_flag_captures{recorded_filter}"))
    before = ts(args.before) if args.before else first_recorded
    if before is None:
        sys.exit("no recorded rows to take a cutoff from -- pass --before")
    cp_until = ts(args.control_point_until) if args.control_point_until else None
    since = ts(args.since) if args.since else None
    upper = max(before, cp_until) if cp_until else before
    print(f"earliest recorded row: {first_recorded}; main cutoff: {before}; "
          f"control_point extension until: {cp_until}; since: {since}")

    pa = "hlstats_Events_PlayerActions"
    id_lo = first_id_at_or_after(db, pa, since - timedelta(days=1)) if since else int(db.scalar(f"SELECT MIN(id) FROM {pa}") or 0)
    id_hi = first_id_at_or_after(db, pa, upper + timedelta(days=1))
    in_actions = ",".join(str(i) for i in code_by_action)
    where = f"actionId IN ({in_actions}) AND eventTime < '{upper:%Y-%m-%d %H:%M:%S}'"
    if since:
        where += f" AND eventTime >= '{since:%Y-%m-%d %H:%M:%S}'"
    raw = scan_by_id(db, pa, "id, eventTime, serverId, map, match_id, playerId, actionId",
                     where, id_lo, id_hi, args.chunk, args.pause)
    events = [SourceEvent(int(i), ts(t), int(s), m, mid, int(pl), code_by_action[int(a)])
              for i, t, s, m, mid, pl, a in raw]
    print(f"source events read: {len(events)} by code {dict(Counter(e.code for e in events))} "
          f"(PK ids {id_lo}..{id_hi})")
    late_area = int(db.scalar(
        f"SELECT COUNT(*) FROM {pa} WHERE id > {id_hi} AND actionId IN "
        f"({','.join(str(i) for i, c in code_by_action.items() if c == 'dod_capture_area')})"))
    print(f"  dod_capture_area source rows after the scanned range (expect 0 -- the daemon "
          f"diverted that code at go-live): {late_area}")
    if not events:
        sys.exit("QUERY IS BLIND: the source window returned no events")

    already = set()
    if migrated:
        already = {int(r[0]) for r in db.rows(
            "SELECT source_action_id FROM ktp_flag_captures WHERE provenance = 'inferred'")}
    t_lo = min(e.event_time for e in events)
    nb_rows = db.rows(
        "SELECT server_id, player_id, event_time FROM ktp_flag_captures WHERE "
        f"event_time <= '{upper + timedelta(seconds=args.neighbour_seconds):%Y-%m-%d %H:%M:%S}'"
        + (" AND provenance = 'recorded'" if migrated else ""))
    neighbours = RecordedNeighbours(((s, p, ts(t)) for s, p, t in nb_rows), args.neighbour_seconds)
    windows = load_windows(db, {e.match_id for e in events if e.match_id}, args)
    teams = load_teams(db, t_lo - timedelta(minutes=max(args.nomatch_team_minutes, args.team_slack_minutes + 60)),
                       upper, args)

    rows, skipped = plan(events, windows, teams, already, neighbours, before, cp_until,
                         args.team_slack_minutes, args.nomatch_team_minutes)
    summarise(rows, skipped)
    if not args.no_control:
        run_control(db, args)

    if not args.apply:
        print("DRY RUN -- nothing written. Re-run with --apply --expect "
              f"{len(rows)} to write these rows.")
        return 0
    if args.expect != len(rows):
        sys.exit(f"--expect {args.expect} does not match the {len(rows)} rows planned now -- refusing to write")
    before_n = int(db.scalar("SELECT COUNT(*) FROM ktp_flag_captures WHERE provenance = 'inferred'"))
    for stmt in insert_statements(rows):
        db.execute("START TRANSACTION;\n" + stmt + "\nCOMMIT;")
    after_n = int(db.scalar("SELECT COUNT(*) FROM ktp_flag_captures WHERE provenance = 'inferred'"))
    print(f"inferred rows: {before_n} -> {after_n} (+{after_n - before_n}, planned {len(rows)})")
    if after_n - before_n != len(rows):
        sys.exit("WRITE COUNT MISMATCH -- inspect before re-running")
    return 0


if __name__ == "__main__":
    sys.exit(main())
