# KTP HLStatsX

**Version 0.3.10** | Modified HLStatsX:CE Perl daemon with KTP match integration

A fork of [HLStatsX:CE](https://github.com/NomisCZ/hlstatsx-community-edition) that enables match-based statistics tracking for competitive play. Separates warmup/practice stats from official match stats by tagging events with match IDs from KTP Match Handler.

Part of the [KTP Competitive Infrastructure](https://github.com/afraznein).

---

## Purpose

Standard HLStatsX tracks all player activity regardless of context — warmup kills, practice rounds, and competitive matches are mixed together. KTP HLStatsX solves this by:

1. Listening for `KTP_MATCH_START`, `KTP_MATCH_END`, `KTP_HALF_END`, `KTP_ROUND_FREEZE`, and `KTP_ROUND_LIVE` log events
2. Tracking match context per server (`%g_ktpMatchContext` hash)
3. Tagging events with `match_id` while a match round is live
4. Storing match metadata in dedicated tables

| Context | match_id | Result |
|---------|----------|--------|
| Warmup / Practice | `NULL` | Stats not attributed to any match |
| Competitive Match, round live | `KTP-xxx-mapname` | Events tagged with match ID |
| Freeze time (during a match) | `NULL` | Pre-round kills excluded from match stats |
| Between halves | `NULL` | Context cleared at `KTP_HALF_END` |
| Between Matches | `NULL` | Post-match activity untagged |

> Untagged events **inside** a live match are deliberate as of 0.3.3 — freeze-time
> kills and inter-half kills are excluded by design. If match frag counts look low,
> check that before suspecting the daemon.

---

## Architecture

```
Game Servers (UDP logs)
     |  logaddress_add <ip>:27500
     v
KTP HLStatsX Daemon (Perl)
  - Parses KTP_MATCH_START/END/HALF_END events
  - Tags events with match_id
  - Stores match metadata
     |
     v
MySQL (hlstatsx database)
  - hlstats_Events_Frags + match_id column
  - ktp_matches, ktp_match_players, ktp_match_stats
```

**Event flow from game server:**
```
KTPMatchHandler → dodx_set_match_id() → DODX logs KTP_MATCH_START
     → UDP to HLStatsX → doEvent_KTPMatchStart() → sets context
     → All subsequent events get match_id in INSERT
```

---

## KTP Event Types

| Type | Event | Handler | Purpose |
|------|-------|---------|---------|
| 600 | `KTP_MATCH_START` | `doEvent_KTPMatchStart` | Set match context, insert `ktp_matches` row |
| 601 | `KTP_MATCH_END` | `doEvent_KTPMatchEnd` | Set end_time, aggregate stats, clear context |
| 602 | `KTP_HALF_END` | `doEvent_KTPHalfEnd` | Set accurate half end_time before warmup starts; clear match context for the inter-half gap |
| 603 | `KTP_ROUND_FREEZE` | (inline) | Pause `match_id` tagging (`round_live = 0`) |
| 604 | `KTP_ROUND_LIVE` | (inline) | Resume `match_id` tagging (`round_live = 1`) |
| 605 | `damage` marker | `doEvent_KTPDamage` | Per-hit row in `ktp_damage_events` |
| 606 | `break_context` marker | (inline) | Annotate the matching `cap_break` PlayerActions row |
| 607 | `KTP_FLAG_POSITION` | `doEvent_KTPFlagPosition` | Upsert static per-map flag coordinates |
| 608 | `position_sample` marker | `doEvent_KTPPosition` | Periodic roster position sample |
| 609 | `flag_capture` marker | `doEvent_KTPFlagCapture` | Per-player capture completion |
| 610 | `KTP_FLAG_STATE` | `doEvent_KTPFlagState` | Flag-ownership baseline and owner changes |
| 611 | `life_boundary` marker | `doEvent_KTPLifeBoundary` | Validated life start/end |

The 605–611 markers arrive on the AMXX buffered-marker path rather than as bare
`KTP_*` verbs, and each writes its own table directly instead of going through
`recordEvent`'s batching. The canonical `assist` fact (`doEvent_KTPAssist` →
`ktp_assist_events`) rides the generic PlayerPlayerAction path and has no
dedicated type — the stock rating-neutral action still records alongside it.

**Log format:**
```
L 02/05/2026 - 14:30:00: KTP_MATCH_START (matchid "KTP-1734355200-dod_charlie") (map "dod_charlie") (half "1st")
L 02/05/2026 - 15:05:00: KTP_HALF_END (matchid "KTP-1734355200-dod_charlie") (map "dod_charlie") (half "1st")
L 02/05/2026 - 15:35:00: KTP_MATCH_END (matchid "KTP-1734355200-dod_charlie") (map "dod_charlie")
```

---

## Database Schema

**Modified existing tables** — `match_id` column added to:
- `hlstats_Events_Frags`, `hlstats_Events_Teamkills`, `hlstats_Events_Suicides`, `hlstats_Events_PlayerActions`

`half` column added to `hlstats_Events_Frags`, `hlstats_Events_Teamkills`,
`hlstats_Events_Suicides`, `hlstats_Events_Statsme` — `1`/`2` are the regulation
halves and `3+` are OT rounds.

> ⚠️ **On an event table, `half = 0` means the daemon held no match context when
> the line arrived — it is not a match total.** `recordEvent` is the only path
> that inserts into `hlstats_Events_*`, and it never writes an aggregate row, so
> `WHERE half = 0` selects warmup, practice and between-half activity: exactly
> what this fork exists to separate out. Match totals live in `ktp_match_stats`,
> where `half = 0` *is* a real total row, summed from the per-half rows at
> `KTP_MATCH_END`.

`half` and `match_id` answer different questions and are allowed to disagree.
Freeze-time events inside a live match keep the half they happened in but are
deliberately left untagged, so `half > 0 AND match_id IS NULL` is a meaningful
combination rather than corruption. Filter on `match_id` for *what counted*, on
`half` for *when*.

`hlstats_Events_PlayerActions` carries `match_id` but **no `half`** — objective
events take their half from `ktp_matches` by time. A query that names a `half`
column on that table fails to stderr while the caller sees an empty result,
which reads exactly like a match with no captures.

Every `DATETIME` in this schema is written through `FROM_UNIXTIME()`, so it
renders in the database session's own zone (Eastern on the data server), not
UTC. Where a producer supplies `event_epoch`, that is the only column holding a
true epoch — cross-zone comparisons belong there.

**New KTP tables** — the daemon writes each of these directly rather than
through `recordEvent`:
- `ktp_matches` — match/half boundaries (match_id, server_id, map, half, type, start/end times)
- `ktp_match_players` — roster per match (steam_id, team, joined_at)
- `ktp_match_stats` — derived kills/deaths/headshots/teamkills/suicides/damage/score
  cache per player per match per half, plus the `half = 0` total. Damage is
  `SUM(ktp_damage_events.damage_capped)`; StatsMe remains the weapon-level
  shots/hits/damage breakdown, not the canonical match-damage source.
- `ktp_damage_events` — per-hit ledger, capped and raw
- `ktp_flag_captures` — per-player capture completions; multi-capper detection is
  a query-time `GROUP BY (flag_name, event_time)`, not a stored column
- `ktp_flag_positions` — static per-flag coordinates per map
- `ktp_flag_state_events` — ownership timeline: one baseline row per flag per
  half, then owner changes only
- `ktp_position_samples` — periodic roster positions; attacking/holding/defending
  is classified at query time, never stored
- `ktp_life_events` — validated life starts and ends for survival analytics
- `ktp_assist_events` — canonical producer-time assists

**Views:** `ktp_match_leaderboard`, `ktp_recent_matches`

Schema migration:
- **Fresh install:** apply `sql/ktp_schema.sql`, then migrations 003 through
  018 in numeric order. The base schema is not a roll-up of later migrations;
  in particular, 016 creates `ktp_life_events`, 017 adds producer clocks and
  `ktp_assist_events`, and 018 adds the break-context claim column and makes
  `is_capout` nullable -- all required by daemon 0.3.10. Skip migration 002 on a fresh
  install because its half-column changes are already in the base schema.
- **Existing install:** apply every not-yet-applied migration in numeric order.
  A pre-0.3.1 database starts with `sql/migrate_002_half_damage_score.sql`;
  newer databases start with their next unapplied number.

---

## Files Modified

| File | Changes |
|------|---------|
| `scripts/hlstats.pl` | `%g_ktpMatchContext` hash, match_id injection in `recordEvent()`, the KTP event parsers and handlers, `getProperties` |
| `scripts/HLstats_EventHandlers.plib` | Per-half tagging, `ktpTrackMatchPlayer()`, accumulator increments, and the unresolved-action report in the generic trigger dispatcher |
| `scripts/HLstats.plib` | `execNonQuery` returns DBI's affected-row count, so a write that matched nothing can be detected instead of assumed |
| `sql/ktp_schema.sql` + `sql/migrate_*.sql` | match_id and half columns, ktp_* tables, views |

`HLstats_EventHandlers.plib` and `HLstats.plib` are upstream files carrying a KTP
delta — deploying an upstream copy over either one silently removes the fix.

---

## Installation

**Prerequisites:** Perl 5.x with DBI, MySQL 8.0+, existing HLStatsX:CE installation, KTP Match Handler plugin.

```bash
# Replace daemon scripts
cp scripts/hlstats.pl /opt/hlstatsx/scripts/
cp scripts/HLstats_EventHandlers.plib /opt/hlstatsx/scripts/
cp scripts/HLstats.plib /opt/hlstatsx/scripts/

# Create/upgrade the base KTP schema, then apply every later migration in order.
# Fresh installs start at 003 because ktp_schema.sql already contains 002.
mysql -u hlstatsx -p hlstatsx < sql/ktp_schema.sql
for migration in sql/migrate_{003..018}_*.sql; do
  mysql -u hlstatsx -p hlstatsx < "$migration"
done

# 016 and 017 must both complete before starting daemon 0.3.10 or deploying
# the coordinated stats_logging.amxx producer. 018 must complete before that
# daemon starts too -- it writes a NULL is_capout, which the pre-018 column
# rejects outright (ERROR 1048), taking the whole break-context UPDATE with it.

# Restart daemon
sudo systemctl restart hlstatsx
```

**Daemon config** (`/opt/hlstatsx/scripts/hlstats.conf`) — a layered install inherits
the upstream file, but `DBName` must be overridden: the built-in default is `hlstats`,
while this fork's database is `hlstatsx`.

```
DBHost=localhost
DBUsername=hlstatsx
DBPassword=<from the operator credential store>
DBName=hlstatsx
Port=27500
```

**Game server config** (`dodserver.cfg`):
```
log on
logaddress_add 74.91.112.242:27500
```

---

## Sample Queries

```sql
-- Match vs warmup kill counts (last 7 days)
SELECT
    CASE WHEN match_id IS NULL THEN 'Warmup' ELSE 'Match' END AS type,
    COUNT(*) AS kills
FROM hlstats_Events_Frags
WHERE eventTime > DATE_SUB(NOW(), INTERVAL 7 DAY)
GROUP BY (match_id IS NULL);

-- Stats for a specific match
SELECT p.lastName, COUNT(*) AS kills, SUM(headshot) AS headshots
FROM hlstats_Events_Frags f
JOIN hlstats_Players p ON f.killerId = p.playerId
WHERE f.match_id = 'KTP-1734355200-dod_charlie'
GROUP BY f.killerId ORDER BY kills DESC;

-- ktp_match_stats.half=0 is stored, not derived: it is written once at
-- KTP_MATCH_END and never recomputed, so a repair that fixes the per-half rows
-- leaves it stale and every per-half check still passes. Reconcile it directly.
SELECT t.match_id, t.player_id, t.kills AS total_kills, SUM(h.kills) AS half_kills
FROM ktp_match_stats t
JOIN ktp_match_stats h ON h.match_id = t.match_id
                      AND h.player_id = t.player_id AND h.half > 0
WHERE t.half = 0
GROUP BY t.match_id, t.player_id, t.kills
HAVING total_kills <> half_kills;
```

**Event rows are stamped on receipt, not at the kill**, so a row sits slightly
off its own log line. Reconciling a console log against the database on an exact
timestamp therefore reports nearly every kill as missing; match on the
participants and weapon within a small tolerance instead. Where a producer
supplies `event_epoch`, that is the authoritative clock and the reason
`producer_match_id`/`producer_half` exist — buffered delivery can cross a half
boundary, so timed analytics belong on the producer fields, never the
receipt-time ones.

**`hlstats_Events_Statsme` half `0` is contaminated, not merely untagged.** It
holds warmup and pub activity from every server, and the match-start flush can
fire before the match id is set, so some half-0 rows precede their own match.
Summing StatsMe without a `half` filter silently imports warmup. Rows older than
half attribution itself also carry `0`, which makes a naive half-coverage check
flag the whole early archive.

---

## Related Projects

**KTP Stack:**
- [KTPMatchHandler](https://github.com/afraznein/KTPMatchHandler) — Generates KTP_MATCH events
- [KTPAMXX](https://github.com/afraznein/KTPAMXX) — DODX module with HLStatsX natives

**Upstream:**
- [HLStatsX:CE](https://github.com/NomisCZ/hlstatsx-community-edition) — Original project

See [CHANGELOG.md](CHANGELOG.md) for version history.

---

## License

GPL v2 — Same as upstream HLStatsX:CE. See [LICENSE](LICENSE).
