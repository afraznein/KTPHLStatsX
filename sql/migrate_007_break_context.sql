-- KTP HLStatsX Migration 007: break context, flag positions, last-flag-defense
-- Run on data server: mysql -u hlstatsx -p hlstatsx < migrate_007_break_context.sql
--
-- Pairs with KTPAMXX's ktp_stats_capture.inc, which now emits three things:
--
--   "Attacker<uid><steamid><Team>" triggered "flag_position" is NOT emitted
--   by a player -- it's a bare marker, no player string:
--     KTP_FLAG_POSITION (map "dod_anzio") (flag_index "0") (flag_name "...")
--       (x "1234") (y "-567")
--
--   "Breaker<uid><steamid><Team>" triggered "break_context"
--     (contester_count "3") (time_remaining "12.4") (is_capout "1")
--   -- a follow-up marker on cap_break, same shape frag_context's UPDATE
--   -- onto Frags uses, but this one UPDATEs the most recent matching
--   -- hlstats_Events_PlayerActions row instead.
--
--   frag_context (already handled by migrate_005/hlstats.pl event 901) gains
--   two more properties: (is_last_flag_defense "0"/"1"), plus (k_position "x
--   y z") / (v_position "x y z") -- those two land in Frags' EXISTING
--   pos_x/pos_y/pos_z and pos_victim_x/pos_victim_y/pos_victim_z columns
--   (stock HLStatsX schema already has them; no migration needed for
--   position itself, only for is_last_flag_defense).
--
-- Positions: killer/victim kill position land in stock hlstats_Events_Frags
-- columns (pos_x/y/z, pos_victim_x/y/z) -- already present, verified against
-- base-schema.sql, not something this migration adds. Break position already
-- lands in hlstats_Events_PlayerActions.pos_x/y/z the same way (Unit 4).
--
-- Idempotent on both MySQL and MariaDB, same information_schema-guarded
-- pattern as migrate_005/ktp_schema.sql. The new table uses plain
-- `CREATE TABLE IF NOT EXISTS`, which (unlike `ADD COLUMN IF NOT EXISTS`) is
-- standard SQL on both, so it needs no guard.
--
-- The database MUST be named on the command line -- see ktp_schema.sql's
-- header for why (DATABASE() is NULL otherwise and every guard chooses to
-- apply, so the first ALTER aborts the batch at ERROR 1046).

-- hlstats_Events_PlayerActions.contester_count
SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_PlayerActions'
                   AND COLUMN_NAME = 'contester_count');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE hlstats_Events_PlayerActions ADD COLUMN contester_count SMALLINT DEFAULT NULL');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- hlstats_Events_PlayerActions.time_remaining -- seconds, as a decimal
-- (CA_time_remaining is a float on the plugin side; kept as one here rather
-- than rounded to an integer, since "how close" is the whole point of it).
SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_PlayerActions'
                   AND COLUMN_NAME = 'time_remaining');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE hlstats_Events_PlayerActions ADD COLUMN time_remaining DECIMAL(6,1) DEFAULT NULL');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- hlstats_Events_PlayerActions.is_capout
SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_PlayerActions'
                   AND COLUMN_NAME = 'is_capout');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE hlstats_Events_PlayerActions ADD COLUMN is_capout TINYINT(1) NOT NULL DEFAULT 0');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- hlstats_Events_Frags.is_last_flag_defense
SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_Frags'
                   AND COLUMN_NAME = 'is_last_flag_defense');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE hlstats_Events_Frags ADD COLUMN is_last_flag_defense TINYINT(1) NOT NULL DEFAULT 0');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Static per-map flag positions. Keyed on (server_id, map_name, flag_index)
-- so a repeat map load (warmup, halftime reload) is an idempotent upsert,
-- not a growing table of duplicates.
CREATE TABLE IF NOT EXISTS ktp_flag_positions (
    id INT AUTO_INCREMENT,
    server_id INT UNSIGNED NOT NULL,
    map_name VARCHAR(32) NOT NULL,
    flag_index TINYINT NOT NULL,
    flag_name VARCHAR(32) NOT NULL,
    -- 2D only -- dodx.inc exposes no CP_origin_z.
    origin_x MEDIUMINT NOT NULL,
    origin_y MEDIUMINT NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    PRIMARY KEY (id),
    UNIQUE KEY uk_server_map_flag (server_id, map_name, flag_index),
    KEY idx_map (map_name)
    -- No FOREIGN KEY to hlstats_Servers: the HLStatsX base tables are
    -- MyISAM, which has no FK support -- same reason ktp_matches has none.
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Static per-flag (x,y) per map, for last-flag-defense / ninja-cap proximity checks';

-- Verify: expects 3 new PlayerActions columns, 1 new Frags column, and the
-- ktp_flag_positions table.
--
--   SELECT COLUMN_NAME FROM information_schema.COLUMNS
--   WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'hlstats_Events_PlayerActions'
--     AND COLUMN_NAME IN ('contester_count','time_remaining','is_capout');
--
--   SELECT COLUMN_NAME FROM information_schema.COLUMNS
--   WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'hlstats_Events_Frags'
--     AND COLUMN_NAME = 'is_last_flag_defense';
--
--   SELECT * FROM ktp_flag_positions;
--
-- Then, after a match with a cap break and some kills:
--
--   SELECT playerId, actionId, contester_count, time_remaining, is_capout,
--          pos_x, pos_y, pos_z
--   FROM hlstats_Events_PlayerActions
--   JOIN hlstats_Actions a ON a.id = actionId WHERE a.code = 'cap_break'
--   ORDER BY id DESC LIMIT 5;
--
--   SELECT killerId, victimId, is_last_flag_defense, pos_x, pos_y, pos_z,
--          pos_victim_x, pos_victim_y, pos_victim_z
--   FROM hlstats_Events_Frags ORDER BY id DESC LIMIT 10;
--
-- All-default rows after a match with real breaks/kills means the marker
-- isn't matching -- check `ktp_stats_capture` is 1 on the game server, then
-- look for the raw "break_context"/"flag_position" lines in the server log.
