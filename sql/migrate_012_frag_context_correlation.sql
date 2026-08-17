-- KTP HLStatsX Migration 012: exactly-once frag-context correlation
-- Run before deploying the paired hlstats.pl:
--   mysql -u hlstatsx -p hlstatsx < migrate_012_frag_context_correlation.sql
--
-- A frag_context UDP line can arrive even when its stock frag line was lost.
-- Marking rows after the first successful correlation prevents that orphan
-- context from rewriting a previously enriched kill with the same tuple.

SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_Frags'
                   AND COLUMN_NAME = 'frag_context_recorded');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE hlstats_Events_Frags ADD COLUMN frag_context_recorded TINYINT(1) NOT NULL DEFAULT 0');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Verify: expects one row.
--
--   SELECT COLUMN_NAME FROM information_schema.COLUMNS
--   WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'hlstats_Events_Frags'
--     AND COLUMN_NAME = 'frag_context_recorded';
