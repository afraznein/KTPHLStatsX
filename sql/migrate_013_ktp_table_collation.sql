-- KTP HLStatsX Migration 013: normalize KTP table collations
-- Run before deploying daemon 0.3.8 or later:
--   mysql -u hlstatsx -p hlstatsx < migrate_013_ktp_table_collation.sql
--
-- MySQL 8 can default newly-created utf8mb4 tables to utf8mb4_0900_ai_ci while
-- the existing HLStatsX tables use utf8mb4_unicode_ci. KTP joins event-table
-- match IDs to KTP match IDs, so every KTP-owned text column must use the same
-- collation as the existing HLStatsX schema.

ALTER TABLE ktp_matches
    CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE ktp_match_players
    CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE ktp_match_stats
    CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE ktp_damage_events
    CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE ktp_flag_positions
    CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE ktp_position_samples
    CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE ktp_flag_captures
    CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Verify: every row should report utf8mb4_unicode_ci.
--
--   SELECT TABLE_NAME, TABLE_COLLATION
--   FROM information_schema.TABLES
--   WHERE TABLE_SCHEMA = DATABASE()
--     AND TABLE_NAME IN ('ktp_matches', 'ktp_match_players',
--       'ktp_match_stats', 'ktp_damage_events', 'ktp_flag_positions',
--       'ktp_position_samples', 'ktp_flag_captures');
