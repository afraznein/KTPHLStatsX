# KTP HLStatsX Changelog

## [0.2.7] - 2026-02-25

### Fixed
- **Headshot flush used wrong table key** - `flushEventTable("hlstats_Events_Frags")` was a no-op because event queue keys use short names (`"Frags"`). Headshot UPDATE ran before the frag was actually flushed to the database, silently losing headshot attribution. Changed to `flushEventTable("Frags")`.
- **Duplicate players in match stats** - `ktp_match_players` had no unique constraint on `(match_id, player_id)`, so `INSERT IGNORE` never prevented duplicates. Players appearing in both halves got two rows, causing double-counted stats in the aggregation query. Added `UNIQUE KEY uk_match_player` to schema and changed to `ON DUPLICATE KEY UPDATE` to update team/name on re-appearance.
- **Match start_time overwritten by duplicate UDP packets** - `doEvent_KTPMatchStart` used `ON DUPLICATE KEY UPDATE start_time = NOW()` which overwrote the original timestamp if a duplicate log line arrived. Changed to no-op (`id = id`) on duplicate.
- **Team kills and suicides not aggregated** - `doEvent_KTPMatchEnd` hardcoded `team_kills = 0` and `suicides = 0` instead of querying `hlstats_Events_Teamkills` and `hlstats_Events_Suicides` tables. Added LEFT JOINs for both tables.

### Schema
- Added `UNIQUE KEY uk_match_player (match_id, player_id)` to `ktp_match_players` table
- **Migration required:** `ALTER TABLE ktp_match_players ADD UNIQUE KEY uk_match_player (match_id, player_id);`

---

## [0.2.6] - 2026-02-19

### Added
- **Headshot kill tracking** - New `headshot_kill` triggered event handler parses log lines from stats_logging.sma's `client_death` forward. Flushes pending frags then UPDATEs the most recent matching frag row to `headshot=1`. Enables per-frag headshot data without double-counting kills.
- **Map tracking restoration on match start** - `doEvent_KTPMatchStart` now sets `$g_servers{$s_addr}->{map}` from the match event's map property. Ensures correct map attribution after daemon restarts where the "Started map" log event was missed.

### Fixed
- **MySQL encoding crash resilience** - `execCached()` in `HLstats.plib` now catches "Incorrect string value" MySQL errors (from non-UTF8 player names) and logs a warning instead of dying. All other query errors still fatal.

---

## [0.2.5] - 2026-02-05

### Added
- **KTP_HALF_END event handler** - Sets accurate `end_time` at actual gameplay end
  - Fires when scoreboard appears, BEFORE map change/warmup
  - Prevents warmup kills from being incorrectly attributed to the previous half
  - Works with KTPMatchHandler v0.10.69+

### Fixed
- **Half end_time accuracy** - Previously set when next half started (after warmup)
  - Now set at actual gameplay end via KTP_HALF_END event
  - Eliminates ~1-2 minutes of warmup kills being counted in H1 stats

---

## [0.2.4] - 2026-02-04

### Fixed
- First half `end_time` now recorded in `ktp_matches` table when second half starts
  - Previously only the final half had `end_time` set (via KTP_MATCH_END)
  - Now each half's `end_time` is set when the next half begins
  - **Note:** This was later improved in v0.2.5 to set end_time at actual gameplay end

---

## [0.2.3] - 2026-02-03

### Added
- Debug logging for match context cleanup in `doEvent_KTPMatchEnd`
  - Logs match_id being cleared when match ends for troubleshooting

---

## [0.2.2] - 2026-01-23

### Added
- Debug logging for KTP_MATCH event tracing (`KTP_DEBUG` messages in journal)
- Traces raw lines containing KTP_MATCH, parsed properties, and function entry

### Changed
- Removed dead code from `HLstats_EventHandlers.plib` (duplicate event handlers)
- Added clarifying comment explaining authoritative handlers are in `hlstats.pl`

### Fixed
- Half detection now supports all formats: "1st", "2nd", OT halves (regex-based matching)

## [0.2.1] - 2026-01-22

### Fixed
- Half number detection now uses regex (`/^2/`) instead of exact string match to handle different half format variations (e.g., "2nd", "2", "2nd_half")

## [0.2.0] - 2026-01-16

### Added
- Track participating players in `ktp_match_players` table on each frag event
- Aggregate player stats to `ktp_match_stats` table on match end
- Auto-populate `ktp_matches` table on match start
- Parse `KTP_MATCH_START`/`KTP_MATCH_END` events from plugin log lines

### Changed
- Use NULL instead of empty string for `match_id` when no match is active
- Enhanced match context tracking per server

## [0.1.0] - 2025-12-17

### Added
- Initial fork from HLStatsX:CE (NomisCZ/hlstatsx-community-edition)
- KTP match context tracking (`%g_ktpMatchContext` hash)
- KTP_MATCH_START event handler
- KTP_MATCH_END event handler
- match_id column support in event recording
- SQL schema for ktp_matches table

### Changed
- Modified event recording to include match_id when context is active

## [0.0.0] - 2025-12-17

### Base
- Original HLStatsX:CE files from https://github.com/NomisCZ/hlstatsx-community-edition
