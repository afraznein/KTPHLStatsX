-- KTP HLStatsX Schema Migration
-- Adds match tracking support for KTP Match Handler integration
-- Version: 0.3.3
--
-- ⚠️ DO NOT RUN THIS FILE AS-IS ON MySQL. The match_id block below uses
-- ADD COLUMN IF NOT EXISTS / CREATE INDEX IF NOT EXISTS, which is MariaDB-only
-- syntax — MySQL rejects it at every version (the comment further down says so,
-- and the `half` block is written correctly for MySQL). `mysql < this_file`
-- aborts at the first ALTER and applies NOTHING after it.
--
-- Verified 2026-07-20 on the live data server (MySQL 8.0.46): the match_id
-- columns DO exist on Frags / Teamkills / PlayerActions, so production was
-- populated by some other path. The hazard is a FRESH install — notably LAN
-- data-server provisioning — where this file silently applies almost nothing.
-- Apply the match_id block by hand, or port it to plain ALTER first.

-- ============================================================================
-- Add match_id column to event tables
-- ============================================================================

-- Add match_id to hlstats_Events_Frags (kill events)
ALTER TABLE hlstats_Events_Frags
ADD COLUMN IF NOT EXISTS match_id VARCHAR(64) DEFAULT NULL AFTER map;

CREATE INDEX IF NOT EXISTS idx_match_id ON hlstats_Events_Frags (match_id);

-- Add match_id to hlstats_Events_Teamkills
ALTER TABLE hlstats_Events_Teamkills
ADD COLUMN IF NOT EXISTS match_id VARCHAR(64) DEFAULT NULL AFTER map;

CREATE INDEX IF NOT EXISTS idx_match_id ON hlstats_Events_Teamkills (match_id);

-- Add match_id to hlstats_Events_Suicides
ALTER TABLE hlstats_Events_Suicides
ADD COLUMN IF NOT EXISTS match_id VARCHAR(64) DEFAULT NULL AFTER map;

CREATE INDEX IF NOT EXISTS idx_match_id ON hlstats_Events_Suicides (match_id);

-- Add match_id to hlstats_Events_PlayerActions
ALTER TABLE hlstats_Events_PlayerActions
ADD COLUMN IF NOT EXISTS match_id VARCHAR(64) DEFAULT NULL AFTER map;

CREATE INDEX IF NOT EXISTS idx_match_id ON hlstats_Events_PlayerActions (match_id);

-- ============================================================================
-- Add half column to event tables (for per-half stat aggregation)
-- Convention: 0=full match total (backward compat), 1=1st half, 2=2nd half, 3+=OT rounds
-- Note: MySQL 8.0 does not support ADD COLUMN IF NOT EXISTS
-- ============================================================================

ALTER TABLE hlstats_Events_Frags ADD COLUMN half TINYINT NOT NULL DEFAULT 0;
ALTER TABLE hlstats_Events_Teamkills ADD COLUMN half TINYINT NOT NULL DEFAULT 0;
ALTER TABLE hlstats_Events_Suicides ADD COLUMN half TINYINT NOT NULL DEFAULT 0;
ALTER TABLE hlstats_Events_Statsme ADD COLUMN half TINYINT NOT NULL DEFAULT 0;

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
    start_time DATETIME NOT NULL,
    end_time DATETIME DEFAULT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (id),
    UNIQUE KEY uk_match_id_half (match_id, half),
    KEY idx_server (server_id),
    KEY idx_start_time (start_time),
    KEY idx_map (map_name)
    -- No FOREIGN KEY to hlstats_Servers: the HLStatsX base tables are MyISAM,
    -- which has no FK support, so an InnoDB FK referencing it fails with errno
    -- 1824. server_id stays an indexed column; integrity is enforced app-side.
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COMMENT='KTP match metadata - tracks match boundaries';

-- Players participating in each match
CREATE TABLE IF NOT EXISTS ktp_match_players (
    id INT AUTO_INCREMENT,
    match_id VARCHAR(64) NOT NULL,
    player_id INT NOT NULL,
    steam_id VARCHAR(32) NOT NULL,
    player_name VARCHAR(64) NOT NULL,
    team TINYINT NOT NULL COMMENT '1=Allies, 2=Axis',
    joined_at DATETIME NOT NULL,

    PRIMARY KEY (id),
    UNIQUE KEY uk_match_player (match_id, player_id),
    KEY idx_match (match_id),
    KEY idx_player (player_id),
    KEY idx_steam (steam_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COMMENT='Players participating in KTP matches';

-- Aggregated match statistics per player per half (computed from events)
-- half=0: full match total, half=1: 1st half, half=2: 2nd half, half=3+: OT rounds
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
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
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
