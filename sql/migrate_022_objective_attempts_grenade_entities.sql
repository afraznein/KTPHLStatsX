-- KTP HLStatsX Migration 022: objective-attempt and grenade-entity ledgers.
-- Apply before daemon 0.3.15 and stats_logging 1.18.0 (schema contract 22).
--
-- Both ledgers contain factual producer events only. Objective outcomes are
-- derived from start plus terminal rows; no synthetic start is invented when
-- a terminal is left-censored. A grenade "removed" row is only an entity
-- lifecycle observation. It is not proof of detonation or explosion and has
-- no damage-correlation claim.
--
-- The position columns in ktp_grenade_entity_events are private analytics
-- data. Public report exporters must not copy them.

CREATE TABLE IF NOT EXISTS ktp_objective_attempt_events (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    server_id INT UNSIGNED NOT NULL,
    match_id VARCHAR(64) NOT NULL,
    half TINYINT UNSIGNED NOT NULL,
    map_name VARCHAR(32) NOT NULL,
    attempt_id BIGINT UNSIGNED NOT NULL
        COMMENT 'Producer sequence allocated by the start event',
    event_kind VARCHAR(8) NOT NULL
        COMMENT 'Validated by daemon: start, complete, or stop',
    lifecycle_slot TINYINT UNSIGNED NOT NULL
        COMMENT '0=start, 1=terminal; unique key enforces one of each',
    flag_index TINYINT UNSIGNED NOT NULL,
    flag_name VARCHAR(64) NOT NULL,
    capturing_team TINYINT UNSIGNED NOT NULL
        COMMENT '1=Allies, 2=Axis',
    owner_before TINYINT UNSIGNED NOT NULL
        COMMENT '0=neutral, 1=Allies, 2=Axis',
    allies_in_zone SMALLINT UNSIGNED NOT NULL,
    axis_in_zone SMALLINT UNSIGNED NOT NULL,
    stop_reason VARCHAR(32) DEFAULT NULL
        COMMENT 'Only capture_stopped or context_reset on stop rows',
    game_time DECIMAL(10,2) NOT NULL,
    event_epoch BIGINT UNSIGNED NOT NULL,
    producer_sequence BIGINT UNSIGNED NOT NULL,
    event_time DATETIME NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (id),
    UNIQUE KEY uk_objective_producer_sequence
        (server_id, match_id, half, producer_sequence),
    UNIQUE KEY uk_objective_attempt_slot
        (server_id, match_id, half, attempt_id, lifecycle_slot),
    KEY idx_objective_match_timeline
        (match_id, half, event_epoch, producer_sequence),
    KEY idx_objective_attempt
        (server_id, match_id, half, attempt_id),
    KEY idx_objective_flag_team
        (match_id, half, flag_index, capturing_team, event_epoch)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Append-only factual objective-attempt lifecycle events';

CREATE TABLE IF NOT EXISTS ktp_grenade_entity_events (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    server_id INT UNSIGNED NOT NULL,
    match_id VARCHAR(64) NOT NULL,
    half TINYINT UNSIGNED NOT NULL,
    map_name VARCHAR(32) NOT NULL,
    entity_kind VARCHAR(8) NOT NULL
        COMMENT 'Validated by daemon: tracked or removed',
    lifecycle_slot TINYINT UNSIGNED NOT NULL
        COMMENT '0=tracked, 1=removed',
    entindex INT UNSIGNED NOT NULL,
    serial INT UNSIGNED NOT NULL,
    weapon_id TINYINT UNSIGNED NOT NULL
        COMMENT 'Only 13, 14, or 36',
    weapon_type VARCHAR(16) NOT NULL
        COMMENT 'handgrenade, stickgrenade, or mills_bomb',
    owner_player_id INT NOT NULL,
    owner_engine_userid INT UNSIGNED NOT NULL,
    pos_x MEDIUMINT NOT NULL COMMENT 'Private: never publish',
    pos_y MEDIUMINT NOT NULL COMMENT 'Private: never publish',
    pos_z MEDIUMINT NOT NULL COMMENT 'Private: never publish',
    game_time DECIMAL(10,2) NOT NULL,
    event_epoch BIGINT UNSIGNED NOT NULL,
    producer_sequence BIGINT UNSIGNED NOT NULL,
    event_time DATETIME NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (id),
    UNIQUE KEY uk_grenade_producer_sequence
        (server_id, match_id, half, producer_sequence),
    UNIQUE KEY uk_grenade_entity_kind
        (server_id, match_id, half, entindex, serial, entity_kind),
    KEY idx_grenade_match_timeline
        (match_id, half, event_epoch, producer_sequence),
    KEY idx_grenade_entity
        (server_id, match_id, half, entindex, serial),
    KEY idx_grenade_owner
        (match_id, half, owner_player_id, event_epoch)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Tracked/removed grenade entity facts; removed does not mean detonated';

-- CREATE TABLE is atomic on supported MySQL/MariaDB versions, so an interrupted
-- clean apply is repaired by rerunning the missing CREATE. CREATE TABLE IF NOT
-- EXISTS does *not* repair a pre-existing partial or incompatible table. Fail
-- before any index ALTER in that case: the deliberately named missing table in
-- the error tells the operator which ledger must be restored, or dropped only
-- if confirmed empty, before rerunning 022. A compatible table with missing
-- named secondary/unique indexes is repaired by the guarded ALTERs below. A
-- same-name index with different uniqueness, a prefix/extra/reordered column,
-- or an extra required/no-default column fails preflight rather than claiming
-- a safe repair that could weaken lifecycle constraints or break daemon inserts.

SET @objective_column_count := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_objective_attempt_events'
      AND COLUMN_NAME IN ('id','server_id','match_id','half','map_name','attempt_id',
          'event_kind','lifecycle_slot','flag_index','flag_name','capturing_team',
          'owner_before','allies_in_zone','axis_in_zone','stop_reason','game_time',
          'event_epoch','producer_sequence','event_time','created_at')
);
SET @objective_bad_columns := (
    SELECT COALESCE(SUM(CASE COLUMN_NAME
        WHEN 'id' THEN NOT(DATA_TYPE='bigint' AND LOCATE('unsigned',COLUMN_TYPE)>0 AND IS_NULLABLE='NO' AND LOCATE('auto_increment',EXTRA)>0)
        WHEN 'server_id' THEN NOT(DATA_TYPE='int' AND LOCATE('unsigned',COLUMN_TYPE)>0 AND IS_NULLABLE='NO')
        WHEN 'match_id' THEN NOT(DATA_TYPE='varchar' AND CHARACTER_MAXIMUM_LENGTH=64 AND IS_NULLABLE='NO')
        WHEN 'half' THEN NOT(DATA_TYPE='tinyint' AND LOCATE('unsigned',COLUMN_TYPE)>0 AND IS_NULLABLE='NO')
        WHEN 'map_name' THEN NOT(DATA_TYPE='varchar' AND CHARACTER_MAXIMUM_LENGTH=32 AND IS_NULLABLE='NO')
        WHEN 'attempt_id' THEN NOT(DATA_TYPE='bigint' AND LOCATE('unsigned',COLUMN_TYPE)>0 AND IS_NULLABLE='NO')
        WHEN 'event_kind' THEN NOT(DATA_TYPE='varchar' AND CHARACTER_MAXIMUM_LENGTH=8 AND IS_NULLABLE='NO')
        WHEN 'lifecycle_slot' THEN NOT(DATA_TYPE='tinyint' AND LOCATE('unsigned',COLUMN_TYPE)>0 AND IS_NULLABLE='NO')
        WHEN 'flag_index' THEN NOT(DATA_TYPE='tinyint' AND LOCATE('unsigned',COLUMN_TYPE)>0 AND IS_NULLABLE='NO')
        WHEN 'flag_name' THEN NOT(DATA_TYPE='varchar' AND CHARACTER_MAXIMUM_LENGTH=64 AND IS_NULLABLE='NO')
        WHEN 'capturing_team' THEN NOT(DATA_TYPE='tinyint' AND LOCATE('unsigned',COLUMN_TYPE)>0 AND IS_NULLABLE='NO')
        WHEN 'owner_before' THEN NOT(DATA_TYPE='tinyint' AND LOCATE('unsigned',COLUMN_TYPE)>0 AND IS_NULLABLE='NO')
        WHEN 'allies_in_zone' THEN NOT(DATA_TYPE='smallint' AND LOCATE('unsigned',COLUMN_TYPE)>0 AND IS_NULLABLE='NO')
        WHEN 'axis_in_zone' THEN NOT(DATA_TYPE='smallint' AND LOCATE('unsigned',COLUMN_TYPE)>0 AND IS_NULLABLE='NO')
        WHEN 'stop_reason' THEN NOT(DATA_TYPE='varchar' AND CHARACTER_MAXIMUM_LENGTH=32 AND IS_NULLABLE='YES')
        WHEN 'game_time' THEN NOT(DATA_TYPE='decimal' AND NUMERIC_PRECISION=10 AND NUMERIC_SCALE=2 AND IS_NULLABLE='NO')
        WHEN 'event_epoch' THEN NOT(DATA_TYPE='bigint' AND LOCATE('unsigned',COLUMN_TYPE)>0 AND IS_NULLABLE='NO')
        WHEN 'producer_sequence' THEN NOT(DATA_TYPE='bigint' AND LOCATE('unsigned',COLUMN_TYPE)>0 AND IS_NULLABLE='NO')
        WHEN 'event_time' THEN NOT(DATA_TYPE='datetime' AND IS_NULLABLE='NO')
        WHEN 'created_at' THEN NOT(DATA_TYPE='timestamp' AND IS_NULLABLE='NO')
        ELSE 0 END), 0)
    FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_objective_attempt_events'
);
SET @objective_extra_required_columns := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_objective_attempt_events'
      AND COLUMN_NAME NOT IN ('id','server_id','match_id','half','map_name','attempt_id',
          'event_kind','lifecycle_slot','flag_index','flag_name','capturing_team',
          'owner_before','allies_in_zone','axis_in_zone','stop_reason','game_time',
          'event_epoch','producer_sequence','event_time','created_at')
      AND IS_NULLABLE='NO' AND COLUMN_DEFAULT IS NULL
      AND LOCATE('auto_increment',EXTRA)=0
      AND LOCATE('GENERATED',UPPER(EXTRA))=0
);
SET @objective_table_ok := (
    SELECT COUNT(*)=1 FROM information_schema.TABLES
    WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_objective_attempt_events'
      AND ENGINE='InnoDB' AND TABLE_COLLATION='utf8mb4_unicode_ci'
);
SET @objective_primary_ok := (
    SELECT COUNT(*)=1 AND MIN(NON_UNIQUE)=0 AND
        GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ',')='id' AND
        SUM(SUB_PART IS NOT NULL)=0
    FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_objective_attempt_events'
      AND INDEX_NAME='PRIMARY'
);
SET @objective_bad_named_indexes := (
    SELECT COUNT(*) FROM (
        SELECT INDEX_NAME
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA=DATABASE()
          AND TABLE_NAME='ktp_objective_attempt_events'
          AND INDEX_NAME IN ('uk_objective_producer_sequence',
              'uk_objective_attempt_slot','idx_objective_match_timeline',
              'idx_objective_attempt','idx_objective_flag_team')
        GROUP BY INDEX_NAME
        HAVING NOT (
            (INDEX_NAME='uk_objective_producer_sequence' AND COUNT(*)=4 AND
             MIN(NON_UNIQUE)=0 AND SUM(SUB_PART IS NOT NULL)=0 AND
             GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ',')=
                 'server_id,match_id,half,producer_sequence') OR
            (INDEX_NAME='uk_objective_attempt_slot' AND COUNT(*)=5 AND
             MIN(NON_UNIQUE)=0 AND SUM(SUB_PART IS NOT NULL)=0 AND
             GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ',')=
                 'server_id,match_id,half,attempt_id,lifecycle_slot') OR
            (INDEX_NAME='idx_objective_match_timeline' AND COUNT(*)=4 AND
             MIN(NON_UNIQUE)=1 AND SUM(SUB_PART IS NOT NULL)=0 AND
             GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ',')=
                 'match_id,half,event_epoch,producer_sequence') OR
            (INDEX_NAME='idx_objective_attempt' AND COUNT(*)=4 AND
             MIN(NON_UNIQUE)=1 AND SUM(SUB_PART IS NOT NULL)=0 AND
             GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ',')=
                 'server_id,match_id,half,attempt_id') OR
            (INDEX_NAME='idx_objective_flag_team' AND COUNT(*)=5 AND
             MIN(NON_UNIQUE)=1 AND SUM(SUB_PART IS NOT NULL)=0 AND
             GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ',')=
                 'match_id,half,flag_index,capturing_team,event_epoch')
        )
    ) AS incompatible_objective_indexes
);
SET @objective_schema_ok := (@objective_column_count=20 AND
    @objective_bad_columns=0 AND @objective_extra_required_columns=0 AND
    @objective_table_ok=1 AND @objective_primary_ok=1 AND
    @objective_bad_named_indexes=0);
