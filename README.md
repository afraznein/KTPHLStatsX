# KTP HLStatsX

**Version 0.3.16** | Modified HLStatsX:CE Perl daemon with KTP match integration

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
| 612 | `KTP_CAPTURE_MANIFEST` | `doEvent_KTPCaptureManifest` | Validate and persist the paired producer contract |
| 613 | `KTP_CAPTURE_HEALTH` | `doEvent_KTPCaptureHealth` | Reconcile producer and daemon counts by event type |
| 614 | `KTP_OBJECTIVE_ATTEMPT` | `doEvent_KTPObjectiveAttempt` | Append factual capture start/complete/stop lifecycle rows |
| 615 | `KTP_GRENADE_ENTITY` | `doEvent_KTPGrenadeEntity` | Append tracked/removed grenade entity facts |

Types 605, 606, 608, and 611 arrive on the AMXX triggered/buffered-marker path;
607, 610, and 612–615 are bare `KTP_*` verbs. Producer-side buffering can still
delay either shape, so producer clocks rather than daemon receipt time are the
authoritative join. Each writes its own table directly instead of going through
`recordEvent`'s batching. Type 609 is parsed from the engine's ordinary
`dod_capture_area` line. The canonical
`assist` fact (`doEvent_KTPAssist` →
`ktp_assist_events`) rides the generic PlayerPlayerAction path and has no
dedicated type — the stock rating-neutral action still records alongside it.

Schema-22 bare markers have a 1024-byte maximum and an exact ordered-property
grammar. Objective and grenade events are accepted only after a successfully
persisted schema-22 manifest authorized both capabilities for that exact
server/match/half. Invalid manifests and unmanifested marker floods cannot
allocate capture-sequence state. Authorization is tied to a canonical manifest
fingerprint: a non-identical manifest for the same context revokes the old
contract before validation or persistence, and a failed replacement leaves
telemetry unauthorized. Only an exact accepted replay preserves the existing
sequence/health state.

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

**`ktp_matches.match_type`** is a direct `TINYINT UNSIGNED` column (migration 014), matching
`KTPMatchHandler.sma`'s enum: `0` official (`.ktp`), `1` scrim, `2` 12man, `3` draft, `4` KTP OT,
`5` draft OT. It records only which chat command started the match — it does not encode round,
stage, or format, and cannot separate group play from playoffs on its own. `NULL` rows predate the
KTPMatchHandler build that started emitting the type on `KTP_MATCH_START` (0.10.167); see
`sql/repair_backfill_match_type_13community.sql` for the one class of historical row recoverable
from the match id shape, and `scripts/backfill-match-type-from-demos.py` for the rest.
⚠️ **Keying match selection on `end_time IS NOT NULL` silently drops matches that started but
never got an explicit end** — decide deliberately whether an unfinished-but-real match belongs in
a result set, rather than by the side effect of an inner join or a `WHERE end_time IS NOT NULL`.
⚠️ **The `-KTP1`…`-KTP5` suffix on a `match_id` is the game-server station, not the match type** —
do not parse it looking for one.

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
- `ktp_position_samples` — periodic roster positions with explicit producer
  `is_alive`, `is_spectator`, and captured BSP SHA-256 facts;
  attacking/holding/defending is classified at query time, never stored
- `ktp_life_events` — validated life starts and ends for survival analytics
- `ktp_assist_events` — canonical producer-time assists
- `ktp_capture_manifests` — per-half producer version, capability manifest, and
  captured BSP SHA-256 provenance
- `ktp_capture_health` — producer-vs-daemon end-of-half capture reconciliation by
  event type
- `ktp_objective_attempt_events` — append-only start/complete/stop facts. A
  terminal without a received start is retained as left-censored; no start is
  synthesized. Completed, aborted, and orphan classifications are query-time.
- `ktp_grenade_entity_events` — append-only tracked/removed facts for hand,
  stick, and Mills grenades. `removed` is not proof of detonation/explosion,
  and this schema makes no grenade-to-damage correlation claim. Coordinates
  are private analytics data and must not be copied to public reports.

