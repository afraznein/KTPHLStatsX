# KTP HLStatsX

**Version 0.3.7** | Modified HLStatsX:CE Perl daemon with KTP match integration

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

`half` column added to `hlstats_Events_Frags`, `hlstats_Events_Teamkills`, `hlstats_Events_Suicides`, `hlstats_Events_Statsme` (0 = full-match total, 1/2 = halves, 3+ = OT).

**New KTP tables:**
- `ktp_matches` — Match boundaries (match_id, server_id, map, half, start/end times)
- `ktp_match_players` — Players per match (steam_id, team, joined_at)
- `ktp_match_stats` — Derived kills/deaths/headshots/teamkills/suicides/damage/score
  cache per player per match per half. Damage is `SUM(ktp_damage_events.damage_capped)`;
  StatsMe remains the weapon-level shots/hits/damage breakdown, not the canonical
  match-damage source.

**Views:** `ktp_match_leaderboard`, `ktp_recent_matches`

Schema migration:
- **Fresh install:** `sql/ktp_schema.sql`
- **Upgrading an existing pre-0.3.1 database:** `sql/migrate_002_half_damage_score.sql` — the `half` columns in `ktp_schema.sql` are unguarded `ADD COLUMN`, so re-running the full schema against a database that already has them fails.

---

## Files Modified

| File | Changes |
|------|---------|
| `scripts/hlstats.pl` | `%g_ktpMatchContext` hash, match_id injection in `recordEvent()`, KTP event parsers (types 600-604), event handlers |
| `scripts/HLstats_EventHandlers.plib` | `ktpTrackMatchPlayer()` calls in `doEvent_Frag()` |
| `sql/ktp_schema.sql` | match_id columns, ktp_* tables, views |

---

## Installation

**Prerequisites:** Perl 5.x with DBI, MySQL 8.0+, existing HLStatsX:CE installation, KTP Match Handler plugin.

```bash
# Replace daemon scripts
cp scripts/hlstats.pl /opt/hlstatsx/scripts/
cp scripts/HLstats_EventHandlers.plib /opt/hlstatsx/scripts/
cp scripts/HLstats.plib /opt/hlstatsx/scripts/

# Run schema migration
mysql -u hlstatsx -p hlstatsx < sql/ktp_schema.sql

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
```

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