SET @ddl := IF(@objective_schema_ok, 'DO 0',
    'SELECT * FROM ERROR_022_objective_table_partial_or_incompatible');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @grenade_column_count := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_grenade_entity_events'
      AND COLUMN_NAME IN ('id','server_id','match_id','half','map_name','entity_kind',
          'lifecycle_slot','entindex','serial','weapon_id','weapon_type',
          'owner_player_id','owner_engine_userid','pos_x','pos_y','pos_z','game_time',
          'event_epoch','producer_sequence','event_time','created_at')
);
SET @grenade_bad_columns := (
    SELECT COALESCE(SUM(CASE COLUMN_NAME
        WHEN 'id' THEN NOT(DATA_TYPE='bigint' AND LOCATE('unsigned',COLUMN_TYPE)>0 AND IS_NULLABLE='NO' AND LOCATE('auto_increment',EXTRA)>0)
        WHEN 'server_id' THEN NOT(DATA_TYPE='int' AND LOCATE('unsigned',COLUMN_TYPE)>0 AND IS_NULLABLE='NO')
        WHEN 'match_id' THEN NOT(DATA_TYPE='varchar' AND CHARACTER_MAXIMUM_LENGTH=64 AND IS_NULLABLE='NO')
        WHEN 'half' THEN NOT(DATA_TYPE='tinyint' AND LOCATE('unsigned',COLUMN_TYPE)>0 AND IS_NULLABLE='NO')
        WHEN 'map_name' THEN NOT(DATA_TYPE='varchar' AND CHARACTER_MAXIMUM_LENGTH=32 AND IS_NULLABLE='NO')
        WHEN 'entity_kind' THEN NOT(DATA_TYPE='varchar' AND CHARACTER_MAXIMUM_LENGTH=8 AND IS_NULLABLE='NO')
        WHEN 'lifecycle_slot' THEN NOT(DATA_TYPE='tinyint' AND LOCATE('unsigned',COLUMN_TYPE)>0 AND IS_NULLABLE='NO')
        WHEN 'entindex' THEN NOT(DATA_TYPE='int' AND LOCATE('unsigned',COLUMN_TYPE)>0 AND IS_NULLABLE='NO')
        WHEN 'serial' THEN NOT(DATA_TYPE='int' AND LOCATE('unsigned',COLUMN_TYPE)>0 AND IS_NULLABLE='NO')
        WHEN 'weapon_id' THEN NOT(DATA_TYPE='tinyint' AND LOCATE('unsigned',COLUMN_TYPE)>0 AND IS_NULLABLE='NO')
        WHEN 'weapon_type' THEN NOT(DATA_TYPE='varchar' AND CHARACTER_MAXIMUM_LENGTH=16 AND IS_NULLABLE='NO')
        WHEN 'owner_player_id' THEN NOT(DATA_TYPE='int' AND LOCATE('unsigned',COLUMN_TYPE)=0 AND IS_NULLABLE='NO')
        WHEN 'owner_engine_userid' THEN NOT(DATA_TYPE='int' AND LOCATE('unsigned',COLUMN_TYPE)>0 AND IS_NULLABLE='NO')
        WHEN 'pos_x' THEN NOT(DATA_TYPE='mediumint' AND IS_NULLABLE='NO')
        WHEN 'pos_y' THEN NOT(DATA_TYPE='mediumint' AND IS_NULLABLE='NO')
        WHEN 'pos_z' THEN NOT(DATA_TYPE='mediumint' AND IS_NULLABLE='NO')
        WHEN 'game_time' THEN NOT(DATA_TYPE='decimal' AND NUMERIC_PRECISION=10 AND NUMERIC_SCALE=2 AND IS_NULLABLE='NO')
        WHEN 'event_epoch' THEN NOT(DATA_TYPE='bigint' AND LOCATE('unsigned',COLUMN_TYPE)>0 AND IS_NULLABLE='NO')
        WHEN 'producer_sequence' THEN NOT(DATA_TYPE='bigint' AND LOCATE('unsigned',COLUMN_TYPE)>0 AND IS_NULLABLE='NO')
        WHEN 'event_time' THEN NOT(DATA_TYPE='datetime' AND IS_NULLABLE='NO')
        WHEN 'created_at' THEN NOT(DATA_TYPE='timestamp' AND IS_NULLABLE='NO')
        ELSE 0 END), 0)
    FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_grenade_entity_events'
);
SET @grenade_extra_required_columns := (
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_grenade_entity_events'
      AND COLUMN_NAME NOT IN ('id','server_id','match_id','half','map_name','entity_kind',
          'lifecycle_slot','entindex','serial','weapon_id','weapon_type',
          'owner_player_id','owner_engine_userid','pos_x','pos_y','pos_z','game_time',
          'event_epoch','producer_sequence','event_time','created_at')
      AND IS_NULLABLE='NO' AND COLUMN_DEFAULT IS NULL
      AND LOCATE('auto_increment',EXTRA)=0
      AND LOCATE('GENERATED',UPPER(EXTRA))=0
);
SET @grenade_table_ok := (
    SELECT COUNT(*)=1 FROM information_schema.TABLES
    WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_grenade_entity_events'
      AND ENGINE='InnoDB' AND TABLE_COLLATION='utf8mb4_unicode_ci'
);
SET @grenade_primary_ok := (
    SELECT COUNT(*)=1 AND MIN(NON_UNIQUE)=0 AND
        GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ',')='id' AND
        SUM(SUB_PART IS NOT NULL)=0
    FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_grenade_entity_events'
      AND INDEX_NAME='PRIMARY'
);
SET @grenade_bad_named_indexes := (
    SELECT COUNT(*) FROM (
        SELECT INDEX_NAME
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA=DATABASE()
          AND TABLE_NAME='ktp_grenade_entity_events'
          AND INDEX_NAME IN ('uk_grenade_producer_sequence',
              'uk_grenade_entity_kind','idx_grenade_match_timeline',
              'idx_grenade_entity','idx_grenade_owner')
        GROUP BY INDEX_NAME
        HAVING NOT (
            (INDEX_NAME='uk_grenade_producer_sequence' AND COUNT(*)=4 AND
             MIN(NON_UNIQUE)=0 AND SUM(SUB_PART IS NOT NULL)=0 AND
             GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ',')=
                 'server_id,match_id,half,producer_sequence') OR
            (INDEX_NAME='uk_grenade_entity_kind' AND COUNT(*)=6 AND
             MIN(NON_UNIQUE)=0 AND SUM(SUB_PART IS NOT NULL)=0 AND
             GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ',')=
                 'server_id,match_id,half,entindex,serial,entity_kind') OR
            (INDEX_NAME='idx_grenade_match_timeline' AND COUNT(*)=4 AND
             MIN(NON_UNIQUE)=1 AND SUM(SUB_PART IS NOT NULL)=0 AND
             GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ',')=
                 'match_id,half,event_epoch,producer_sequence') OR
            (INDEX_NAME='idx_grenade_entity' AND COUNT(*)=5 AND
             MIN(NON_UNIQUE)=1 AND SUM(SUB_PART IS NOT NULL)=0 AND
             GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ',')=
                 'server_id,match_id,half,entindex,serial') OR
            (INDEX_NAME='idx_grenade_owner' AND COUNT(*)=4 AND
             MIN(NON_UNIQUE)=1 AND SUM(SUB_PART IS NOT NULL)=0 AND
             GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ',')=
                 'match_id,half,owner_player_id,event_epoch')
        )
    ) AS incompatible_grenade_indexes
);
SET @grenade_schema_ok := (@grenade_column_count=21 AND
    @grenade_bad_columns=0 AND @grenade_extra_required_columns=0 AND
    @grenade_table_ok=1 AND @grenade_primary_ok=1 AND
    @grenade_bad_named_indexes=0);
