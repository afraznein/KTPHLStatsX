-- KTP HLStatsX Migration 020: separate the frag-context claim guard from the
-- certification of what it claimed
-- Run on data server: mysql -u hlstatsx -p hlstatsx < migrate_020_frag_context_certified.sql
--
-- Migration 020 must run before daemon 0.3.12. Its frag_context UPDATE names
-- this column, and a write to a column that does not exist fails inside MySQL,
-- so code ahead of schema loses every frag correlation silently.
--
-- WHY A SECOND COLUMN RATHER THAN REDEFINING THE FIRST. Migration 012's
-- frag_context_recorded is load-bearing as an exactly-once claim guard: the
-- frag_context UPDATE requires it to be 0 and sets it to 1, which is what stops
-- a second marker rewriting a row a first marker already took. That guard has to
-- be set on every row a marker consumes, including one whose payload arrived
-- incomplete. Certification is the opposite question -- may a reader trust the
-- context columns on this row -- and the two answers differ exactly when a
-- property is absent, empty or malformed. One column cannot carry both without
-- reintroducing the double-claim defect migration 018 fixed on the break side.
--
-- WHAT frag_context_certified = 1 MEANS. Every NOT NULL context property the
-- producer emits unconditionally -- the set enumerated in the daemon's
-- @fc_context_spec, which is the only place it is written down -- was present on
-- the marker and matched the producer's format. Positions are deliberately not
-- part of it: they are nullable, so NULL already reads as unknown.
--
-- WHAT 0 MEANS, AND WHY THAT IS THE WHOLE POINT. Three different things -- no
-- marker was ever emitted for this row (the stock build on most of the fleet),
-- a marker was emitted and lost, or a marker arrived with an unusable property.
-- All three share one consequence: the context columns hold defaults, not
-- measurements, and every one of those defaults is a legal reading. k_prone = 0
-- is "standing", k_clip = -1 is "the read failed", is_last_flag_defense = 0 is
-- "not defending". Nothing in the row's content distinguishes a default from a
-- measurement, which is why this has to be recorded at write time and cannot be
-- recovered by a query afterwards.
--
-- Additive and idempotent: guarded on information_schema, so re-running is a
-- no-op. Existing rows take the default 0 -- see the backfill note at the end.
--
-- ⚠️ hlstats_Events_Frags is MyISAM, so this ADD COLUMN is a full table rebuild
-- under a write lock on the largest table in the schema. Apply in an idle
-- window, and combine it into one ALTER with any other pending change to this
-- table rather than running several in sequence.

-- The database MUST be named on the command line: DATABASE() is NULL otherwise
-- and the guard below reads as 'column absent'.

-- hlstats_Events_Frags.frag_context_certified
SET @col_exists = (SELECT COUNT(*) FROM information_schema.COLUMNS
                   WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_Frags'
                   AND COLUMN_NAME = 'frag_context_certified');
SET @sql = IF(@col_exists > 0, 'DO 0',
    'ALTER TABLE hlstats_Events_Frags ADD COLUMN frag_context_certified TINYINT(1) NOT NULL DEFAULT 0');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Verify the column landed:
--
--   SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT
--   FROM information_schema.COLUMNS
--   WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'hlstats_Events_Frags'
--     AND COLUMN_NAME IN ('frag_context_recorded','frag_context_certified');

-- ---------------------------------------------------------------------------
-- BACKFILL -- deliberately NOT run by this file.
--
-- Certification is a claim the daemon makes from what it read off the wire. No
-- query over rows already written can re-derive it, for the reason given above:
-- a defaulted column and a measured one are byte-identical. Copying
-- frag_context_recorded across would therefore be an operator's judgement about
-- a population, not a derivation, and this file will not make that judgement
-- silently on a table this size.
--
-- It is a defensible judgement when the flagged population is confined to
-- instances known to have been running the complete emitter for the whole span
-- the rows cover, because that emitter writes all ten properties on every kill.
-- Establish that first, with these two, and read them rather than assuming the
-- shape they had last time -- the split moves with every instance that takes the
-- new plugin:
--
--   SELECT serverId, COUNT(*) AS flagged,
--          MIN(eventTime) AS first_seen, MAX(eventTime) AS last_seen
--   FROM hlstats_Events_Frags WHERE frag_context_recorded = 1 GROUP BY serverId;
--
--   -- Any non-zero here is a flagged row whose payload was NOT of the shape the
--   -- complete emitter produces, and the backfill below would certify it falsely.
--   SELECT SUM(headshot NOT IN (0,1) OR k_scope NOT IN (0,1) OR v_scope NOT IN (0,1)
--              OR is_last_flag_defense NOT IN (0,1)
--              OR k_clip < -1 OR k_ammo < -1 OR v_clip < -1 OR v_ammo < -1) AS malformed
--   FROM hlstats_Events_Frags WHERE frag_context_recorded = 1;
--
-- Only with both read, and only for the server ids they justify:
--
--   UPDATE hlstats_Events_Frags
--   SET frag_context_certified = 1
--   WHERE frag_context_recorded = 1 AND serverId IN (/* the ids established above */);
--
-- Leaving the backfill undone is the safe failure: certified queries then
-- under-report history and never over-report it.
