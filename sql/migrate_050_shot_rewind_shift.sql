-- ENGINE: mysql (hlstatsx on the data server -- NOT the Supabase editor)
-- KTP HLStatsX Migration 050: shot-row tgt_shift, how far the shooter's rewind
-- moved the victim from where the victim really was (stats_logging 1.34.0).
--
-- STATUS: proposed, not applied.
--
-- Apply once as: sudo mysql hlstatsx < migrate_050_shot_rewind_shift.sql
-- Idempotent: the column is added only when information_schema says it is
-- missing, so a second run is a DO 0.
--
-- DEPLOY ORDER: this migration, then the daemon. The daemon names tgt_shift in
--   every batched shot INSERT, so a daemon ahead of this migration loses EVERY
--   shot row. Schema ahead of code is harmless; code ahead of schema is data
--   loss. The producer can go in any order against both: an older producer sends
--   no tgt_shift and the daemon stores NULL. No KSC_SCHEMA_CONTRACT bump.
--
-- WHY. In 15 12-mans, settings changed neither hit registration (99.97%) nor
-- whether the rewind reached its target, and the rewind ran about 100 ms deep at
-- the median. What that depth costs the player on the other end is how far they
-- had moved, on their own screen, by the time the shot was judged: the "died
-- behind the wall". The engine (KTP-ReHLDS ktp_rewind_shift_v1) holds both of the
-- victim's origins during the shooter's rewind, and dodx stamps the distance at
-- trace time with the rest of the target group. On LAN it is a few units.
--
-- NULL semantics: NULL is "no value", never 0. 0 is real (the rewind did not move
-- the victim). The producer's -1 (an engine without the API, a trace outside the
-- shooter's rewind window, or no target state) is stored as NULL. A producer
-- before 1.34.0 sends nothing and the row lands NULL.

SET @clauses := CONCAT_WS(', ',
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_shot_events' AND COLUMN_NAME='tgt_shift'), 'ADD COLUMN tgt_shift SMALLINT UNSIGNED DEFAULT NULL COMMENT ''units: how far the shooter''''s rewind moved the victim from its true origin when the shot was judged; NULL when the shot has no target state, the engine lacks ktp_rewind_shift_v1, or the producer predates stats_logging 1.34.0''', NULL)
);
SET @ddl := IF(@clauses IS NULL OR @clauses = '', 'DO 0', CONCAT('ALTER TABLE ktp_shot_events ', @clauses));
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Verify, once a 1.34.0 producer on an engine with ktp_rewind_shift_v1 has played a human half:
--
--   SELECT COUNT(*) AS hits, SUM(tgt_shift IS NOT NULL) AS with_shift,
--          AVG(tgt_shift) AS mean_units, MAX(tgt_shift) AS max_units
--   FROM ktp_shot_events
--   WHERE event_time >= '<first 1.34.0 half>' AND tgt_dead = 0;
