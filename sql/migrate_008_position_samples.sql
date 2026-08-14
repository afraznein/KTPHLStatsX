-- KTP HLStatsX Migration 008: periodic roster-position samples
-- Run on data server: mysql -u hlstatsx -p hlstatsx < migrate_008_position_samples.sql
--
-- Pairs with KTPAMXX's ktp_stats_capture.inc, which emits, every
-- KSC_POSITION_BROADCAST_SECS (30s, a reasoned-not-measured starting value --
-- see the constant's own comment) for every connected, alive player:
--     "Player<uid><steamid><Team>" triggered "position_sample"
--     (team "1") (position "123 456 -78") (game_time "245.32")
--
-- Raw facts only, on purpose -- per the operator's direction on ninja-cap
-- detection (the other deliberately-deferred consumer of this exact same
-- data, see KTPInfrastructure's tests/e2e_stats/NEXT_PHASES.md), no
-- "is this player holding forward territory" / "is this a solo cap"
-- judgment happens in the plugin or the daemon. That classification belongs
-- entirely in the query layer, reading this table plus ktp_flag_positions.
--
-- Direct per-event INSERT, same shape as ktp_damage_events (migrate_006) --
-- not routed through the daemon's generic recordEvent/hlstats_Events_*
-- batching, which is config-driven around the stock event tables.
--
-- `CREATE TABLE IF NOT EXISTS` is standard SQL on both MySQL and MariaDB.

CREATE TABLE IF NOT EXISTS ktp_position_samples (
    id INT AUTO_INCREMENT,
    server_id INT UNSIGNED NOT NULL,
    match_id VARCHAR(64) DEFAULT NULL,
    half TINYINT NOT NULL DEFAULT 0 COMMENT '0=no match context, 1/2=half, 3+=OT',
    player_id INT NOT NULL,
    team TINYINT NOT NULL COMMENT '1=Allies, 2=Axis, per KSC_TEAM_ALLIES/AXIS',
    pos_x MEDIUMINT NOT NULL,
    pos_y MEDIUMINT NOT NULL,
    pos_z MEDIUMINT NOT NULL,
    game_time FLOAT NOT NULL COMMENT 'get_gametime() at the sample, seconds since map start',
    event_time DATETIME NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (id),
    KEY idx_server (server_id),
    KEY idx_match (match_id),
    KEY idx_player (player_id),
    KEY idx_event_time (event_time)
    -- No FOREIGN KEY to hlstats_Servers or hlstats_Players: the HLStatsX base
    -- tables are MyISAM, which has no FK support (same reason ktp_matches
    -- and ktp_damage_events have none).
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COMMENT='Periodic roster-position samples -- raw facts for positional/holding stats and ninja-cap detection, classified entirely at query time';

-- Verify: table exists with the expected columns.
--
--   SELECT COLUMN_NAME, DATA_TYPE FROM information_schema.COLUMNS
--   WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'ktp_position_samples'
--   ORDER BY ORDINAL_POSITION;
--
-- Then, after a match with real play:
--
--   SELECT player_id, team, pos_x, pos_y, pos_z, match_id, half, game_time
--   FROM ktp_position_samples ORDER BY id DESC LIMIT 10;
--
-- Expected volume at the 30s default and a full ~17-player roster: roughly
-- one row per player per 30s of ALIVE playtime -- same order of magnitude as
-- ktp_damage_events, not a new dominant volume source. A rate far above that
-- means the interval needs revisiting; zero rows during real play with
-- ktp_stats_capture enabled means the plugin isn't emitting or the daemon
-- isn't matching -- check the raw "position_sample" line in the server log
-- first to tell which side the gap is on, same diagnostic order
-- migrate_006's header recommends for the damage ledger.