**Retention ownership:** migration 022 and the daemon never purge either new
ledger. Before production rollout, KTPInfrastructure's match-type retention job
must explicitly include `ktp_objective_attempt_events` and
`ktp_grenade_entity_events`, joined by `match_id`/`half`, under the same policy
as the other per-match ledgers.

**Views:** `ktp_match_leaderboard`, `ktp_recent_matches`

Schema migration:
- **Fresh install:** apply `sql/ktp_schema.sql`, then migrations 003 through
  024 in numeric order. The base schema is not a roll-up of later migrations;
  in particular, 016 creates `ktp_life_events`, 017 adds producer clocks and
  `ktp_assist_events`, and 018 adds the break-context claim column and makes
  `is_capout` nullable -- all required by daemon 0.3.10. 020 adds
  `frag_context_certified` and is required by daemon 0.3.12. 019 is a data
  correction rather than a precondition, and is a no-op on a fresh install.
  Migration 021 adds producer manifests, sequences, and capture-health
  reconciliation and is required by daemon 0.3.13. Migration 022 adds the two
  schema-22 telemetry ledgers and is required by daemon 0.3.15. Migration 023
  adds authoritative team transitions. Migration 024 adds nullable legacy-safe
  position state and map-revision columns and is required by daemon 0.3.16 and
  stats_logging 1.19.0 (schema 23). Skip migration
  002 on a fresh install because its half-column changes are already in the
  base schema.
- **Existing install:** apply every not-yet-applied migration in numeric order.
  A pre-0.3.1 database starts with `sql/migrate_002_half_damage_score.sql`;
  newer databases start with their next unapplied number.

`scripts/selftest-migration22.py` is the standard executable contract; CI runs
it against Infrastructure's production-parity ephemeral MySQL harness.

Migration 024 is independently idempotent: every new column and its query
index is guarded through `information_schema`. Existing rows remain `NULL` and
are explicitly legacy/unavailable; the daemon only authorizes schema-23
position rows whose alive/spectator bits and SHA-256 match the accepted
per-half manifest. See `docs/POSITION_STATE_MAP_REVISION_SCHEMA23.md`.

Migration 022 is safe to rerun and repairs missing named indexes. Every existing
named index must retain its expected uniqueness and complete ordered column
list. If either new table has missing/incompatible required columns, an extra
required/no-default column, a wrong same-name index, incompatible engine,
primary key, or collation, it fails early with an `ERROR_022_*_partial_or_incompatible`
sentinel. Restore the table definition—or drop it only after confirming it is
empty—then rerun; the migration does not guess how to rewrite existing data.

**Why each stat is or is not logged** — which absences are honest (`NULL` or a
reserved sentinel) versus which read as a measured false, what each deliberate
omission was decided for, and the one action with no recorded decision behind
it — is in [`docs/STAT_SET_RATIONALE.md`](docs/STAT_SET_RATIONALE.md).

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
for migration in sql/migrate_{003..022}_*.sql; do
  mysql -u hlstatsx -p hlstatsx < "$migration"
done

# 016 and 017 must both complete before starting daemon 0.3.10 or deploying
# the coordinated stats_logging.amxx producer. 018 must complete before that
# daemon starts too -- without it the break-context UPDATE names a column that
# does not exist (ERROR 1054) and the whole statement is lost. 020 is the same
# kind of precondition for daemon 0.3.12 and its frag_context UPDATE.
# 019 is a data correction and is not a daemon precondition. Its window has
# closed and 020 supersedes it: from 0.3.12 the daemon writes 019's own
# "all defaults" shape for an unusable payload while still claiming the row, so
# the predicate no longer identifies a false claim. 019 is guarded on 020 and
# becomes a no-op once 020 is applied -- which is why it stays in the loop.
# 021 must complete before daemon 0.3.13 and stats_logging 1.17.0 are deployed.
# 022 must complete before daemon 0.3.15 and stats_logging 1.18.0 (schema 22)
# are deployed. KTPInfrastructure owns retention for both new ledgers.
# 023 then 024 must complete before daemon 0.3.16 and stats_logging 1.19.0
# (schema 23) are deployed. 024 is nullable for legacy rows but schema-23
# authorization fails closed when explicit state or captured revision is absent.

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
