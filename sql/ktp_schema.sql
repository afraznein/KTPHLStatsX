-- KTP HLStatsX Schema Migration
-- Adds match tracking support for KTP Match Handler integration
--
-- Runs on MySQL 8.0 and MariaDB, and is idempotent in both directions: a fresh
-- database and an already-applied one both succeed. Apply with
--
--     mysql <database> < ktp_schema.sql
--
-- The database MUST be named on the command line. With none selected DATABASE()
-- is NULL, every guard below finds nothing, and each guard therefore chooses to
-- APPLY rather than skip — so the first ALTER aborts the batch with
-- "ERROR 1046 (3D000): No database selected" before anything has run. Verified;
-- the file cannot silently do nothing and report success.
--
-- WHY THE ALTERs LOOK LIKE THIS. MariaDB has ADD COLUMN IF NOT EXISTS and
-- CREATE INDEX IF NOT EXISTS; MySQL has neither, at any version, and rejects
-- them with ERROR 1064. Because the file is applied as one batch, the first
-- rejection aborts everything after it — so on MySQL the old file applied
-- almost nothing and said so only once. Each change is therefore guarded by an
-- information_schema lookup and run through a prepared statement, which is
-- plain SQL and needs no privilege the migration does not already have.
--
-- Bare `ALTER TABLE ... ADD COLUMN` is not an alternative: it is ERROR 1060 on
-- a database that already has the column, which is the path production takes.
--
-- ⚠️ This file is DECLARATIVE — it creates whatever is absent. As of
-- 2026-08-11 the live database is missing idx_match_id on Teamkills, Suicides
-- and PlayerActions, so running it there is NOT a no-op: it will build those
-- three indexes (a MyISAM table rebuild). Check before assuming it is free.

-- ============================================================================
-- Add match_id column to event tables
-- ============================================================================

-- hlstats_Events_Frags (kill events)
SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_Frags'
                   AND COLUMN_NAME = 'match_id');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE hlstats_Events_Frags ADD COLUMN match_id VARCHAR(64) DEFAULT NULL AFTER map');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @exists := (SELECT COUNT(*) FROM information_schema.STATISTICS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_Frags'
                   AND INDEX_NAME = 'idx_match_id');
SET @ddl := IF(@exists > 0, 'DO 0',
    'CREATE INDEX idx_match_id ON hlstats_Events_Frags (match_id)');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- hlstats_Events_Teamkills
SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_Teamkills'
                   AND COLUMN_NAME = 'match_id');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE hlstats_Events_Teamkills ADD COLUMN match_id VARCHAR(64) DEFAULT NULL AFTER map');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @exists := (SELECT COUNT(*) FROM information_schema.STATISTICS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_Teamkills'
                   AND INDEX_NAME = 'idx_match_id');
SET @ddl := IF(@exists > 0, 'DO 0',
    'CREATE INDEX idx_match_id ON hlstats_Events_Teamkills (match_id)');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- hlstats_Events_Suicides
SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_Suicides'
                   AND COLUMN_NAME = 'match_id');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE hlstats_Events_Suicides ADD COLUMN match_id VARCHAR(64) DEFAULT NULL AFTER map');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @exists := (SELECT COUNT(*) FROM information_schema.STATISTICS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_Suicides'
                   AND INDEX_NAME = 'idx_match_id');
SET @ddl := IF(@exists > 0, 'DO 0',
    'CREATE INDEX idx_match_id ON hlstats_Events_Suicides (match_id)');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- hlstats_Events_PlayerActions
SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_PlayerActions'
                   AND COLUMN_NAME = 'match_id');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE hlstats_Events_PlayerActions ADD COLUMN match_id VARCHAR(64) DEFAULT NULL AFTER map');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @exists := (SELECT COUNT(*) FROM information_schema.STATISTICS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_PlayerActions'
                   AND INDEX_NAME = 'idx_match_id');
SET @ddl := IF(@exists > 0, 'DO 0',
    'CREATE INDEX idx_match_id ON hlstats_Events_PlayerActions (match_id)');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- ============================================================================
-- Add half column to event tables (for per-half stat aggregation)
-- 1=1st half, 2=2nd half, 3+=OT rounds. 0 means the daemon held no match
-- context when the line arrived -- warmup, practice, between halves. It is NOT
-- a match total: recordEvent is the only insert path here and never writes an
-- aggregate row. Totals are ktp_match_stats.half=0, further down.
-- half and match_id may disagree: freeze-time events keep their half but are
-- deliberately left untagged.
-- ============================================================================

SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_Frags' AND COLUMN_NAME = 'half');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE hlstats_Events_Frags ADD COLUMN half TINYINT NOT NULL DEFAULT 0');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_Teamkills' AND COLUMN_NAME = 'half');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE hlstats_Events_Teamkills ADD COLUMN half TINYINT NOT NULL DEFAULT 0');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_Suicides' AND COLUMN_NAME = 'half');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE hlstats_Events_Suicides ADD COLUMN half TINYINT NOT NULL DEFAULT 0');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_Statsme' AND COLUMN_NAME = 'half');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE hlstats_Events_Statsme ADD COLUMN half TINYINT NOT NULL DEFAULT 0');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- ============================================================================
-- Create KTP match tables
-- ============================================================================

