-- KTP HLStatsX Migration 032: expansion wave 1, additive fields on existing
-- streams. Apply after migration 031. No schema-contract bump: every column
-- is optional and NULL from a pre-wave-1 producer (KTPAMXX < 1.21.0), so a
-- mixed fleet keeps writing. Spec: ENGINE_STATS_EXPANSION_PLAN_20260909.md
-- sections 3.1, 3.4, 3.6a, 3.8, 3.9, 3.10.
--
-- WHY. The producer already had every one of these in hand at emit time and
-- threw them away: how far a cap got before it was broken, how much of a hit
-- actually landed on the health bar (overkill/armour), how many rounds a life
-- fired before it ended and how long it waited to start, what a flag's map
-- entity says it is worth, and where killer and victim were looking at the
-- kill. Each is a field on a row that already exists, not a new stream --
-- same sequence space, same health accounting, same dedup key.
--
-- NULL semantics, deliberately uniform: the daemon writes NULL for an absent
-- field, a malformed field, and the producer's own "no value" sentinels
-- (progress -1 = the flag had no cap timer, first_shot_delay -1 = the life
-- never fired, angle -999 = edict unreadable). 0 is a real measurement on
-- every column here, so nothing is ever defaulted to it.

SET @clauses := CONCAT_WS(', ',
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_objective_attempt_events' AND COLUMN_NAME='progress'), 'ADD COLUMN progress TINYINT UNSIGNED DEFAULT NULL COMMENT ''cap progress 0-100 at this event; NULL when the flag had no cap timer or the producer predates wave 1''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_objective_attempt_events' AND COLUMN_NAME='peak_progress'), 'ADD COLUMN peak_progress TINYINT UNSIGNED DEFAULT NULL COMMENT ''highest cap progress reached during this attempt; NULL as progress''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_objective_attempt_events' AND COLUMN_NAME='timetocap'), 'ADD COLUMN timetocap DECIMAL(6,1) DEFAULT NULL COMMENT ''flag CA_timetocap seconds at this event''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_objective_attempt_events' AND COLUMN_NAME='round_time_left'), 'ADD COLUMN round_time_left DECIMAL(7,1) DEFAULT NULL COMMENT ''dodx_get_round_time() seconds at this event''', NULL)
);
SET @ddl := IF(@clauses IS NULL OR @clauses = '', 'DO 0', CONCAT('ALTER TABLE ktp_objective_attempt_events ', @clauses));
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @clauses := CONCAT_WS(', ',
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_damage_events' AND COLUMN_NAME='health_before'), 'ADD COLUMN health_before SMALLINT DEFAULT NULL COMMENT ''victim health before the hit (producer-tracked), NULL pre-wave-1''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_damage_events' AND COLUMN_NAME='health_after'), 'ADD COLUMN health_after SMALLINT DEFAULT NULL COMMENT ''victim health after the hit''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_damage_events' AND COLUMN_NAME='damage_applied'), 'ADD COLUMN damage_applied SMALLINT DEFAULT NULL COMMENT ''health actually removed = clamp(before - after, 0, damage); differs from damage on overkill and armour''', NULL)
);
SET @ddl := IF(@clauses IS NULL OR @clauses = '', 'DO 0', CONCAT('ALTER TABLE ktp_damage_events ', @clauses));
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @clauses := CONCAT_WS(', ',
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_life_events' AND COLUMN_NAME='shots'), 'ADD COLUMN shots SMALLINT UNSIGNED DEFAULT NULL COMMENT ''weapon_fire count during this life, all firearms''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_life_events' AND COLUMN_NAME='shots_hitscan'), 'ADD COLUMN shots_hitscan SMALLINT UNSIGNED DEFAULT NULL COMMENT ''subset of shots from hitscan firearms''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_life_events' AND COLUMN_NAME='first_shot_delay'), 'ADD COLUMN first_shot_delay DECIMAL(7,2) DEFAULT NULL COMMENT ''seconds from spawn to first shot; NULL when the life ended without firing''', NULL)
);
SET @ddl := IF(@clauses IS NULL OR @clauses = '', 'DO 0', CONCAT('ALTER TABLE ktp_life_events ', @clauses));
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @clauses := CONCAT_WS(', ',
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_flag_state_events' AND COLUMN_NAME='round_time_left'), 'ADD COLUMN round_time_left DECIMAL(7,1) DEFAULT NULL COMMENT ''dodx_get_round_time() seconds at this ownership change''', NULL)
);
SET @ddl := IF(@clauses IS NULL OR @clauses = '', 'DO 0', CONCAT('ALTER TABLE ktp_flag_state_events ', @clauses));
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @clauses := CONCAT_WS(', ',
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_flag_positions' AND COLUMN_NAME='default_owner'), 'ADD COLUMN default_owner TINYINT DEFAULT NULL COMMENT ''CP_default_owner from the map entity (0 neutral, 1 allies, 2 axis)''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_flag_positions' AND COLUMN_NAME='points_for_cap'), 'ADD COLUMN points_for_cap TINYINT DEFAULT NULL COMMENT ''CP_points_for_cap''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_flag_positions' AND COLUMN_NAME='team_points'), 'ADD COLUMN team_points TINYINT DEFAULT NULL COMMENT ''CP_team_points''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_flag_positions' AND COLUMN_NAME='timetocap'), 'ADD COLUMN timetocap DECIMAL(6,1) DEFAULT NULL COMMENT ''CA_timetocap seconds for this flag''s capture area''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_flag_positions' AND COLUMN_NAME='identity_resolved'), 'ADD COLUMN identity_resolved TINYINT DEFAULT NULL COMMENT ''dodx_cp_identity_resolved() at controlpoints_init''', NULL)
);
SET @ddl := IF(@clauses IS NULL OR @clauses = '', 'DO 0', CONCAT('ALTER TABLE ktp_flag_positions ', @clauses));
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @clauses := CONCAT_WS(', ',
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='hlstats_Events_Frags' AND COLUMN_NAME='k_yaw'), 'ADD COLUMN k_yaw DECIMAL(5,1) DEFAULT NULL COMMENT ''killer view yaw at the kill, degrees; NULL when unreadable''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='hlstats_Events_Frags' AND COLUMN_NAME='k_pitch'), 'ADD COLUMN k_pitch DECIMAL(5,1) DEFAULT NULL COMMENT ''killer view pitch at the kill, degrees''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='hlstats_Events_Frags' AND COLUMN_NAME='v_yaw'), 'ADD COLUMN v_yaw DECIMAL(5,1) DEFAULT NULL COMMENT ''victim view yaw at the kill, degrees''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='hlstats_Events_Frags' AND COLUMN_NAME='v_pitch'), 'ADD COLUMN v_pitch DECIMAL(5,1) DEFAULT NULL COMMENT ''victim view pitch at the kill, degrees''', NULL)
);
SET @ddl := IF(@clauses IS NULL OR @clauses = '', 'DO 0', CONCAT('ALTER TABLE hlstats_Events_Frags ', @clauses));
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Verify, once a 1.21.0 producer has played a half:
--
--   SELECT stop_reason, COUNT(*) AS n, ROUND(AVG(peak_progress),1) AS avg_peak
--   FROM ktp_objective_attempt_events
--   WHERE event_kind IN ('complete','stop') AND peak_progress IS NOT NULL
--   GROUP BY stop_reason;
--
--   SELECT SUM(damage) AS dealt, SUM(damage_applied) AS applied
--   FROM ktp_damage_events WHERE damage_applied IS NOT NULL;