SET @ddl := IF(@grenade_schema_ok, 'DO 0',
    'SELECT * FROM ERROR_022_grenade_table_partial_or_incompatible');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @exists := (SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_objective_attempt_events' AND INDEX_NAME='uk_objective_producer_sequence');
SET @ddl := IF(@exists, 'DO 0', 'ALTER TABLE ktp_objective_attempt_events ADD UNIQUE KEY uk_objective_producer_sequence (server_id, match_id, half, producer_sequence)');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @exists := (SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_objective_attempt_events' AND INDEX_NAME='uk_objective_attempt_slot');
SET @ddl := IF(@exists, 'DO 0', 'ALTER TABLE ktp_objective_attempt_events ADD UNIQUE KEY uk_objective_attempt_slot (server_id, match_id, half, attempt_id, lifecycle_slot)');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @exists := (SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_objective_attempt_events' AND INDEX_NAME='idx_objective_match_timeline');
SET @ddl := IF(@exists, 'DO 0', 'ALTER TABLE ktp_objective_attempt_events ADD KEY idx_objective_match_timeline (match_id, half, event_epoch, producer_sequence)');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @exists := (SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_objective_attempt_events' AND INDEX_NAME='idx_objective_attempt');
SET @ddl := IF(@exists, 'DO 0', 'ALTER TABLE ktp_objective_attempt_events ADD KEY idx_objective_attempt (server_id, match_id, half, attempt_id)');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @exists := (SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_objective_attempt_events' AND INDEX_NAME='idx_objective_flag_team');
SET @ddl := IF(@exists, 'DO 0', 'ALTER TABLE ktp_objective_attempt_events ADD KEY idx_objective_flag_team (match_id, half, flag_index, capturing_team, event_epoch)');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @exists := (SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_grenade_entity_events' AND INDEX_NAME='uk_grenade_producer_sequence');
SET @ddl := IF(@exists, 'DO 0', 'ALTER TABLE ktp_grenade_entity_events ADD UNIQUE KEY uk_grenade_producer_sequence (server_id, match_id, half, producer_sequence)');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @exists := (SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_grenade_entity_events' AND INDEX_NAME='uk_grenade_entity_kind');
SET @ddl := IF(@exists, 'DO 0', 'ALTER TABLE ktp_grenade_entity_events ADD UNIQUE KEY uk_grenade_entity_kind (server_id, match_id, half, entindex, serial, entity_kind)');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @exists := (SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_grenade_entity_events' AND INDEX_NAME='idx_grenade_match_timeline');
SET @ddl := IF(@exists, 'DO 0', 'ALTER TABLE ktp_grenade_entity_events ADD KEY idx_grenade_match_timeline (match_id, half, event_epoch, producer_sequence)');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @exists := (SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_grenade_entity_events' AND INDEX_NAME='idx_grenade_entity');
SET @ddl := IF(@exists, 'DO 0', 'ALTER TABLE ktp_grenade_entity_events ADD KEY idx_grenade_entity (server_id, match_id, half, entindex, serial)');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @exists := (SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_grenade_entity_events' AND INDEX_NAME='idx_grenade_owner');
SET @ddl := IF(@exists, 'DO 0', 'ALTER TABLE ktp_grenade_entity_events ADD KEY idx_grenade_owner (match_id, half, owner_player_id, event_epoch)');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Query examples (classification remains in analytics, not storage):
-- SELECT attempt_id,
--        MAX(event_kind='start') AS has_start,
--        MAX(event_kind='complete') AS completed,
--        MAX(event_kind='stop') AS aborted
-- FROM ktp_objective_attempt_events
-- WHERE match_id=? AND half=? GROUP BY attempt_id;
-- A terminal with has_start=0 is a left-censored/orphan attempt, not corrupt.
