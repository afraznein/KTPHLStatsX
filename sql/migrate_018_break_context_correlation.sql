-- KTP HLStatsX Migration 018: exactly-once break-context correlation,
-- and an honest "unknown" for is_capout
-- Run BEFORE deploying the paired hlstats.pl:
--   mysql -u hlstatsx -p hlstatsx < migrate_018_break_context_correlation.sql
--
-- Two changes in one file on purpose. The paired hlstats.pl writes
-- break_context_recorded and a NULL is_capout in the SAME UPDATE statement, so
-- applying only one half breaks that statement outright.
--
-- Without the claim column the statement fails with ERROR 1054 (Unknown column
-- 'break_context_recorded'). That is the failure to lead with, because it does
-- not depend on server configuration. The NULL half fails with ERROR 1048 on
-- this server, but only because it runs STRICT_TRANS_TABLES -- on a non-strict
-- install the same write would silently coerce NULL to 0 and restore exactly
-- the ambiguity this migration exists to remove, while looking healthy.
--
-- Either way the whole UPDATE aborts, so contester_count and time_remaining are
-- lost with it, and execNonQuery's zero return fires a misleading
-- KTP_NO_ROW_MATCHED. One file = one precondition to get right.
--
-- ⚠️ hlstats_Events_PlayerActions is MyISAM, so the ALTER below is a full
-- table rebuild under a write lock, and the daemon writes to this table
-- continuously. Apply in an idle window, not mid-match -- the same live-match
-- check a daemon restart calls for. Row count to size the outage:
--   SELECT TABLE_ROWS FROM information_schema.TABLES
--   WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'hlstats_Events_PlayerActions';
--
-- The database MUST be named on the command line -- see ktp_schema.sql's
-- header for why (DATABASE() is NULL otherwise and every guard chooses to
-- apply, so the first ALTER aborts the batch at ERROR 1046).

-- Both changes are applied as ONE ALTER, deliberately. This table is MyISAM, so
-- every ALTER is a full table rebuild under a write lock -- never MySQL 8's
-- instant add -- and running the two as separate statements would rebuild it
-- twice for no benefit. The guards below select which clauses are needed, so a
-- re-run on an already-migrated database emits `DO 0` and rebuilds nothing.
--
-- 1. break_context_recorded
--
-- Direct mirror of migration 012 on the Frags side, for the same failure. A
-- break_context UDP line can arrive even when its cap_break line was lost.
-- Without a claim column the UPDATE's 60-second receipt window still matches
-- SOMETHING -- the player's previous break inside that window -- and writes
-- this break's contester_count/time_remaining/is_capout onto it. The UPDATE
-- reports one row affected, so the existing KTP_NO_ROW_MATCHED diagnostic
-- never fires and the wrong numbers read as good numbers. Marking a row on
-- first successful correlation turns that into a no-op the daemon can log.
--
-- 2. is_capout -> NULLable
--
-- Migration 007 added this column NOT NULL DEFAULT 0 while giving its two
-- siblings (contester_count, time_remaining) a NULL default. That asymmetry
-- makes is_capout the only one of the three that cannot say "unknown": a break
-- whose context marker never arrived is stored identically to a break the
-- plugin measured and found was not a capout.
--
-- That is the same invisible default as k_prone -- a column read as fact for
-- nine seasons while it only ever held its default. Fixing it before Season 10
-- costs one rebuild; leaving it makes the distinction unrecoverable after the
-- fact, because nothing else in the row records whether context ever landed.
-- The paired hlstats.pl writes NULL when the property is absent.

SET @add_claim := (SELECT COUNT(*) = 0 FROM information_schema.COLUMNS
                    WHERE TABLE_SCHEMA = DATABASE()
                      AND TABLE_NAME = 'hlstats_Events_PlayerActions'
                      AND COLUMN_NAME = 'break_context_recorded');

SET @fix_capout := (SELECT COUNT(*) > 0 FROM information_schema.COLUMNS
                     WHERE TABLE_SCHEMA = DATABASE()
                       AND TABLE_NAME = 'hlstats_Events_PlayerActions'
                       AND COLUMN_NAME = 'is_capout'
                       AND IS_NULLABLE = 'NO');

-- CONCAT_WS drops NULL arguments, so an unneeded clause leaves no stray comma.
SET @clauses := CONCAT_WS(', ',
    IF(@add_claim,  'ADD COLUMN break_context_recorded TINYINT(1) NOT NULL DEFAULT 0', NULL),
    IF(@fix_capout, 'MODIFY COLUMN is_capout TINYINT(1) DEFAULT NULL', NULL));

SET @ddl := IF(@clauses IS NULL OR @clauses = '', 'DO 0',
    CONCAT('ALTER TABLE hlstats_Events_PlayerActions ', @clauses));
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- ⚠️ MODIFY changes the column DEFAULT for the whole table, not just for
-- cap_break. hlstats_Events_PlayerActions is written by the generic event-table
-- insert, whose column list does not name is_capout, so every future row of
-- every action type -- kill streaks, captures, everything -- now takes NULL
-- where it previously took 0. That is the intended reading (is_capout is
-- meaningless for a kill streak, and NULL says so where 0 asserted "measured,
-- not a capout"), but it is a table-wide behaviour change, not a cap_break-only
-- one, and the bounding query below deliberately counts only cap_break rows.
--
-- Existing rows are deliberately NOT backfilled to NULL. A stored 0 today is
-- genuinely ambiguous -- it may be a measured non-capout or an absent marker --
-- and nothing in the row distinguishes them, so any backfill would be inventing
-- a fact. Only rows written after this migration carry the honest distinction.
-- How many rows that ambiguity covers, if you need to bound it:
--
--   SELECT COUNT(*) FROM hlstats_Events_PlayerActions pa
--   JOIN hlstats_Actions a ON a.id = pa.actionId
--   WHERE a.code = 'cap_break';

-- Verify: expects break_context_recorded present, and is_capout IS_NULLABLE=YES
-- alongside its two siblings.
--
--   SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT
--   FROM information_schema.COLUMNS
--   WHERE TABLE_SCHEMA = DATABASE()
--     AND TABLE_NAME = 'hlstats_Events_PlayerActions'
--     AND COLUMN_NAME IN ('contester_count','time_remaining','is_capout',
--                         'break_context_recorded');
--
-- Then, after a match containing a cap break on an instance running a
-- stats_logging build that emits break_context:
--
--   SELECT playerId, contester_count, time_remaining, is_capout,
--          break_context_recorded
--   FROM hlstats_Events_PlayerActions pa
--   JOIN hlstats_Actions a ON a.id = pa.actionId
--   WHERE a.code = 'cap_break' ORDER BY pa.id DESC LIMIT 10;
--
-- break_context_recorded = 1 with all three context columns populated is a
-- correlated break. break_context_recorded = 0 with all three NULL is a break
-- whose context never arrived -- expected, and now visible rather than
-- disguised as a non-capout. A row with break_context_recorded = 0 and
-- non-NULL context would mean something wrote context outside this handler.
