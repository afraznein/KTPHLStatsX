-- KTP HLStatsX Migration 031: the shooter's own stance and movement at trace
-- time on ktp_shot_events. Apply after migration 030 (shot target player id).
--
-- WHY. `errUdeg` (folded into trace geometry elsewhere in this stack) already
-- reports how far a shot's resolved angle missed its target by, but nothing
-- records WHY. DoD's own accuracy model applies real penalties for movement,
-- ducking/hip-fire, and recoil that has not settled between shots -- so a wide
-- miss from a shooter who was sprinting, mid-air, or firing an undeployed
-- MG42 explains itself, while the identical miss from a stationary, prone,
-- deployed shooter does not. Distinguishing those two cases from a time-window
-- correlation alone is exactly the kind of inference this stream exists to
-- replace with a measurement.
--
-- These are SHOOTER fields, not target fields -- do not confuse
-- shooter_flags/shooter_punch_* with anything in migration 029, which
-- describes the player the trace HIT. Same trace-time instant, same
-- presence key (tgt_dead, migration 029's group) as the rest of that stash:
-- the producer stamps this whole group together or not at all, since it is
-- captured in the identical first-wins window off the shooter's own edict.
--
-- shooter_flags packs three booleans (matching migration 029's trace_flags
-- convention -- one bitfield rather than three columns):
--   bit0 FL_ONGROUND at trace time.
--   bit1 FL_DUCKING at trace time.
--   bit2 IN_ATTACK2 held -- an MG42/BAR bipod deploy, or a scoped weapon's
--        scope. Both are real DoD accuracy-model inputs, not decoration.
--
-- shooter_punch_pitch/yaw: v.punchangle at trace time, CENTIDEGREES (the
-- producer sends x100, matching trace_frac's fixed-point convention rather
-- than a float on the wire). Unsettled recoil from a PRIOR shot pushes THIS
-- shot's aim off by exactly this much.
--
-- shooter_speed: magnitude of v.velocity, world units/sec. Not a vector --
-- the analysis question is "was this shooter moving fast", not which
-- direction.
--
-- shooter_stamina: v.fuser4, DoD's stamina gauge, unscaled. DoD's own range
-- for this field is not documented anywhere accessible to this stack, so it
-- ships raw rather than guessing a normalization that could be wrong.
--
-- NULLABLE, and NULL is the normal state on the same terms as the rest of
-- this stash: the producer sends the whole target-adjacent group only when a
-- trace-time stash belongs to that exact shot. Never a sentinel -- a real
-- punch angle or stamina value can legitimately be 0 or negative, so there is
-- no safe placeholder that means "absent" other than NULL itself.

SET @clauses := CONCAT_WS(', ',
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_shot_events' AND COLUMN_NAME='shooter_flags'), 'ADD COLUMN shooter_flags TINYINT UNSIGNED DEFAULT NULL COMMENT ''bit0 FL_ONGROUND, bit1 FL_DUCKING, bit2 IN_ATTACK2 held, all at trace time''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_shot_events' AND COLUMN_NAME='shooter_punch_pitch'), 'ADD COLUMN shooter_punch_pitch SMALLINT DEFAULT NULL COMMENT ''v.punchangle pitch x100 (centidegrees) at trace time -- unsettled recoil from the prior shot''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_shot_events' AND COLUMN_NAME='shooter_punch_yaw'), 'ADD COLUMN shooter_punch_yaw SMALLINT DEFAULT NULL COMMENT ''v.punchangle yaw x100 (centidegrees) at trace time''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_shot_events' AND COLUMN_NAME='shooter_speed'), 'ADD COLUMN shooter_speed SMALLINT DEFAULT NULL COMMENT ''magnitude of shooter v.velocity, world units/sec, at trace time''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_shot_events' AND COLUMN_NAME='shooter_stamina'), 'ADD COLUMN shooter_stamina SMALLINT DEFAULT NULL COMMENT ''shooter v.fuser4 (DoD stamina gauge), unscaled, at trace time''', NULL)
);
SET @ddl := IF(@clauses IS NULL OR @clauses = '', 'DO 0', CONCAT('ALTER TABLE ktp_shot_events ', @clauses));
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Verify: bucket the still-open MP40 within-weapon trace_frac split (bot
-- lane: 50% vs 100% registration, n=37) by shooter movement, to see whether
-- the low-frac cluster is explained by a shooter who was moving/ducking/
-- undeployed at trace time -- something no bot lane can vary meaningfully.
--
--   SELECT (trace_frac < 100) AS low_frac,
--          (shooter_flags & 1) AS on_ground,
--          (shooter_flags & 2) AS ducking,
--          ROUND(AVG(shooter_speed), 1) AS avg_speed,
--          COUNT(*) AS n
--   FROM ktp_shot_events
--   WHERE weapon_id = 12 AND tgt_dead IS NOT NULL
--   GROUP BY low_frac, on_ground, ducking;
