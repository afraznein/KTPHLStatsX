-- ENGINE: mysql (hlstatsx on the data server -- NOT the Supabase editor)
-- KTP HLStatsX Migration 040: ktp_flag_captures provenance + source pointer.
--
-- STATUS: proposed, not applied.
--
-- Apply once as: sudo mysql hlstatsx < migrate_040_flag_captures_provenance.sql
-- Idempotent: each column and the index are added only when information_schema
-- says they are missing, so a second run is a DO 0.
--
-- DEPLOY ORDER: this migration, THEN scripts/backfill-flag-captures-inferred.py.
--   No daemon change and no restart. hlstats.pl names its columns on the one
--   INSERT into this table (doEvent_KTPFlagCapture), so live rows take the
--   DEFAULT 'recorded' and the daemon never needs to know the columns exist.
--   The backfill refuses to write until both columns are present.
--
-- WHY. The table starts at its own go-live; every earlier capture survives only
-- in hlstats_Events_PlayerActions (dod_capture_area / dod_control_point). A
-- backfill from there has to derive half and side after the fact and cannot
-- recover the flag name at all. Without a marker those derived values become
-- indistinguishable from the ones the daemon measured live, permanently.
--
--   provenance = 'recorded'  written live by the daemon (every existing row)
--              = 'inferred'  written by the backfill; half/team derived later,
--                            flag_name NULL because the source never carried it
--   source_action_id         hlstats_Events_PlayerActions.id an inferred row came
--                            from; NULL on recorded rows. Unique, so a re-run of
--                            the backfill cannot insert the same capture twice.
--                            Several NULLs are allowed by a UNIQUE key, which is
--                            what recorded rows need.
--
-- To undo a backfill without touching live data:
--   DELETE FROM ktp_flag_captures WHERE provenance = 'inferred';
--
-- Consumers: a capture COUNT may include inferred rows; anything that reads
-- half, team or flag_name as a measurement must filter provenance = 'recorded'
-- or render inferred values as derived. A NULL flag_name is absent, never blank.

SET @clauses := CONCAT_WS(', ',
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_flag_captures' AND COLUMN_NAME='provenance'),
       'ADD COLUMN provenance ENUM(''recorded'',''inferred'') NOT NULL DEFAULT ''recorded'' COMMENT ''recorded = written live by the daemon; inferred = backfilled from hlstats_Events_PlayerActions, half/team derived after the fact''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_flag_captures' AND COLUMN_NAME='source_action_id'),
       'ADD COLUMN source_action_id INT UNSIGNED DEFAULT NULL COMMENT ''hlstats_Events_PlayerActions.id an inferred row was derived from; NULL on recorded rows''', NULL)
);
SET @ddl := IF(@clauses IS NULL OR @clauses = '', 'DO 0', CONCAT('ALTER TABLE ktp_flag_captures ', @clauses));
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @ddl := IF((SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_flag_captures' AND INDEX_NAME='uk_source_action') > 0,
    'DO 0',
    'ALTER TABLE ktp_flag_captures ADD UNIQUE KEY uk_source_action (source_action_id)');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Verify (read-only):
--
--   SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT
--   FROM information_schema.COLUMNS
--   WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'ktp_flag_captures'
--     AND COLUMN_NAME IN ('provenance', 'source_action_id');
--
--   -- before the backfill: every row recorded, no source pointers
--   SELECT provenance, COUNT(*), SUM(source_action_id IS NOT NULL)
--   FROM ktp_flag_captures GROUP BY provenance;
--
--   -- after the next live capture: the daemon's new rows took the default
--   SELECT provenance, COUNT(*) FROM ktp_flag_captures
--   WHERE created_at >= '<apply time>' GROUP BY provenance;
