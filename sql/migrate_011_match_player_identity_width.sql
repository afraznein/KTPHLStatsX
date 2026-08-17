-- KTP HLStatsX Migration 011: allow full HLStatsX player identities in match rosters
--
-- HLStatsX represents bots as "BOT:" followed by a 32-character MD5, for a
-- total of 36 characters. ktp_match_players.steam_id was VARCHAR(32), so an
-- otherwise valid synthetic match produced one failed INSERT per participant
-- and left its match roster empty. Production Steam IDs fit either width; this
-- change removes the narrower constraint and lets the ephemeral Lane B match
-- exercise player tracking and match aggregation without truncating identity.
--
-- Idempotent in effect: repeating the ALTER leaves the same VARCHAR(64) shape.

ALTER TABLE ktp_match_players
    MODIFY COLUMN steam_id VARCHAR(64) NOT NULL;

-- Verify:
--
--   SELECT CHARACTER_MAXIMUM_LENGTH
--   FROM information_schema.COLUMNS
--   WHERE TABLE_SCHEMA = DATABASE()
--     AND TABLE_NAME = 'ktp_match_players'
--     AND COLUMN_NAME = 'steam_id';
--
-- Expected: 64.
