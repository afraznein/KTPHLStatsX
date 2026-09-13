-- KTP HLStatsX Migration 027: shot-context stream.
-- Run on data server: mysql -u hlstatsx -p hlstatsx < migrate_027_shot_events.sql
--
-- Pairs with KTPAMXX's ktp_stats_capture.inc wave 0 (dod_client_weapon_fire),
-- which emits, on every weapon actuation:
--     "Player<uid><steamid><Team>" triggered "shot"
--     (weapon_id "10") (position "123 456 -78") (yaw "45.20") (pitch "-3.10")
--     (prone "0") (map "dod_anzio") (matchid "...") (half "1")
--     (game_time "245.32") (event_epoch "...") (sequence "...")
--
-- Deliberately NOT a duplicate of the anti-cheat per-shot ledger
-- (ktp_ac_weapon_fires, with aim geometry from dodx_get_shot_geom) -- this
-- table carries only what that one lacks: where the shooter was standing and
-- facing. Joining the two is expected to happen at query time on
-- (steam_id/player identity, weapon_id, nearest game_time/event_epoch), the
-- same nearest-timestamp technique frag_context's correlation already uses in
-- production (~99.4% success, see FRAG_CONTEXT_COVERAGE_TRIAGE_20260906.md).
--
-- Direct per-event INSERT, same shape as ktp_position_samples (migrate_008)
-- and ktp_damage_events (migrate_006) -- not routed through the generic
-- hlstats_Events_* batching, and not accumulated in Perl before the flush:
-- see the paired daemon change (doEvent_KTPShot) for the batched multi-row
-- INSERT this stream is expected to run through instead of one INSERT per
-- row (this is the first ktp_* stream sized to need it).
--
-- `CREATE TABLE IF NOT EXISTS` is standard SQL on both MySQL and MariaDB.

CREATE TABLE IF NOT EXISTS ktp_shot_events (
    id BIGINT UNSIGNED AUTO_INCREMENT,
    server_id INT UNSIGNED NOT NULL,
    match_id VARCHAR(64) DEFAULT NULL,
    half TINYINT NOT NULL DEFAULT 0 COMMENT '0=no match context, 1/2=half, 3+=OT',
    player_id INT NOT NULL,
    weapon_id SMALLINT UNSIGNED NOT NULL,
    pos_x MEDIUMINT NOT NULL,
    pos_y MEDIUMINT NOT NULL,
    pos_z MEDIUMINT NOT NULL,
    yaw DECIMAL(6,2) NOT NULL,
    pitch DECIMAL(6,2) NOT NULL,
    -- dodx pronestate verbatim: 0 upright, 1 prone, 2 prone with the weapon
    -- deployed. There is deliberately no separate `deployed` column -- the
    -- producer's only candidate was a dodfun native it does not depend on and
    -- which did not compile (KTPAMXX #106), and deriving one from pronestate
    -- would catch prone deploys only. Full deploy state wants a dodx accessor.
    prone TINYINT UNSIGNED NOT NULL DEFAULT 0,
    map_name VARCHAR(32) NOT NULL,
    game_time FLOAT NOT NULL COMMENT 'the forward''s own gametime param, seconds since map start',
    event_epoch BIGINT UNSIGNED DEFAULT NULL COMMENT 'producer wall-clock, for AC-ledger join',
    producer_sequence BIGINT UNSIGNED DEFAULT NULL,
    event_time DATETIME NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (id),
    KEY idx_server (server_id),
    KEY idx_match (match_id),
    KEY idx_player (player_id),
    KEY idx_event_time (event_time),
    -- The AC-ledger join path: player + weapon + a small time window.
    KEY idx_join (player_id, weapon_id, event_time)
    -- No FOREIGN KEY to hlstats_Servers/hlstats_Players: the HLStatsX base
    -- tables are MyISAM, same reason ktp_position_samples has none.
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Shooter position/facing on every weapon actuation -- joins to ktp_ac_weapon_fires for full per-shot context';

-- Verify: table exists with the expected columns.
--
--   SELECT COLUMN_NAME, DATA_TYPE FROM information_schema.COLUMNS
--   WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'ktp_shot_events'
--   ORDER BY ORDINAL_POSITION;
--
-- Then, after a match with real play:
--
--   SELECT player_id, weapon_id, pos_x, pos_y, pos_z, yaw, pitch, match_id,
--          half, game_time
--   FROM ktp_shot_events ORDER BY id DESC LIMIT 10;
--
-- Expected volume: ~2,500 rows per 12-player match (measured against
-- ktp_ac_weapon_fires, 2026-09-01..09), bursting to ~120/s during a heavy
-- engagement -- an order of magnitude above ktp_position_samples' rate. Zero
-- rows during real play with ktp_stats_shots enabled means either the plugin
-- isn't emitting (check the raw "shot" line in the server log) or the
-- batched insert isn't matching -- same diagnostic order migrate_008's
-- header recommends for position samples.
