-- KTP HLStatsX Migration 017: producer clocks/context and canonical assists
-- Run after migrate_016_life_events.sql and before the coordinated AMXX plugin:
--   mysql -u hlstatsx -p hlstatsx < migrate_017_capture_clocks_and_assists.sql
--
-- Coordinated producer wire fields are named exactly:
--   (matchid "...") (half "...") (event_epoch "...") (game_time "...")
-- `frag_context` and `damage` retain their existing event paths; these columns
-- are additive. `assist` also retains its existing generic, rating-neutral
-- PlayerPlayerAction and gains the private canonical table below.
--
-- IMPORTANT FOR ANALYTICS: receipt-time hlstats match_id/half on damage/frags
-- remain for backward compatibility, but buffered delivery can cross a half
-- boundary. Timed analytics must filter/join on producer_match_id and
-- producer_half, and require non-NULL producer clocks.
--
-- hlstats_Events_Frags is MyISAM, so each ADD COLUMN and the index below is a
-- full rebuild of the schema's largest table under a write lock. Combine them
-- into one ALTER when applying, in an idle window -- the per-statement guards
-- keep either form idempotent.

-- hlstats_Events_Frags producer context and clocks (all nullable for old rows).
SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_Frags'
                   AND COLUMN_NAME = 'producer_match_id');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE hlstats_Events_Frags ADD COLUMN producer_match_id VARCHAR(64) DEFAULT NULL');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_Frags'
                   AND COLUMN_NAME = 'producer_half');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE hlstats_Events_Frags ADD COLUMN producer_half TINYINT UNSIGNED DEFAULT NULL');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_Frags'
                   AND COLUMN_NAME = 'game_time');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE hlstats_Events_Frags ADD COLUMN game_time DECIMAL(10,2) DEFAULT NULL COMMENT ''producer get_gametime() at kill''');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_Frags'
                   AND COLUMN_NAME = 'event_epoch');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE hlstats_Events_Frags ADD COLUMN event_epoch BIGINT UNSIGNED DEFAULT NULL COMMENT ''producer get_systime() at kill''');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @exists := (SELECT COUNT(*) FROM information_schema.STATISTICS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_Frags'
                   AND INDEX_NAME = 'idx_frag_producer_context');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE hlstats_Events_Frags ADD INDEX idx_frag_producer_context (producer_match_id, producer_half, event_epoch)');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- ktp_damage_events producer context and clock. Existing event_time is now
-- populated from FROM_UNIXTIME(event_epoch) when the new producer field exists;
-- old emitters keep the historical receipt-time fallback.
SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'ktp_damage_events'
                   AND COLUMN_NAME = 'producer_match_id');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE ktp_damage_events ADD COLUMN producer_match_id VARCHAR(64) DEFAULT NULL AFTER hitplace');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'ktp_damage_events'
                   AND COLUMN_NAME = 'producer_half');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE ktp_damage_events ADD COLUMN producer_half TINYINT UNSIGNED DEFAULT NULL AFTER producer_match_id');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'ktp_damage_events'
                   AND COLUMN_NAME = 'event_epoch');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE ktp_damage_events ADD COLUMN event_epoch BIGINT UNSIGNED DEFAULT NULL AFTER game_time');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @exists := (SELECT COUNT(*) FROM information_schema.STATISTICS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'ktp_damage_events'
                   AND INDEX_NAME = 'idx_damage_producer_context');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE ktp_damage_events ADD INDEX idx_damage_producer_context (producer_match_id, producer_half, event_epoch)');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Canonical, private assist ledger. The existing hlstats action is preserved;
-- this table is additive and does not award or alter skill/rating points.
CREATE TABLE IF NOT EXISTS ktp_assist_events (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    server_id INT UNSIGNED NOT NULL,
    match_id VARCHAR(64) NOT NULL,
    half TINYINT UNSIGNED NOT NULL COMMENT 'producer half validated against event-time match interval',
    map_name VARCHAR(32) NOT NULL,
    assister_id INT NOT NULL,
    victim_id INT NOT NULL,
    assister_pos_x INT DEFAULT NULL,
    assister_pos_y INT DEFAULT NULL,
    assister_pos_z INT DEFAULT NULL,
    victim_pos_x INT DEFAULT NULL,
    victim_pos_y INT DEFAULT NULL,
    victim_pos_z INT DEFAULT NULL,
    game_time DECIMAL(10,2) NOT NULL COMMENT 'producer get_gametime() at victim death',
    event_epoch BIGINT UNSIGNED NOT NULL COMMENT 'producer get_systime() at victim death',
    event_time DATETIME NOT NULL COMMENT 'FROM_UNIXTIME(event_epoch), never daemon receipt time',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (id),
    UNIQUE KEY uk_ktp_assist
        (server_id, match_id, half, assister_id, victim_id, game_time),
    KEY idx_match_timeline (match_id, half, game_time, id),
    KEY idx_assister_time (assister_id, event_time),
    KEY idx_victim_time (victim_id, event_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Canonical producer-time assist facts; generic rating-neutral action remains intact';

-- Verification:
--   SELECT producer_match_id, producer_half, game_time, event_epoch
--   FROM hlstats_Events_Frags ORDER BY id DESC LIMIT 5;
--   SELECT producer_match_id, producer_half, game_time, event_epoch, event_time
--   FROM ktp_damage_events ORDER BY id DESC LIMIT 5;
--   SELECT match_id, half, assister_id, victim_id, game_time, event_epoch
--   FROM ktp_assist_events ORDER BY id DESC LIMIT 5;
