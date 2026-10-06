-- ENGINE: mysql (hlstatsx on the data server -- NOT the Supabase editor)
-- KTP HLStatsX Migration 043: (match_id, half, game_time) index on ktp_position_samples.
--
-- STATUS: proposed, not applied.
--
-- Apply once as: sudo mysql hlstatsx < migrate_043_position_samples_time_index.sql
-- Idempotent: the index is added only when information_schema says it is
-- missing, so a second run is a DO 0. An index of this NAME over any other
-- column list stops the run with ERROR_043_index_name_taken_by_other_columns
-- rather than being accepted as done.
--
-- DEPLOY ORDER: none required. No daemon or producer reads or writes anything
--   new. It is independent of 042 (a different table). The consumer that needs
--   it is KTPInfrastructure's sql/analytics/shot_placement_fact.sql, and the
--   join rewrite that lets the optimizer use it must ship AFTER this is applied:
--   without the index that rewrite is slower than today's join, not faster.
--
-- WHY. shot_placement_fact joins every shot to the enemy position samples within
-- +/-1.0 s of it. The only index starting (match_id, half) was
-- idx_position_map_revision, whose third column is the BSP hash, so each shot
-- read every sample of its half, and the cost of a match grew as shots times
-- samples. With game_time as the third column, a per-shot range reads only the
-- two-second window. Measured numbers are in the PR that added this file.
--
-- ONLINE. InnoDB builds a secondary index in place without blocking DML; the
-- daemon keeps inserting position rows throughout. The ALTER still needs a brief
-- exclusive metadata lock at its start and end, and while it WAITS for that lock
-- every new statement on the table queues behind it -- the daemon's INSERTs
-- included. A long report rebuild holds a shared lock for the length of its
-- reads, so apply this when no rebuild is running; lock_wait_timeout below makes
-- an unlucky run fail in 10 s instead of stalling ingestion.

SET SESSION lock_wait_timeout = 10;

SET @cols := (SELECT GROUP_CONCAT(COLUMN_NAME, IF(SUB_PART IS NULL, '', CONCAT('(', SUB_PART, ')'))
                                  ORDER BY SEQ_IN_INDEX)
              FROM information_schema.STATISTICS
              WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_position_samples'
                AND INDEX_NAME='idx_pos_match_half_time');
SET @ddl := CASE
    WHEN @cols IS NULL THEN
        'ALTER TABLE ktp_position_samples ADD INDEX idx_pos_match_half_time (match_id, half, game_time), ALGORITHM=INPLACE, LOCK=NONE'
    WHEN @cols = 'match_id,half,game_time' THEN 'DO 0'
    ELSE 'SELECT * FROM ERROR_043_index_name_taken_by_other_columns'
END;
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Verify the index exists with the right column order:
--
--   SELECT INDEX_NAME, SEQ_IN_INDEX, COLUMN_NAME FROM information_schema.STATISTICS
--   WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_position_samples'
--     AND INDEX_NAME='idx_pos_match_half_time' ORDER BY SEQ_IN_INDEX;
--
-- Expect match_id, half, game_time. Once the shot_placement_fact rewrite is
-- deployed, EXPLAIN of that query shows p as "Range checked for each record"
-- with idx_pos_match_half_time in its index map, rather than a ref on
-- idx_position_map_revision.
