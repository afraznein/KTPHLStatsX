-- KTP HLStatsX data repair: damage rows zeroed between 2026-08-21 and 2026-08-24
--
-- NOT a migration -- a one-time production data repair, proposed for operator
-- review. Deliberately named outside the migrate_NNN pattern so no migration
-- runner picks it up. Apply by hand, dry-run first, in an idle window.
--
-- Context (issue #33): from 2026-08-21 ~13:00 ET until the 0.3.12 daemon
-- restart at 2026-08-24 08:30 ET, doEvent_KTPMatchEnd derived damage solely
-- from ktp_damage_events. Only one instance (Denver 4, server_id 14) produced
-- that ledger, so every other instance had COALESCE(dmg.damage, 0) publish a
-- measured zero for every player. The forward fix (ktpDamageExpr, merged in
-- PR #35 and live since 2026-08-24 08:30) writes NULL when the ledger is
-- absent -- but the rows written inside the window are still false zeros.
--
-- Measured 2026-08-25 (read-only, production):
--   * 844 per-half player rows with damage = 0 in the window on halves with
--     no ktp_damage_events
--   * 70 distinct match/halves affected -- 69 of them have StatsMe rows for
--     the same match/half, so real damage is recoverable
--   * pre-2026-08-21 damage was itself StatsMe-derived (see ce17266), so a
--     StatsMe restore gives the window the same definition as the days
--     around it rather than a third definition
--
-- Repair shape, three statements, in order:
--   1. restore damage from hlstats_Events_Statsme where that source exists
--      (COALESCE(sum, 0) -- a player with no StatsMe rows in a covered half
--      dealt no damage under the old definition, exactly as pre-08-21 rows
--      were written)
--   2. write NULL where no source at all exists (the honest absence, matching
--      what 0.3.12 would have written)
--   3. recompute the half = 0 totals row from the repaired halves, matching
--      the daemon's own SUM(damage) semantics (SUM skips NULL halves and
--      returns NULL only when every half is NULL)
--
-- Guards: every statement requires damage = 0 today, the match window, and
-- NOT EXISTS on ktp_damage_events for that match/half -- so Denver 4 rows
-- (which have the ledger and whose zeros are real measurements) and genuine
-- zero-damage players outside the window are untouchable by construction.
--
-- ---------------------------------------------------------------------------
-- DRY RUN -- run these first and compare against the measured figures above.
-- Expected: ~844 / ~70 / ~69 on a database where the repair has not run, and
-- 0 affected rows when re-run after the repair (the statements are idempotent
-- because the damage = 0 guard no longer matches restored or NULLed rows).
-- ---------------------------------------------------------------------------

SELECT COUNT(*) AS rows_to_repair
FROM ktp_match_stats s
JOIN ktp_matches m ON m.match_id = s.match_id AND m.half = s.half
WHERE s.damage = 0
  AND m.start_time >= '2026-08-21 12:00:00'
  AND m.start_time <  '2026-08-24 08:30:00'
  AND NOT EXISTS (SELECT 1 FROM ktp_damage_events d
                  WHERE d.match_id = s.match_id AND d.half = s.half);

SELECT COUNT(*) AS halves_affected,
       SUM(sm.has_sm IS NOT NULL) AS halves_recoverable_from_statsme
FROM (SELECT DISTINCT s.match_id, s.half
      FROM ktp_match_stats s
      JOIN ktp_matches m ON m.match_id = s.match_id AND m.half = s.half
      WHERE s.damage = 0
        AND m.start_time >= '2026-08-21 12:00:00'
        AND m.start_time <  '2026-08-24 08:30:00'
        AND NOT EXISTS (SELECT 1 FROM ktp_damage_events d
                        WHERE d.match_id = s.match_id AND d.half = s.half)) z
LEFT JOIN (SELECT DISTINCT match_id, half, 1 AS has_sm
           FROM hlstats_Events_Statsme
           WHERE match_id IS NOT NULL) sm
       ON sm.match_id = z.match_id AND sm.half = z.half;

-- ---------------------------------------------------------------------------
-- Statement 1: restore from StatsMe where the half has StatsMe coverage
-- ---------------------------------------------------------------------------

UPDATE ktp_match_stats s
JOIN ktp_matches m ON m.match_id = s.match_id AND m.half = s.half
SET s.damage = COALESCE(
        (SELECT SUM(sm.damage)
           FROM hlstats_Events_Statsme sm
          WHERE sm.match_id = s.match_id
            AND sm.half = s.half
            AND sm.playerId = s.player_id), 0)
WHERE s.damage = 0
  AND m.start_time >= '2026-08-21 12:00:00'
  AND m.start_time <  '2026-08-24 08:30:00'
  AND NOT EXISTS (SELECT 1 FROM ktp_damage_events d
                  WHERE d.match_id = s.match_id AND d.half = s.half)
  AND EXISTS (SELECT 1 FROM hlstats_Events_Statsme sm2
              WHERE sm2.match_id = s.match_id AND sm2.half = s.half);

-- ---------------------------------------------------------------------------
-- Statement 2: no ledger and no StatsMe -- the absence is honest, write NULL
-- ---------------------------------------------------------------------------

UPDATE ktp_match_stats s
JOIN ktp_matches m ON m.match_id = s.match_id AND m.half = s.half
SET s.damage = NULL
WHERE s.damage = 0
  AND m.start_time >= '2026-08-21 12:00:00'
  AND m.start_time <  '2026-08-24 08:30:00'
  AND NOT EXISTS (SELECT 1 FROM ktp_damage_events d
                  WHERE d.match_id = s.match_id AND d.half = s.half)
  AND NOT EXISTS (SELECT 1 FROM hlstats_Events_Statsme sm2
                  WHERE sm2.match_id = s.match_id AND sm2.half = s.half);

-- ---------------------------------------------------------------------------
-- Statement 3: recompute the half = 0 totals rows for window matches from the
-- repaired per-half rows. Derived table sidesteps MySQL error 1093. Plain SUM
-- matches the daemon's own totals write: NULL halves are skipped, and the
-- total is NULL only when every half is NULL.
-- ---------------------------------------------------------------------------

UPDATE ktp_match_stats t
JOIN (SELECT match_id, player_id, SUM(damage) AS dmg_total
        FROM ktp_match_stats
       WHERE half > 0
       GROUP BY match_id, player_id) h
  ON h.match_id = t.match_id AND h.player_id = t.player_id
JOIN (SELECT DISTINCT match_id
        FROM ktp_matches
       WHERE start_time >= '2026-08-21 12:00:00'
         AND start_time <  '2026-08-24 08:30:00') w
  ON w.match_id = t.match_id
SET t.damage = h.dmg_total
WHERE t.half = 0
  AND NOT (t.damage <=> h.dmg_total);

-- ---------------------------------------------------------------------------
-- VERIFY -- after the repair:
--   * first dry-run query above returns 0
--   * the window's per-day coverage no longer reports mass zeros:
-- ---------------------------------------------------------------------------

SELECT DATE(m.start_time) AS d,
       COUNT(*)             AS rows_,
       SUM(s.damage IS NULL) AS null_,
       SUM(s.damage = 0)     AS zero_,
       SUM(s.damage > 0)     AS pos_
FROM ktp_match_stats s
JOIN ktp_matches m ON m.match_id = s.match_id AND m.half = s.half
WHERE m.start_time >= '2026-08-20 00:00:00'
  AND m.start_time <  '2026-08-25 00:00:00'
GROUP BY d ORDER BY d;
