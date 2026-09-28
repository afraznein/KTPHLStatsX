-- ENGINE: mysql (hlstatsx on the data server -- NOT the Supabase editor)
-- KTP HLStatsX Migration 039: ktp_score_events.round_time_left (schema 25).
--
-- STATUS: proposed, not applied.
--
-- Apply once as: sudo mysql hlstatsx < migrate_039_score_round_time_left.sql
-- Idempotent: the column is added only when information_schema says it is
-- missing, so a second run is a DO 0.
--
-- DEPLOY ORDER: this migration, then the daemon, then the producer.
--   The daemon that writes this column names it in every score INSERT, so a
--   daemon ahead of this migration loses EVERY score row, not just the new
--   field. Schema ahead of code is harmless; code ahead of schema is data loss.
--
-- WHY. Schema 25 (ruled 2026-09-23) gives score rows the half clock that wave 1
-- (migration 032) already gave objective_attempt and flag_state rows. Without it
-- a tick or cap award can only be placed in the half by game_time, which resets
-- per map and does not say how much of the half was left.
--
-- Same column as 032's two: DECIMAL(7,1) seconds, DEFAULT NULL, from
-- dodx_get_round_time() at emit time. NULL = a producer that predates schema 25
-- (stats_logging < 1.26.1) or a malformed value. The producer's "no time limit"
-- -1.0 is stored as sent, exactly as it is on the other two tables.

SET @clauses := CONCAT_WS(', ',
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_score_events' AND COLUMN_NAME='round_time_left'), 'ADD COLUMN round_time_left DECIMAL(7,1) DEFAULT NULL COMMENT ''dodx_get_round_time() seconds at this score award; NULL from a producer before stats_logging 1.26.1''', NULL)
);
SET @ddl := IF(@clauses IS NULL OR @clauses = '', 'DO 0', CONCAT('ALTER TABLE ktp_score_events ', @clauses));
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Verify, once a 1.26.1 producer has played a half:
--
--   SELECT COUNT(*) AS n, SUM(round_time_left IS NULL) AS no_clock,
--          MIN(round_time_left), MAX(round_time_left)
--   FROM ktp_score_events
--   WHERE event_time >= '<first 1.26.1 half>';