-- Match metadata table
CREATE TABLE IF NOT EXISTS ktp_matches (
    id INT AUTO_INCREMENT,
    match_id VARCHAR(64) NOT NULL,
    -- INT UNSIGNED to match hlstats_Servers.serverId; a plain INT FK fails on
    -- MySQL with errno 1824 (referenced-table open failure on a type mismatch).
    server_id INT UNSIGNED NOT NULL,
    map_name VARCHAR(32) NOT NULL,
    half TINYINT DEFAULT 1 COMMENT '1=first half, 2=second half',
    match_type TINYINT UNSIGNED DEFAULT NULL COMMENT 'KTPMatchHandler enum: 0=official, 1=scrim, 2=12man, 3=draft, 4=KTP OT, 5=draft OT',
    start_time DATETIME NOT NULL,
    end_time DATETIME DEFAULT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (id),
    UNIQUE KEY uk_match_id_half (match_id, half),
    KEY idx_server (server_id),
    KEY idx_start_time (start_time),
    KEY idx_retention (match_type, start_time),
    KEY idx_map (map_name)
    -- No FOREIGN KEY to hlstats_Servers: the HLStatsX base tables are MyISAM,
    -- which has no FK support, so an InnoDB FK referencing it fails with errno
    -- 1824. server_id stays an indexed column; integrity is enforced app-side.
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='KTP match metadata - tracks match boundaries';

-- Players participating in each match
CREATE TABLE IF NOT EXISTS ktp_match_players (
    id INT AUTO_INCREMENT,
    match_id VARCHAR(64) NOT NULL,
    player_id INT NOT NULL,
    -- HLStatsX bot identities are "BOT:" plus a 32-character MD5 (36 total).
    -- Real Steam IDs are shorter, but the wider column lets isolated bot
    -- regression matches exercise the same match-roster path.
    steam_id VARCHAR(64) NOT NULL,
    player_name VARCHAR(64) NOT NULL,
    team TINYINT NOT NULL COMMENT '1=Allies, 2=Axis',
    joined_at DATETIME NOT NULL,

    PRIMARY KEY (id),
    UNIQUE KEY uk_match_player (match_id, player_id),
    KEY idx_match (match_id),
    KEY idx_player (player_id),
    KEY idx_steam (steam_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Players participating in KTP matches';

-- Aggregated match statistics per player per half (computed from events)
-- half=1: 1st half, half=2: 2nd half, half=3+: OT rounds. Unlike the event
-- tables above, half=0 here IS a real full-match total, written at
-- KTP_MATCH_END by summing this table's own half>0 rows.
CREATE TABLE IF NOT EXISTS ktp_match_stats (
    id INT AUTO_INCREMENT,
    match_id VARCHAR(64) NOT NULL,
    player_id INT NOT NULL,
    half TINYINT NOT NULL DEFAULT 0,
    kills INT DEFAULT 0,
    deaths INT DEFAULT 0,
    headshots INT DEFAULT 0,
    team_kills INT DEFAULT 0,
    suicides INT DEFAULT 0,
    damage INT DEFAULT 0,
    score INT DEFAULT 0,

    PRIMARY KEY (id),
    UNIQUE KEY uk_match_player_half (match_id, player_id, half),
    KEY idx_match (match_id),
    KEY idx_player (player_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Aggregated player stats per KTP match per half';

-- ============================================================================
-- Useful views for querying match data
-- ============================================================================

-- View: Match leaderboard with K/D ratio (uses half=0 totals)
CREATE OR REPLACE VIEW ktp_match_leaderboard AS
SELECT
    m.match_id,
    m.map_name,
    m.start_time,
    m.end_time,
    p.lastName AS player_name,
    mp.steam_id,
    mp.team,
    COALESCE(ms.kills, 0) AS kills,
    COALESCE(ms.deaths, 0) AS deaths,
    COALESCE(ms.headshots, 0) AS headshots,
    COALESCE(ms.team_kills, 0) AS team_kills,
    COALESCE(ms.damage, 0) AS damage,
    COALESCE(ms.score, 0) AS score,
    CASE WHEN COALESCE(ms.deaths, 0) > 0
         THEN ROUND(COALESCE(ms.kills, 0) / ms.deaths, 2)
         ELSE COALESCE(ms.kills, 0) END AS kd_ratio
FROM ktp_matches m
JOIN ktp_match_players mp ON m.match_id = mp.match_id
JOIN hlstats_Players p ON mp.player_id = p.playerId
LEFT JOIN ktp_match_stats ms ON m.match_id = ms.match_id AND mp.player_id = ms.player_id AND ms.half = 0
ORDER BY m.start_time DESC, ms.kills DESC;

-- View: Recent matches summary
CREATE OR REPLACE VIEW ktp_recent_matches AS
SELECT
    m.match_id,
    m.map_name,
    m.start_time,
    m.end_time,
    TIMEDIFF(m.end_time, m.start_time) AS duration,
    (SELECT COUNT(*) FROM ktp_match_players WHERE match_id = m.match_id) AS player_count,
    (SELECT SUM(kills) FROM ktp_match_stats WHERE match_id = m.match_id AND half = 0) AS total_kills,
    s.name AS server_name
FROM ktp_matches m
JOIN hlstats_Servers s ON m.server_id = s.serverId
WHERE m.half = 1  -- Only show first half entry (one row per match)
ORDER BY m.start_time DESC
LIMIT 50;

-- ============================================================================
-- Sample queries for match vs non-match separation
-- ============================================================================

-- Count match vs non-match kills (for verification)
-- SELECT
--     CASE WHEN match_id IS NULL THEN 'Warmup/Practice' ELSE 'Match' END AS type,
--     COUNT(*) AS kill_count
-- FROM hlstats_Events_Frags
-- WHERE eventTime > DATE_SUB(NOW(), INTERVAL 7 DAY)
-- GROUP BY (match_id IS NULL);

-- Get specific match stats
-- SELECT
--     killerId,
--     COUNT(*) AS kills,
--     SUM(headshot) AS headshots
-- FROM hlstats_Events_Frags
-- WHERE match_id = 'KTP-1734355200-dod_charlie'
-- GROUP BY killerId
-- ORDER BY kills DESC;
