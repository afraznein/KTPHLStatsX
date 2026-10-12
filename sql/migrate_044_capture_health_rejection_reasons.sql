-- ENGINE: mysql (hlstatsx on the data server -- NOT the Supabase editor)
-- KTP HLStatsX Migration 044: rejection_reasons on ktp_capture_health.
--
-- STATUS: proposed, not applied.
--
-- Apply once as: sudo mysql hlstatsx < migrate_044_capture_health_rejection_reasons.sql
-- Idempotent: the column is added only when information_schema says it is
-- missing, so a second run is a DO 0.
--
-- DEPLOY ORDER: migration FIRST, then the daemon. The paired hlstats.pl names
--   the column in its ktp_capture_health INSERT, so a daemon swapped ahead of
--   this migration fails every health write. The column is nullable with no
--   default, so the current daemon keeps writing rows unchanged until it is
--   swapped -- an applied migration with the old daemon is a no-op, which is the
--   safe ordering.
--
-- WHY. correlation_failure_count was the only reason this table carried, so a
-- rejection for any other cause arrived with every reason column at zero: the
-- capture-loss alert could page but not diagnose, and most of a lost match-half
-- said nothing at all about why its rows were refused. The reason already
-- existed at every rejection site in the daemon as the dispatch status string
-- and was discarded; it is now tallied per (match, half, stream) and written
-- here.
--
-- FORMAT. `reason=count;reason=count`, most frequent first and name-ordered on
-- a tie, so two identical halves produce identical bytes. The daemon folds
-- anything past 12 distinct reasons per stream into `other=N` and truncates the
-- whole string at the column width rather than overflowing it, so a malformed
-- stream cannot grow this column with the flood it exists to describe.
--
-- IDENTITY. The daemon scrubs a reason before storing it: two status strings
-- interpolate an internal player id and a raw position, and `for player=<id>`,
-- quoted payload literals and SteamID-shaped tokens are all removed. Nothing
-- here is per-player, which is what makes the column safe to read out and quote.

SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_capture_health'
      AND COLUMN_NAME='rejection_reasons');
SET @ddl := IF(@exists, 'DO 0',
    'ALTER TABLE ktp_capture_health ADD COLUMN rejection_reasons VARCHAR(255) DEFAULT NULL COMMENT ''reason=count;reason=count for this stream''''s daemon_rejected, most frequent first; NULL = pre-044 daemon or nothing rejected'' AFTER repaired_count');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Verify, after a match night on the paired daemon. A NULL here means either a
-- pre-044 daemon or a stream that rejected nothing, so read it against
-- daemon_rejected rather than on its own -- a row with daemon_rejected > 0 and
-- rejection_reasons NULL is the defect this migration exists to remove:
--
--   SELECT event_type, SUM(daemon_rejected) AS rejected,
--          SUM(daemon_rejected > 0 AND rejection_reasons IS NULL) AS unexplained,
--          SUBSTRING_INDEX(rejection_reasons, ';', 1) AS leading_reason,
--          COUNT(*) AS rows_with_it
--   FROM ktp_capture_health
--   WHERE event_time > NOW() - INTERVAL 1 DAY AND daemon_rejected > 0
--   GROUP BY event_type, leading_reason
--   ORDER BY event_type, rejected DESC;
