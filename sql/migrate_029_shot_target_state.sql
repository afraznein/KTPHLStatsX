-- KTP HLStatsX Migration 029: target state at trace time on ktp_shot_events.
-- Apply after migration 028 (shot-event dedup guard).
--
-- WHY. ~24% of shots the server's own lag-compensated trace confirmed struck a
-- real studio hitbox produce a matching damage row (measured fleet-wide over a
-- week, uniform across all 14 endpoints). A confirmed hit with no damage has
-- exactly three explanations and only the target's own state at the instant the
-- trace resolved separates them:
--
--   1. the target was already dead -- another shot resolved first in the same
--      tick, so the damage hook had nothing left to damage. tgt_dead=1, or
--      tgt_health<=0 while tgt_dead is still 0 (killed this very tick, deadflag
--      not yet set).
--   2. the target was a teammate -- friendly-fire damage the game DLL zeroed
--      before the damage hook ran, which writes no ktp_ac_weapon_hits row at all
--      (that table has never carried a damage=0 row). tgt_team = shooter_team.
--   3. neither -- a live enemy, hit confirmed, no damage recorded. This is the
--      only case that means damage is genuinely going missing, and it is the
--      one this migration exists to count.
--
-- Reconstructing any of this after the fact from separately-ingested tables
-- cannot tell the three apart: a frag-timing proxy correlates (unmatched fires
-- are 3.3x more likely to sit within 30ms of some kill) but cannot say whether
-- THIS shot's own target was the one who died. These columns can.
--
-- All four are NULLABLE and NULL is the normal state: the producer sends the
-- group only when a trace-time stash belongs to that exact shot, so a miss, a
-- grenade/melee dispatch, or a stash that belonged to another dispatch all
-- land as NULL rather than a sentinel. Never write -1 here -- tgt_health is
-- legitimately negative for a target already below zero, so a -1 stored as data
-- is indistinguishable from the measurement that matters most.

SET @clauses := CONCAT_WS(', ',
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_shot_events' AND COLUMN_NAME='tgt_health'), 'ADD COLUMN tgt_health SMALLINT DEFAULT NULL COMMENT ''target health at trace time -- <=0 with tgt_dead=0 is a same-tick kill''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_shot_events' AND COLUMN_NAME='tgt_dead'), 'ADD COLUMN tgt_dead TINYINT UNSIGNED DEFAULT NULL COMMENT ''1 when the target deadflag was set at trace time''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_shot_events' AND COLUMN_NAME='tgt_team'), 'ADD COLUMN tgt_team TINYINT DEFAULT NULL COMMENT ''target team at trace time''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_shot_events' AND COLUMN_NAME='shooter_team'), 'ADD COLUMN shooter_team TINYINT DEFAULT NULL COMMENT ''shooter team at trace time, so tgt_team needs no roster join''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_shot_events' AND COLUMN_NAME='shot_ping'), 'ADD COLUMN shot_ping SMALLINT DEFAULT NULL COMMENT ''shooter measured ping ms at trace time -- the only per-shot ping there is''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_shot_events' AND COLUMN_NAME='shot_loss'), 'ADD COLUMN shot_loss SMALLINT DEFAULT NULL COMMENT ''shooter measured loss at trace time''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_shot_events' AND COLUMN_NAME='cmd_traces'), 'ADD COLUMN cmd_traces SMALLINT DEFAULT NULL COMMENT ''player-hitting traces in the shooter cmd -- >1 means this sample may not be the bullet''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_shot_events' AND COLUMN_NAME='trace_frac'), 'ADD COLUMN trace_frac SMALLINT DEFAULT NULL COMMENT ''trace flFraction x10000 -- how far along the ray it stopped''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_shot_events' AND COLUMN_NAME='trace_flags'), 'ADD COLUMN trace_flags TINYINT UNSIGNED DEFAULT NULL COMMENT ''bit0 trace started in solid, bit1 all solid, bit2 target SOLID_NOT, bit3 target DAMAGE_NO''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_shot_events' AND COLUMN_NAME='trace_start_off'), 'ADD COLUMN trace_start_off MEDIUMINT DEFAULT NULL COMMENT ''units from the shooter eye to the trace start -- ~0 eye-origin, large = wall-penetration continuation''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_shot_events' AND COLUMN_NAME='cmd_all_traces'), 'ADD COLUMN cmd_all_traces SMALLINT DEFAULT NULL COMMENT ''every trace the shooter owned that cmd, not just player-hitting ones''', NULL));
SET @ddl := IF(@clauses IS NULL OR @clauses='', 'DO 0', CONCAT('ALTER TABLE ktp_shot_events ', @clauses));
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- The three-way partition this exists to produce, once rows carry it:
--
--   SELECT
--     CASE
--       WHEN tgt_dead IS NULL                     THEN 'no target state'
--       WHEN cmd_traces > 1                       THEN 'unattributed (multi-trace cmd)'
--       WHEN tgt_dead = 1 OR tgt_health <= 0      THEN 'already dead'
--       WHEN tgt_team = shooter_team              THEN 'teammate'
--       ELSE                                           'live enemy, unexplained'
--     END AS bucket,
--     COUNT(*)
--   FROM ktp_shot_events
--   WHERE match_id IS NOT NULL
--   GROUP BY bucket;
--
-- 'live enemy, unexplained' is the smoking gun, and the cmd_traces arm above is
-- what keeps that claim honest. The capture is first-wins within a usercmd and
-- cannot prove the sample it kept was the bullet's own trace rather than a
-- game-DLL trace that displaced it; a displaced sample reports a hitgroup,
-- applies no damage, and leaves health flat -- indistinguishable from a real
-- disappearing shot. Counting the cmd's player-hitting traces is the only way to
-- separate them, so anything with more than one candidate is set aside rather
-- than counted as evidence. Measured on a bot match 2026-09-12 BEFORE this
-- column existed: 41.7% of confirmed live-enemy hits had no damage row and 100%
-- of those left health flat, which is exactly the ambiguity this resolves.
--
-- shot_ping is the field that matters once this runs against live players:
-- nothing else anywhere records a per-shot ping, and a hitreg failure caused by
-- the network should concentrate in the high-ping tail. Bots make it uniformly
-- 0, which is precisely why a bot lane cannot answer the production question.
