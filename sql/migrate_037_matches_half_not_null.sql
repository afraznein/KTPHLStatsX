-- ENGINE: mysql (hlstatsx on the data server -- NOT the Supabase editor)
-- KTP HLStatsX Migration 037: ktp_matches.half NOT NULL.
--
-- uk_match_id_half is UNIQUE (match_id, half) and half is NULLABLE, so the key
-- guards nothing for a row whose half is NULL.
--
-- Apply once as: sudo mysql hlstatsx < migrate_037_matches_half_not_null.sql
-- Post-apply: 2_migrate_037_matches_half_not_null_VERIFY.sql, in the ROOT
--   migration queue. The VERIFY file stays OUT of this directory.
-- STATUS: staged, not applied. The queue copy carries the same bytes.
--
-- DEPLOY ORDER: ANY. There is no daemon change and no API change. half keeps
-- its type, its default and its meaning, the only writer already emits an
-- integer on every path, and no reader learns anything new.
--
-- -- WHY -------------------------------------------------------------------
--
-- In MySQL two NULLs are never equal, in a UNIQUE index as in a JOIN. So a row
-- with half NULL collides with nothing: INSERT IGNORE inserts a duplicate and
-- reports success, and ON DUPLICATE KEY UPDATE takes the INSERT branch. The key
-- constrains only the rows that have a half.
--
-- This is the same defect class KTPAntiCheat migrations 114 and 115 fixed on
-- uq_identity_note and uq_steam_zip. It was found here by sweeping every
-- nullable column that sits inside a unique key.
--
-- Of the 19 columns named half declared across this repo sql directory, this is
-- the only one that is not NOT NULL. Every other per-half key in the schema is
-- built on a NOT NULL column. Nothing in this repo reasons about a NULL half on
-- ktp_matches -- no header, no inline comment, no migration. Contrast
-- migrate_028, which argues its nullable members at length and is therefore a
-- deliberate case, not this one. An unreasoned nullable member in a unique key
-- reads to the next author as a guarantee the key does not provide.
--
-- -- IS IT BEING HIT TODAY -- NO, AND THE REASON IS THE FIX -----------------
--
-- Measured read-only on production 2026-09-24:
--   4562 rows, 0 with half NULL. half = 1 on 2340 rows and half = 2 on 2222.
--   Duplicate (match_id, half) groups: 0, so the key does hold for every row
--   that exists today.
--
-- Nothing has ever landed in the hole, and the reason is structural rather than
-- lucky. There is exactly one writer of this column in the world:
--
--   * scripts/hlstats.pl doEvent_KTPMatchStart -- the sole INSERT INTO
--     ktp_matches. It writes parseHalfNumber(half), never the raw field.
--   * parseHalfNumber is TOTAL. Every branch returns an integer, including the
--     undefined input, and its fallthrough returns 1. It cannot return undef.
--   * The value is interpolated into the statement text. An undef would not
--     become SQL NULL there -- it would render as empty and fail as a syntax
--     error, which is a loud failure and not this hole.
--   * The other three UPDATE statements against ktp_matches in hlstats.pl set
--     end_time only. backfill-match-type-from-demos.py and
--     repair_backfill_match_type_13community.sql set match_type only. Nothing
--     anywhere runs SET half.
--   * No writer exists outside this repo. keep-the-prac reads the table,
--     KTPInfrastructure only documents it, and the root migration queue has
--     never written half.
--
-- That is what makes the cheap fix the correct one, and it is the OPPOSITE of
-- the situation in KTPAntiCheat 114. There, NULL was a DESIGNED value carried by
-- most rows, so the column had to stay nullable and the key had to move onto a
-- generated sentinel. Here NULL is a value the schema permits and the
-- application has never once produced.
--
--   * A generated column would be CARGO CULT. It buys nothing NOT NULL does not,
--     and it costs a second spelling of the same fact.
--   * NOT NULL moves the guarantee out of one Perl subroutine and into the
--     schema. Today the zero is held by parseHalfNumber happening to be total,
--     and nothing tells a future author the key depends on that. A later
--     writer -- a backfill, an import, an admin tool -- then fails loudly
--     instead of quietly opening the hole.
--
-- -- WILL IT FAIL ON EXISTING DATA ------------------------------------------
--
-- Only if a NULL appears between the measurement above and the run. RUN THE
-- PRE-CHECK FIRST ANYWAY, so a failure is expected rather than diagnosed. It is
-- 2_migrate_037_matches_half_not_null_PRECHECK.sql in the queue, and it is this
-- one query:
--
--     SELECT COUNT(*) AS nulls FROM ktp_matches WHERE half IS NULL
--
-- Zero means this applies cleanly. Any row means STOP: deciding which half a
-- match row belongs to is a data question, not a schema one, and it is a
-- different job from this file. Do not fold an UPDATE into this migration.
--
-- -- SQL_MODE ---------------------------------------------------------------
--
-- sql_mode on this server is STRICT_TRANS_TABLES, global and session, verified
-- read-only 2026-09-24 on MySQL 8.0.46. Under strict mode NOT NULL rejects a
-- NULL with error 1048 and the ALTER itself refuses to run while any NULL row
-- exists. Without strict mode the same ALTER converts existing NULLs to 0 with
-- only a warning, and later writes coerce a NULL to 0 -- trading a silent NULL
-- hole for a silent wrong-value hole, where 0 is not even a half this schema
-- uses on this table. So the mode is CHECKED rather than assumed: the guard
-- below refuses with an unknown-column error if it is missing, because the
-- operator client can set a session mode the server default does not.
--
-- LOCK IMPLICATIONS. NULL to NOT NULL on InnoDB is INPLACE-capable under strict
-- mode, so this is ALGORITHM=INPLACE, LOCK=NONE and reads and writes both
-- continue. At 4562 rows it is instantaneous either way. If this MySQL rejects
-- INPLACE for any reason, drop the clause and let it choose COPY -- still safe
-- at this size, in an idle window, and the statement is atomic.
--
-- NOT TOUCHED, deliberately: the unique key itself. Once the column cannot be
-- NULL, the existing UNIQUE (match_id, half) constrains every row, which is what
-- its author believed it already did. Dropping and re-adding it would be churn
-- with no effect.
--
-- THE COMMENT. MODIFY drops any column comment it does not restate, so one has
-- to be written here. The live column carries NO comment at all -- the text in
-- ktp_schema.sql never reached production, because CREATE TABLE IF NOT EXISTS is
-- a no-op against the table that already existed. The text below extends that
-- declared comment with the OT range, which is not an invention: parseHalfNumber
-- maps OTn to 2+n, and ktp_match_stats already documents half 3 and up as OT
-- rounds. Only 1 and 2 have ever been observed on this table.
--
-- IDEMPOTENT. The guard re-reads information_schema and no-ops once the column
-- is already NOT NULL, so a second run neither errors nor changes anything.

SET @strict := (SELECT @@SESSION.sql_mode LIKE '%STRICT_TRANS_TABLES%');
SET @nullable := (SELECT COUNT(*) FROM information_schema.COLUMNS
                   WHERE TABLE_SCHEMA = DATABASE()
                     AND TABLE_NAME = 'ktp_matches'
                     AND COLUMN_NAME = 'half'
                     AND IS_NULLABLE = 'YES');

-- The refusal branch is a deliberately unresolvable identifier: it stops with
-- ERROR 1054 naming the reason, because plain SQL outside a stored program has
-- no way to raise one.
SET @ddl := CASE
    WHEN @strict = 0
        THEN 'SELECT migration_037_REFUSED_sql_mode_lacks_STRICT_TRANS_TABLES'
    WHEN @nullable = 0
        THEN 'DO 0'
    ELSE CONCAT('ALTER TABLE ktp_matches MODIFY half TINYINT NOT NULL DEFAULT 1 ',
                'COMMENT ''1=first half, 2=second half, 3+=OT round'', ',
                'ALGORITHM=INPLACE, LOCK=NONE')
END;

PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;
