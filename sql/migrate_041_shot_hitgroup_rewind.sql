-- ENGINE: mysql (hlstatsx on the data server -- NOT the Supabase editor)
-- KTP HLStatsX Migration 041: shot-row hitgroup and per-shot rewind (schema 26),
-- plus the sv_maxunlag in force on each capture manifest.
--
-- STATUS: proposed, not applied.
--
-- Apply once as: sudo mysql hlstatsx < migrate_041_shot_hitgroup_rewind.sql
-- Idempotent: every column is added only when information_schema says it is
-- missing, so a second run is a DO 0 on both tables.
--
-- DEPLOY ORDER: this migration, then the daemon that accepts schema 26, then
--   the producer (stats_logging 1.27.0). The daemon names all four shot columns
--   in every batched shot INSERT and sv_maxunlag in every manifest INSERT, so a
--   daemon ahead of this migration loses EVERY shot row and refuses every
--   manifest -- which takes every gated stream down for the half. Schema ahead of
--   code is harmless; code ahead of schema is data loss.
--
-- WHY. Design: KTPInfrastructure docs/handover/SCHEMA_26_SHOT_HITGROUP_AND_REWIND.md.
-- The shot row gains the studio hitgroup its trace resolved on, and the rewind
-- lag compensation applied for the shot's usercmd: how deep, how deep it wanted
-- to go before the sv_maxunlag clamp, and why. Window aggregates cannot answer
-- how many shots a different ceiling would serve; per-shot rows can. The
-- manifest carries the ceiling in force so that analysis needs no join to
-- config history.
--
-- NULL semantics, all five columns: NULL is "no value", never 0. 0 is always
-- real (hitgroup 0 is generic, depth 0 is not rewound). The producer's -1
-- sentinel is stored as NULL. A producer before schema 26 sends none of these
-- and every one lands NULL.
--
-- ktp_shot_events is InnoDB, so the combined ALTER below is one table rebuild
-- at most, not one per column.

SET @clauses := CONCAT_WS(', ',
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_shot_events' AND COLUMN_NAME='hitgroup'), 'ADD COLUMN hitgroup TINYINT UNSIGNED DEFAULT NULL COMMENT ''studio hitgroup the trace resolved on (0 generic, 1 head, 2 chest, 3 stomach, 4-7 limbs); NULL when the shot has no target state or the producer predates schema 26''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_shot_events' AND COLUMN_NAME='rw_flags'), 'ADD COLUMN rw_flags TINYINT UNSIGNED DEFAULT NULL COMMENT ''rewind bits: 0 attempted, 1 reached, 2 clamped by sv_maxunlag, 3 hit the 1.5 s cap, 4 pushed to realtime, 5 estimator on, 6 interp capped/floored; NULL = no rewind record for this cmd (bot, older engine/module, or producer before schema 26)''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_shot_events' AND COLUMN_NAME='rw_depth'), 'ADD COLUMN rw_depth SMALLINT UNSIGNED DEFAULT NULL COMMENT ''ms, realtime - targettime after the sv_maxunlag clamp; NULL when rw_flags is NULL or bit0 is clear''', NULL),
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_shot_events' AND COLUMN_NAME='rw_want'), 'ADD COLUMN rw_want SMALLINT UNSIGNED DEFAULT NULL COMMENT ''ms, the same arithmetic on the pre-clamp latency; NULL as rw_depth''', NULL)
);
SET @ddl := IF(@clauses IS NULL OR @clauses = '', 'DO 0', CONCAT('ALTER TABLE ktp_shot_events ', @clauses));
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @clauses := CONCAT_WS(', ',
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_capture_manifests' AND COLUMN_NAME='sv_maxunlag'), 'ADD COLUMN sv_maxunlag DECIMAL(5,3) DEFAULT NULL COMMENT ''seconds, the sv_maxunlag in force when the producer announced this half; NULL before schema 26 or when malformed''', NULL)
);
SET @ddl := IF(@clauses IS NULL OR @clauses = '', 'DO 0', CONCAT('ALTER TABLE ktp_capture_manifests ', @clauses));
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Verify, once a schema-26 producer has played a human half:
--
--   SELECT COUNT(*) AS n, SUM(hitgroup IS NOT NULL) AS with_hitgroup,
--          SUM(tgt_dead IS NOT NULL) AS with_target,
--          SUM(rw_flags IS NOT NULL) AS with_rewind,
--          SUM(rw_flags & 4 = 4) AS clamped
--   FROM ktp_shot_events
--   WHERE event_time >= '<first stats_logging 1.27.0 half>';
--
--   SELECT schema_version, sv_maxunlag, COUNT(*) FROM ktp_capture_manifests
--   WHERE event_time >= '<same>' GROUP BY schema_version, sv_maxunlag;
