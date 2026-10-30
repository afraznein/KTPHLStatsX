-- ENGINE: mysql (hlstatsx on the data server -- NOT the Supabase editor)
-- KTP HLStatsX Migration 047: the move census completes its time ledger.
--
-- STATUS: APPLIED to production 2026-10-23 08:17 ET on operator authorisation
--   (ledger row `dpl-5a56`). File md5 `0f8ba98b1f310ba323f7b182f78caa33`, matched against
--   this repo's `origin/main` blob on both ends before it ran; verified on the schema,
--   `ktp_move_census` 29 -> 30 columns with `air_ms_standing` at ordinal 25, directly after
--   `ground_ms_ducked_silent`. This line read "STAGED, not applied" for a week afterwards.
--   Pairs with KTPAMXX stats_logging 1.31.0, which
--   appends air_ms_standing to the move_census line and stops counting landing
--   steps in steps_ducked. The field is OPTIONAL on the wire: the daemon stores ''
--   when a 1.29.0/1.30.0 producer omits it, so the deploy order is the usual one.
--
-- Apply once as: sudo mysql hlstatsx < migrate_047_move_census_air_standing.sql
--
-- DEPLOY ORDER: this migration, then the daemon, then the producer.
--
-- WHY. Two nights of 046's columns showed 100% of crouched time above 100 u/s
-- inside windows that also held airborne-crouched time, with cue rates in those
-- buckets far past any step cadence: landing steps, on duck-jump chains. The live
-- quiet-movement pattern is airborne travel (no footsteps) punctuated by landings,
-- and the row could not price it because airborne time was recorded only when the
-- player had ducked in the air (air_ms_ducked).
--
--   air_ms_standing   ms airborne while NOT crouched, by horizontal speed bucket.
--                     With air_ms_ducked, ground_ms_standing and ground_ms_ducked the
--                     time ledger is complete, so distance covered per emitted cue
--                     (steps_ground) can be summed per window.
--
-- steps_ducked changes MEANING from the same producer version: it now excludes
-- steps emitted when the previous command was airborne (landings). Rows written
-- by 1.29.0/1.30.0 carry landings in that column; tell them apart by whether
-- air_ms_standing is '' (old producer) or not.
--
-- MEASURE-ONLY. '' means the producer did not report the field, never a row of
-- zeros.

ALTER TABLE ktp_move_census
  ADD COLUMN air_ms_standing varchar(160) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT ''
    COMMENT 'ms airborne while NOT crouched, by horizontal speed bucket; with air_ms_ducked completes the time ledger; empty = producer did not report (pre-1.31.0). From 1.31.0 steps_ducked excludes landing steps.'
    AFTER ground_ms_ducked_silent;
