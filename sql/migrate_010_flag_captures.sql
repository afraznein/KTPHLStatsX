-- KTP HLStatsX Migration 010: per-player flag-capture completions
-- Run on data server: mysql -u hlstatsx -p hlstatsx < migrate_010_flag_captures.sql
--
-- Persists DoD 1.3's own "dod_capture_area" engine event, previously parsed
-- for exploration only (see KTPInfrastructure's composite_v2.py, which reads
-- the raw log directly), never recorded to the DB -- no hlstats_Actions row
-- existed for it, so recordEvent's generic dispatcher silently discarded
-- every one, the same silent-discard failure mode CHANGELOG.md's 0.3.5 entry
-- describes for dod_control_point/dod_capture_area at the Philly LAN.
--
-- No hlstats_Actions seed needed here, on purpose: rather than fight the
-- generic PlayerActions dispatcher for a shape it was never built for --
-- DoD 1.3's own log line is a bare dash-suffixed quoted point name,
-- "Player<uid><steamid><Team>" triggered a "dod_capture_area" - "POINT_NAME",
-- not the parenthesized (key "val") properties getProperties() parses --
-- this is a direct per-event INSERT, same shape as ktp_position_samples
-- (migrate_008) and ktp_damage_events (migrate_006).
--
-- One row per capping player. DoD 1.3's own capture mechanic requires some
-- points to have two players standing on them simultaneously to complete a
-- cap (others need only one) -- the engine logs one line per capping player
-- plus a redundant team-level line carrying no information the per-player
-- rows don't already have, which is why that team-level line is left
-- unhandled rather than double-recorded. How many players a given point
-- structurally requires is derivable at query time by counting rows sharing
-- the same (flag_name, event_time) pair -- not stored as its own column,
-- consistent with ktp_position_samples' "raw facts, classify at query time"
-- convention.
--
-- `CREATE TABLE IF NOT EXISTS` is standard SQL on both MySQL and MariaDB.

CREATE TABLE IF NOT EXISTS ktp_flag_captures (
    id INT AUTO_INCREMENT,
    server_id INT UNSIGNED NOT NULL,
    match_id VARCHAR(64) DEFAULT NULL,
    half TINYINT NOT NULL DEFAULT 0 COMMENT '0=no match context, 1/2=half, 3+=OT',
    player_id INT NOT NULL,
    team VARCHAR(16) DEFAULT NULL COMMENT 'Allies/Axis, straight from the engine player string -- not KSC_TEAM_*''s numeric convention, that''s KTPAMXX-side only',
    flag_name VARCHAR(64) DEFAULT NULL COMMENT 'engine point name, e.g. POINT_ANZIO_PLAZA; NULL if the trailing dash-quoted name failed to parse',
    event_time DATETIME NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (id),
    KEY idx_server (server_id),
    KEY idx_match (match_id),
    KEY idx_player (player_id),
    KEY idx_event_time (event_time)
    -- No FOREIGN KEY to hlstats_Servers or hlstats_Players: the HLStatsX base
    -- tables are MyISAM, which has no FK support (same reason ktp_matches,
    -- ktp_damage_events and ktp_position_samples have none).
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Per-player DoD 1.3 flag-capture completions -- raw facts, multi-capper detection is a query-time GROUP BY on (flag_name, event_time), not a stored column';

-- Verify: table exists with the expected columns.
--
--   SELECT COLUMN_NAME, DATA_TYPE FROM information_schema.COLUMNS
--   WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'ktp_flag_captures'
--   ORDER BY ORDINAL_POSITION;
--
-- Then, after a match with real captures:
--
--   SELECT player_id, team, flag_name, match_id, half, event_time
--   FROM ktp_flag_captures ORDER BY id DESC LIMIT 10;
--
-- Two-capper points identifiable via:
--
--   SELECT flag_name, event_time, COUNT(*) AS cappers
--   FROM ktp_flag_captures GROUP BY flag_name, event_time HAVING cappers > 1;
--
-- Zero rows during a match with real captures means either the plugin-side
-- log line changed shape (check the raw "dod_capture_area" line in the
-- server log against this file's header comment) or the "- \"POINT_NAME\""
-- parse is failing silently -- flag_name would land NULL in that case rather
-- than the row being dropped, so check for that first.
