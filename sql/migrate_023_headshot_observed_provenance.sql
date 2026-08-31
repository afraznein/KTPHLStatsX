-- KTP HLStatsX Migration 023: headshot_observed provenance on the frag stream
-- Run on data server: mysql -u hlstatsx -p hlstatsx < migrate_023_headshot_observed_provenance.sql
--
-- `hlstats_Events_Frags.headshot` is tinyint(1) NOT NULL DEFAULT 0, and 0 does
-- two jobs: "observed, not a headshot" and "never observed at all". Nothing on
-- the row distinguishes them, so a headshot rate computed over the table mixes
-- a measurement with an absence.
--
-- This is not hypothetical. Measured on the fleet 2026-08-30: 730,645 of
-- 1,426,309 rows predate a sound headshot-observation regime, and a rate taken
-- over everything reads 8.25% against 14.90% over the observed population.
--
--     1 = the observation regime was sound for this row's source. Both
--         headshot=0 and headshot=1 are real observations.
--     0 = the regime was absent or broken. `headshot` keeps whatever was
--         written, but NO headshot statistic may be computed over these rows.
--
-- An honest rate is  SUM(headshot=1) / COUNT(*)  WHERE headshot_observed = 1.
--
-- DEFAULT 1 is what lets the daemon stay untouched: hlstats.pl names its
-- columns on every INSERT into this table, so new rows inherit the default and
-- no daemon change or restart is required.
--
-- ⛔ SCHEMA ONLY, DELIBERATELY. The production backfill that set 730,645 rows
-- to 0 keys on real calendar boundaries (the regime change, and one dated
-- outage). It ran once, on the fleet, and is recorded in the operator queue.
-- It must NOT run here: this file also builds the tier-2 harness database from
-- scratch, whose fixtures are synthetic, and any fixture row dated before those
-- boundaries would be marked unobserved — silently changing what a headshot
-- assertion means in a test. A fresh database has no unobserved history.
--
-- Idempotent: re-running is a no-op once the column exists.

SET @add := (
  SELECT IF(
    COUNT(*) = 0,
    'ALTER TABLE hlstats_Events_Frags
       ADD COLUMN headshot_observed TINYINT(1) NOT NULL DEFAULT 1
       COMMENT ''0 = headshot was never observed for this row; exclude from headshot rates''',
    'SELECT ''migrate_023: headshot_observed already present, nothing to do'' AS note'
  )
  FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = DATABASE()
    AND TABLE_NAME   = 'hlstats_Events_Frags'
    AND COLUMN_NAME  = 'headshot_observed'
);
PREPARE stmt FROM @add;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- Verify: the column exists and defaults to observed.
SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT
  FROM information_schema.COLUMNS
 WHERE TABLE_SCHEMA = DATABASE()
   AND TABLE_NAME   = 'hlstats_Events_Frags'
   AND COLUMN_NAME  = 'headshot_observed';
