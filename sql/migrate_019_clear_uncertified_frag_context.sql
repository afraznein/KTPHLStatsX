-- KTP HLStatsX Migration 019: clear frag_context_recorded on rows that carry
-- no context
-- Run on data server: mysql -u hlstatsx -p hlstatsx < migrate_019_clear_uncertified_frag_context.sql
--
-- A data correction, not a schema change, and the companion to the hlstats.pl
-- fix that stops the headshot_kill branch setting frag_context_recorded.
--
-- That branch set the flag alongside headshot = 1 while collecting no context at
-- all. The flag is read as "the context columns on this row are real
-- measurements", so every row it touched asserts something false. This clears
-- those assertions.
--
-- ⛔ SUPERSEDED BY MIGRATION 020, AND SELF-DISABLING ONCE 020 IS APPLIED.
-- The predicate below reads "flag set, every context column at its default" as
-- proof the flag is false. That inference held while the headshot_kill branch
-- was the only thing setting the flag with no context. It does not survive
-- daemon 0.3.12, which writes defaults for an unusable payload AND claims the
-- row, and where a genuinely certified kill can legitimately measure every
-- default at once -- standing killer, standing victim, neither scoped, all four
-- ammo reads failed, no last-flag defense, positions unreadable. Re-running it
-- then would withdraw live claims and re-open those rows to correlation.
-- frag_context_certified is the column that answers this question afterwards,
-- so the UPDATE is guarded on 020 not being applied yet and becomes a no-op
-- rather than a hazard. Do not remove that guard to "make it run".
--
-- ⏳ BEFORE 020 THIS IS TIME-SENSITIVE, AND THE WINDOW CLOSES ON ITS OWN.
-- Today the fleet runs a stats_logging build that emits headshot_kill and never frag_context, so
-- every flagged row came from the defective path and is exactly identifiable.
-- The moment any instance takes a build that emits frag_context, legitimate
-- rows start carrying the flag too. They are still distinguishable by content
-- (the predicate below), but the population stops being uniform, so run this
-- before the plugin rollout if you can.
--
-- 🔑 The predicate does not depend on a date, a server id, or on which branch
-- wrote the row -- all three would need re-deriving later, and a wrong cutoff
-- would clear legitimate rows. It keys on the contradiction itself: a row whose
-- every context column still holds its default has no context, so a flag
-- claiming context is false no matter what wrote it. Clearing it is correct
-- independently of the rollout state, which is what makes this safe to run at
-- any time, including twice.
--
-- Idempotent: rows already at 0 are not matched. Re-running is a no-op.
--
-- ⚠️ hlstats_Events_Frags is MyISAM and large, and frag_context_recorded is not
-- indexed, so this is a full scan under a write lock. It matches few rows but
-- reads every one. Apply in an idle window, alongside migration 018.

-- PRE-FLIGHT -- run this FIRST and read it before applying. It must show
-- with_context = 0. A non-zero there means some flagged row does carry real
-- context, the population is no longer uniform, and you should inspect before
-- running the UPDATE rather than assuming this migration still describes it.
--
--   SELECT
--     COUNT(*) AS flagged,
--     SUM(pos_x IS NULL AND pos_victim_x IS NULL
--         AND k_prone = 0 AND v_prone = 0 AND k_scope = 0 AND v_scope = 0
--         AND k_clip = -1 AND k_ammo = -1 AND v_clip = -1 AND v_ammo = -1
--         AND is_last_flag_defense = 0)                       AS no_context,
--     SUM(NOT (pos_x IS NULL AND pos_victim_x IS NULL
--         AND k_prone = 0 AND v_prone = 0 AND k_scope = 0 AND v_scope = 0
--         AND k_clip = -1 AND k_ammo = -1 AND v_clip = -1 AND v_ammo = -1
--         AND is_last_flag_defense = 0))                      AS with_context
--   FROM hlstats_Events_Frags
--   WHERE frag_context_recorded = 1;

SET @certified_exists = (SELECT COUNT(*) FROM information_schema.COLUMNS
                         WHERE TABLE_SCHEMA = DATABASE()
                         AND TABLE_NAME = 'hlstats_Events_Frags'
                         AND COLUMN_NAME = 'frag_context_certified');
SET @sql = IF(@certified_exists > 0, 'DO 0', '
UPDATE hlstats_Events_Frags
SET frag_context_recorded = 0
WHERE frag_context_recorded = 1
  AND pos_x IS NULL
  AND pos_victim_x IS NULL
  AND k_prone = 0
  AND v_prone = 0
  AND k_scope = 0
  AND v_scope = 0
  AND k_clip = -1
  AND k_ammo = -1
  AND v_clip = -1
  AND v_ammo = -1
  AND is_last_flag_defense = 0');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- headshot is deliberately left alone. It is the one thing those rows DID
-- measure -- the marker's whole payload -- and the per-player SUM(headshot)
-- that feeds ktp_match_stats and the ladder must not change. This migration
-- withdraws a false claim about context; it does not discard a real kill fact.

-- Verify: expects every remaining flagged row to carry real context, so on a
-- fleet that has not yet taken the new plugin this returns zero rows.
--
--   SELECT COUNT(*) FROM hlstats_Events_Frags
--   WHERE frag_context_recorded = 1
--     AND pos_x IS NULL AND k_clip = -1 AND k_prone = 0 AND k_scope = 0;
--
-- Positive control -- headshots must be untouched by this migration. Capture
-- this number BEFORE running and compare after; it must be identical.
--
--   SELECT COUNT(*) FROM hlstats_Events_Frags WHERE headshot = 1;
