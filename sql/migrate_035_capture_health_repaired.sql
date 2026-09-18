-- KTP HLStatsX Migration 035: repaired_count on ktp_capture_health.
-- Apply after migration 034.
--
-- WHY. The capture transport is one-way UDP over the public internet and
-- loses about 0.1% of markers on the way in (measured 2026-09-18 on the
-- schema-24 fleet: sequence_gap_count == emitted - daemon_received on every
-- stream, no reordering, and this host's socket shows no drops). The daemon
-- now asks the producer to re-log a missing sequence over its existing rcon
-- session (KTPAMXX 1.24.0 keeps a retention ring), and a resent marker that
-- arrives while its gap is still open closes it.
--
-- Accounting contract, unchanged for every existing consumer:
--   sequence_gap_count           = gaps still open at the health row (UNREPAIRED)
--   duplicate_or_reordered_count = markers that were neither new nor a repair
--   repaired_count               = gaps closed by a resend or a late original
-- so emitted - daemon_received + repaired_count is what the transport lost
-- before repair, and sequence_gap_count is what it lost for good.

SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_capture_health' AND COLUMN_NAME='repaired_count');
SET @ddl := IF(@exists, 'DO 0',
    'ALTER TABLE ktp_capture_health ADD COLUMN repaired_count INT UNSIGNED NOT NULL DEFAULT 0 COMMENT ''gaps closed by a resend or a late original; sequence_gap_count is what stayed lost'' AFTER duplicate_or_reordered_count');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Verify, after a day of 1.24.0 producers:
--
--   SELECT event_type, SUM(emitted) AS emitted,
--          SUM(emitted - daemon_received + repaired_count) AS lost_in_transit,
--          SUM(repaired_count) AS repaired, SUM(sequence_gap_count) AS still_lost
--   FROM ktp_capture_health WHERE event_time > NOW() - INTERVAL 1 DAY
--   GROUP BY event_type;
