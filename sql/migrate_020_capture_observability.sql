-- KTP HLStatsX Migration 020: capture manifests, producer sequences and
-- end-of-half health reconciliation.
-- Apply before stats_logging 1.17.0 and the paired hlstats.pl.
--
-- The two MyISAM ALTERs rebuild Frags and PlayerActions. Apply in an idle
-- window after checking their sizes; all other changes are InnoDB metadata or
-- new, initially empty tables.

CREATE TABLE IF NOT EXISTS ktp_capture_manifests (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    server_id INT UNSIGNED NOT NULL,
    match_id VARCHAR(64) NOT NULL,
    half TINYINT UNSIGNED NOT NULL,
    map_name VARCHAR(32) NOT NULL,
    producer VARCHAR(32) NOT NULL,
    producer_version VARCHAR(32) NOT NULL,
    schema_version SMALLINT UNSIGNED NOT NULL,
    capabilities VARCHAR(512) NOT NULL,
    position_interval DECIMAL(6,2) NOT NULL,
    buffer_entries SMALLINT UNSIGNED NOT NULL,
    life_buffer_entries SMALLINT UNSIGNED NOT NULL,
    producer_sequence BIGINT UNSIGNED NOT NULL,
    event_epoch BIGINT UNSIGNED NOT NULL,
    event_time DATETIME NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uk_capture_manifest (server_id, match_id, half, producer),
    KEY idx_manifest_version (producer, producer_version, schema_version),
    KEY idx_manifest_time (event_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Per-half producer version and capture capability manifest';

CREATE TABLE IF NOT EXISTS ktp_capture_health (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    server_id INT UNSIGNED NOT NULL,
    match_id VARCHAR(64) NOT NULL,
    half TINYINT UNSIGNED NOT NULL,
    event_type VARCHAR(32) NOT NULL,
    attempted INT UNSIGNED NOT NULL,
    enqueued INT UNSIGNED NOT NULL,
    dropped INT UNSIGNED NOT NULL,
    emitted INT UNSIGNED NOT NULL,
    daemon_received INT UNSIGNED NOT NULL,
    daemon_accepted INT UNSIGNED NOT NULL,
    daemon_rejected INT UNSIGNED NOT NULL,
    correlation_failure_count INT UNSIGNED NOT NULL DEFAULT 0,
    sequence_first BIGINT UNSIGNED NOT NULL,
    sequence_last BIGINT UNSIGNED NOT NULL,
    daemon_sequence_first BIGINT UNSIGNED DEFAULT NULL,
    daemon_sequence_last BIGINT UNSIGNED DEFAULT NULL,
    sequence_gap_count INT UNSIGNED NOT NULL DEFAULT 0,
    duplicate_or_reordered_count INT UNSIGNED NOT NULL DEFAULT 0,
    producer_sequence BIGINT UNSIGNED NOT NULL,
    event_epoch BIGINT UNSIGNED NOT NULL,
    event_time DATETIME NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uk_capture_health (server_id, match_id, half, event_type),
    KEY idx_health_match (match_id, half),
    KEY idx_health_quality (dropped, sequence_gap_count),
    KEY idx_health_time (event_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Producer-vs-daemon end-of-half capture reconciliation by event type';

-- Idempotent column additions. A producer sequence is NULL for legacy rows.
SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='hlstats_Events_Frags' AND COLUMN_NAME='producer_sequence');
SET @ddl := IF(@exists, 'DO 0', 'ALTER TABLE hlstats_Events_Frags ADD COLUMN producer_sequence BIGINT UNSIGNED DEFAULT NULL AFTER producer_half');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Guard every sibling independently. CONCAT_WS keeps this to one MyISAM
-- rebuild while making a rerun repair any partially applied/manual state.
SET @clauses := CONCAT_WS(', ',
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='hlstats_Events_PlayerActions' AND COLUMN_NAME='producer_match_id'), 'ADD COLUMN producer_match_id VARCHAR(64) DEFAULT NULL', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='hlstats_Events_PlayerActions' AND COLUMN_NAME='producer_half'), 'ADD COLUMN producer_half TINYINT UNSIGNED DEFAULT NULL', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='hlstats_Events_PlayerActions' AND COLUMN_NAME='producer_sequence'), 'ADD COLUMN producer_sequence BIGINT UNSIGNED DEFAULT NULL', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='hlstats_Events_PlayerActions' AND COLUMN_NAME='producer_event_epoch'), 'ADD COLUMN producer_event_epoch BIGINT UNSIGNED DEFAULT NULL', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='hlstats_Events_PlayerActions' AND COLUMN_NAME='producer_game_time'), 'ADD COLUMN producer_game_time DECIMAL(10,2) DEFAULT NULL', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='hlstats_Events_PlayerActions' AND COLUMN_NAME='flag_index'), 'ADD COLUMN flag_index TINYINT UNSIGNED DEFAULT NULL', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='hlstats_Events_PlayerActions' AND COLUMN_NAME='flag_name'), 'ADD COLUMN flag_name VARCHAR(64) DEFAULT NULL', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='hlstats_Events_PlayerActions' AND COLUMN_NAME='break_victim_id'), 'ADD COLUMN break_victim_id INT DEFAULT NULL', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='hlstats_Events_PlayerActions' AND COLUMN_NAME='break_incident_id'), 'ADD COLUMN break_incident_id BIGINT UNSIGNED DEFAULT NULL', NULL));
SET @ddl := IF(@clauses IS NULL OR @clauses='', 'DO 0', CONCAT('ALTER TABLE hlstats_Events_PlayerActions ', @clauses));
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_damage_events' AND COLUMN_NAME='producer_sequence');
SET @ddl := IF(@exists, 'DO 0', 'ALTER TABLE ktp_damage_events ADD COLUMN producer_sequence BIGINT UNSIGNED DEFAULT NULL AFTER producer_half');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @clauses := CONCAT_WS(', ',
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_position_samples' AND COLUMN_NAME='producer_sequence'), 'ADD COLUMN producer_sequence BIGINT UNSIGNED DEFAULT NULL AFTER game_time', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_position_samples' AND COLUMN_NAME='event_epoch'), 'ADD COLUMN event_epoch BIGINT UNSIGNED DEFAULT NULL AFTER producer_sequence', NULL));
SET @ddl := IF(@clauses IS NULL OR @clauses='', 'DO 0', CONCAT('ALTER TABLE ktp_position_samples ', @clauses));
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_assist_events' AND COLUMN_NAME='producer_sequence');
SET @ddl := IF(@exists, 'DO 0', 'ALTER TABLE ktp_assist_events ADD COLUMN producer_sequence BIGINT UNSIGNED DEFAULT NULL AFTER event_epoch');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_life_events' AND COLUMN_NAME='producer_sequence');
SET @ddl := IF(@exists, 'DO 0', 'ALTER TABLE ktp_life_events ADD COLUMN producer_sequence BIGINT UNSIGNED DEFAULT NULL AFTER event_epoch');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @clauses := CONCAT_WS(', ',
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_flag_state_events' AND COLUMN_NAME='producer_sequence'), 'ADD COLUMN producer_sequence BIGINT UNSIGNED DEFAULT NULL AFTER game_time', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_flag_state_events' AND COLUMN_NAME='event_epoch'), 'ADD COLUMN event_epoch BIGINT UNSIGNED DEFAULT NULL AFTER producer_sequence', NULL));
SET @ddl := IF(@clauses IS NULL OR @clauses='', 'DO 0', CONCAT('ALTER TABLE ktp_flag_state_events ', @clauses));
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @clauses := CONCAT_WS(', ',
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_flag_positions' AND COLUMN_NAME='last_match_id'), 'ADD COLUMN last_match_id VARCHAR(64) DEFAULT NULL', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_flag_positions' AND COLUMN_NAME='last_half'), 'ADD COLUMN last_half TINYINT UNSIGNED DEFAULT NULL', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_flag_positions' AND COLUMN_NAME='last_producer_sequence'), 'ADD COLUMN last_producer_sequence BIGINT UNSIGNED DEFAULT NULL', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_flag_positions' AND COLUMN_NAME='last_event_epoch'), 'ADD COLUMN last_event_epoch BIGINT UNSIGNED DEFAULT NULL', NULL));
SET @ddl := IF(@clauses IS NULL OR @clauses='', 'DO 0', CONCAT('ALTER TABLE ktp_flag_positions ', @clauses));
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- A healthy completed half has eight rows, no producer drops, no daemon gaps,
-- and daemon_received = emitted for each event type.
-- SELECT match_id, half, COUNT(*) types,
--        SUM(dropped) dropped, SUM(sequence_gap_count) gaps,
--        SUM(daemon_received <> emitted) count_mismatches
-- FROM ktp_capture_health GROUP BY match_id, half;
