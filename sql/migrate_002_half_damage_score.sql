-- KTP HLStatsX Migration 002: Per-half stats with damage and score
-- Run on data server: mysql -u hlstatsx -p hlstatsx < migrate_002_half_damage_score.sql
-- Requires MySQL 8.0+ (no IF NOT EXISTS for ADD COLUMN)
--
-- Convention: half=1 = 1st half, half=2 = 2nd half, half=3+ = OT rounds.
-- half=0 means "no match context" on the event tables below and "full match
-- total" on ktp_match_stats -- the same value, two different meanings. See the
-- notes in ktp_schema.sql before writing a query against either.
--
-- APPLIED: 2026-03-03 on neindataatl (74.91.112.242)

-- ============================================================================
-- 1. Add half column to event tables used in aggregation
-- ============================================================================

ALTER TABLE hlstats_Events_Frags ADD COLUMN half TINYINT NOT NULL DEFAULT 0;
ALTER TABLE hlstats_Events_Teamkills ADD COLUMN half TINYINT NOT NULL DEFAULT 0;
ALTER TABLE hlstats_Events_Suicides ADD COLUMN half TINYINT NOT NULL DEFAULT 0;
ALTER TABLE hlstats_Events_Statsme ADD COLUMN half TINYINT NOT NULL DEFAULT 0;

-- ============================================================================
-- 2. Add half column to ktp_match_stats and update unique key
-- ============================================================================

ALTER TABLE ktp_match_stats ADD COLUMN half TINYINT NOT NULL DEFAULT 0 AFTER player_id;

-- Replace uk_match_player with uk_match_player_half
-- (existing rows keep half=0 which means "full match total")
ALTER TABLE ktp_match_stats DROP INDEX uk_match_player;
ALTER TABLE ktp_match_stats ADD UNIQUE KEY uk_match_player_half (match_id, player_id, half);

-- ============================================================================
-- 3. Update views to use half=0 for totals
-- ============================================================================

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
WHERE m.half = 1
ORDER BY m.start_time DESC
LIMIT 50;
