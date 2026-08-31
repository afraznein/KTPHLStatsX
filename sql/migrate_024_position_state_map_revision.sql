-- KTP HLStatsX Migration 024: explicit position state and captured BSP revision.
-- Apply after migrations 021 (capture manifests), 023 (team membership), and
-- before stats_logging 1.19.0 / daemon 0.3.16 schema-23 capture is enabled.
--
-- All new columns are nullable for legacy compatibility. Schema-23 ingestion
-- nevertheless requires every new position row to carry alive=1, spectator=0,
-- and the exact SHA-256 advertised by its accepted per-half manifest. NULL is
-- therefore an honest legacy/unavailable value, never schema-23 authorization.

SET @clauses := CONCAT_WS(', ',
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_capture_manifests' AND COLUMN_NAME='map_revision_algorithm'), 'ADD COLUMN map_revision_algorithm VARCHAR(16) DEFAULT NULL AFTER life_buffer_entries', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_capture_manifests' AND COLUMN_NAME='map_revision_sha256'), 'ADD COLUMN map_revision_sha256 CHAR(64) CHARACTER SET ascii COLLATE ascii_bin DEFAULT NULL AFTER map_revision_algorithm', NULL));
SET @ddl := IF(@clauses IS NULL OR @clauses='', 'DO 0', CONCAT('ALTER TABLE ktp_capture_manifests ', @clauses));
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @clauses := CONCAT_WS(', ',
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_position_samples' AND COLUMN_NAME='is_alive'), 'ADD COLUMN is_alive TINYINT UNSIGNED DEFAULT NULL AFTER pos_z', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_position_samples' AND COLUMN_NAME='is_spectator'), 'ADD COLUMN is_spectator TINYINT UNSIGNED DEFAULT NULL AFTER is_alive', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_position_samples' AND COLUMN_NAME='map_revision_sha256'), 'ADD COLUMN map_revision_sha256 CHAR(64) CHARACTER SET ascii COLLATE ascii_bin DEFAULT NULL AFTER is_spectator', NULL));
SET @ddl := IF(@clauses IS NULL OR @clauses='', 'DO 0', CONCAT('ALTER TABLE ktp_position_samples ', @clauses));
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @exists := (SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_position_samples' AND INDEX_NAME='idx_position_map_revision');
SET @ddl := IF(@exists, 'DO 0', 'ALTER TABLE ktp_position_samples ADD INDEX idx_position_map_revision (match_id, half, map_revision_sha256)');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Verification after a schema-23 half:
-- SELECT m.match_id, m.half, m.map_name, m.map_revision_algorithm,
--        m.map_revision_sha256, COUNT(p.id) samples,
--        SUM(p.is_alive<>1 OR p.is_spectator<>0) invalid_state,
--        SUM(p.map_revision_sha256<>m.map_revision_sha256) revision_mismatch
-- FROM ktp_capture_manifests m
-- LEFT JOIN ktp_position_samples p
--   ON p.server_id=m.server_id AND p.match_id=m.match_id AND p.half=m.half
-- WHERE m.schema_version=23
-- GROUP BY m.id;
