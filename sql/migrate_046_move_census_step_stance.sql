-- ENGINE: mysql (hlstatsx on the data server -- NOT the Supabase editor)
-- KTP HLStatsX Migration 046: the move census says WHEN a crouched footstep
-- sounded, and how much crouched time the engine's timer order made silent.
--
-- STATUS: APPLIED to production 2026-10-20 21:39 ET on operator authorisation
--   (ledger row `dpl-b4dd`). File md5 `4c8dba2799c5bd482367f883dd9887bc`, matched against
--   this repo's `origin/main` blob on both ends before it ran; verified on the schema,
--   `ktp_move_census` 27 -> 29 columns with `steps_ducked` at ordinal 23 and
--   `ground_ms_ducked_silent` at 24, directly after `step_timer_fires`.
--   This line read "STAGED, not applied" for ten days afterwards.
--   Pairs with KTPAMXX stats_logging 1.29.0, which
--   appends two histogram fields to the move_census line. Both are OPTIONAL on
--   the wire: the daemon stores '' when a 1.25-1.28 producer omits them, so the
--   deploy order is the usual one and nothing is lost in either direction.
--
-- Apply once as: sudo mysql hlstatsx < migrate_046_move_census_step_stance.sql
--
-- DEPLOY ORDER: this migration, then the daemon, then the producer.
--   Schema ahead of code is harmless; code ahead of schema is data loss.
--
-- WHY. ktp_move_census (038) counts footsteps and crouched time, but a footstep
-- is one count whether it was a 0.7-volume sprint step or a 0.35-volume crouched
-- one, and the ratio of emitted steps to time does not separate players who move
-- crouched above crouch-walk speed from everyone else (measured 2026-10-20,
-- coordination research/movement-sound-signature). Two things the engine knows
-- and the census did not say:
--
--   steps_ducked             ground footsteps emitted while FL_DUCKING, by the
--                            horizontal speed at emission. Against ground_ms_ducked
--                            the same bucket is "sounds per second crouched at that
--                            speed". Standing steps = steps_ground - sum(steps_ducked).
--   ground_ms_ducked_silent  crouched ground time inside a step-timer window whose
--                            opening reset played no footstep. DoD's pm_shared
--                            restarts flTimeStepSound BEFORE PM_PlayStepSound skips
--                            (prone, mp_footsteps, horizontal speed <= 100), so a reset
--                            taken slowly buys the next window silent at any speed.
--                            A subset of ground_ms_ducked.
--
-- MEASURE-ONLY, like the rest of the row: no threshold, no verdict. '' means the
-- producer did not report the field (pre-1.29.0 rows); it is never a histogram of
-- zeros, which would read as "crouched at speed and silent" for every old row.

ALTER TABLE ktp_move_census
  ADD COLUMN steps_ducked varchar(160) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT ''
    COMMENT 'ground footsteps emitted while crouched, by horizontal speed bucket at emission; standing steps = steps_ground - sum of this row; empty = producer did not report (pre-1.29.0)'
    AFTER step_timer_fires,
  ADD COLUMN ground_ms_ducked_silent varchar(160) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT ''
    COMMENT 'ms on the ground crouched inside a step-timer window whose opening reset played no footstep, by speed bucket; subset of ground_ms_ducked; empty = producer did not report (pre-1.29.0)'
    AFTER steps_ducked;
