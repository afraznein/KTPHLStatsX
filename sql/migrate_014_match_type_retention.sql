-- Migration 014: persist KTPMatchHandler match type for retention policy.
--
-- NULL is deliberate for legacy/unclassified rows. Retention must fail closed:
-- only explicit scrim (1), 12man (2), or *-TEST IDs may be purged. Draft (3/5)
-- and official/KTP OT (0/4) are retained permanently.

SET @has_match_type := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'ktp_matches'
      AND COLUMN_NAME = 'match_type'
);
SET @sql := IF(
    @has_match_type = 0,
    'ALTER TABLE ktp_matches ADD COLUMN match_type TINYINT UNSIGNED DEFAULT NULL COMMENT ''KTPMatchHandler enum: 0=official, 1=scrim, 2=12man, 3=draft, 4=KTP OT, 5=draft OT'' AFTER half',
    'SELECT 1'
);
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

SET @has_retention_index := (
    SELECT COUNT(*) FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'ktp_matches'
      AND INDEX_NAME = 'idx_retention'
);
SET @sql := IF(
    @has_retention_index = 0,
    'CREATE INDEX idx_retention ON ktp_matches (match_type, start_time)',
    'SELECT 1'
);
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;
