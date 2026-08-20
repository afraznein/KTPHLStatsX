-- KTP HLStatsX Migration 016: durable per-player life boundaries
-- Run on the data server before deploying a daemon/plugin pair that emits
-- `life_boundary` player actions:
--   mysql -u hlstatsx -p hlstatsx < migrate_016_life_events.sql
--
-- Wire shape (event type 611 in hlstats.pl):
--   "Player<uid><steamid><Team>" triggered "life_boundary"
--     (matchid "1787154570-TEST") (half "2") (event_epoch "1787154601")
--     (game_time "123.45")
--     (kind "start") (reason "spawn")
--     (team "1") (class "3") (slot "7")
--
-- This is a boundary ledger, not a derived life table. Query code pairs each
-- start with the next valid end for the same player/half and can explicitly
-- report incomplete lives. Physical boundaries continue to be emitted while
-- stats are paused, but live/freeze state is intentionally unobservable in v1:
-- MatchHandler changes DODX's private g_bStatsPaused flag, not the public
-- dodstats_pause cvar. Receipt-time daemon state is not a safe substitute
-- because markers are buffered. round_live therefore remains NULL until an
-- authoritative emitter-side signal exists.
--
-- The daemon validates the complete required payload and accepts only these
-- semantic pairs:
--   start -> spawn | context_live
--   end   -> death | disconnect
-- It resolves explicit producer match+half+event_epoch against exactly one
-- ktp_matches start/end interval on the same server. Receipt-time daemon state
-- is never used for half attribution; zero/overlapping intervals, a half
-- disagreement, or match-id case mismatch are dropped rather than guessed.
--
-- CREATE TABLE IF NOT EXISTS is idempotent on both MySQL and MariaDB. The
-- natural key includes game_time because event_epoch is only second precision;
-- `INSERT IGNORE` therefore deduplicates replayed markers without collapsing
-- two genuine boundaries that occur in the same wall-clock second.

CREATE TABLE IF NOT EXISTS ktp_life_events (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    server_id INT UNSIGNED NOT NULL,
    match_id VARCHAR(64) NOT NULL,
    half TINYINT UNSIGNED NOT NULL COMMENT 'producer half, DB-validated: 1/2=regulation, 3+=OT',
    map_name VARCHAR(32) NOT NULL,
    player_id INT NOT NULL,
    player_slot TINYINT UNSIGNED DEFAULT NULL COMMENT 'AMXX client slot, 1..32; correlation aid only',
    engine_userid INT UNSIGNED DEFAULT NULL COMMENT 'GoldSrc userid from the player log identity',
    boundary_kind VARCHAR(8) NOT NULL COMMENT 'start or end',
    reason VARCHAR(16) NOT NULL COMMENT 'spawn, context_live, death, or disconnect',
    team TINYINT UNSIGNED NOT NULL COMMENT '0=unassigned, 1=Allies, 2=Axis',
    player_class TINYINT UNSIGNED DEFAULT NULL COMMENT 'DoD class id at the boundary, when supplied',
    round_live TINYINT(1) DEFAULT NULL COMMENT 'reserved: NULL=unobservable in v1; future authoritative 1=live/0=paused',
    game_time DECIMAL(10,2) NOT NULL COMMENT 'get_gametime() seconds since map start',
    event_epoch BIGINT UNSIGNED NOT NULL COMMENT 'plugin get_systime() value; second precision',
    event_time DATETIME NOT NULL COMMENT 'FROM_UNIXTIME(event_epoch)',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (id),
    UNIQUE KEY uk_life_boundary
        (server_id, match_id, half, player_id, boundary_kind, reason, game_time),
    KEY idx_match_player_timeline (match_id, half, player_id, game_time, id),
    KEY idx_server_time (server_id, event_time),
    KEY idx_player_time (player_id, event_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Validated raw life start/end markers for per-life survival and KAT analytics';

-- Verify after an all-bot match:
--
--   SELECT match_id, half, player_id, player_slot, engine_userid,
--          boundary_kind, reason, team, player_class, round_live,
--          game_time, event_epoch, event_time
--   FROM ktp_life_events
--   ORDER BY match_id, half, player_id, game_time, id;
--
-- Idempotency check (should return zero rows):
--
--   SELECT server_id, match_id, half, player_id, boundary_kind, reason,
--          game_time, COUNT(*) AS copies
--   FROM ktp_life_events
--   GROUP BY server_id, match_id, half, player_id, boundary_kind, reason,
--            game_time
--   HAVING copies > 1;
