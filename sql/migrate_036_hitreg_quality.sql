-- KTP HLStatsX Migration 036: per-half hit-registration quality fact, and the
-- index that makes it cheap to compute.
-- Apply after migration 035. Schema only -- the daemon does not write this
-- table; scripts/ktp-data-server-health.sh (KTPInfrastructure) fills it once
-- per finished half and reads it hourly.
--
-- WHY. The 2026-09 hitreg investigation (coordination: infra-hitreg-diagnostics)
-- ended with one number that says whether registration is healthy: of the
-- shot rows where the server's own trace hit a live enemy cleanly
-- (tgt_dead = 0, tgt_team <> shooter_team, no trace flag), the share that has
-- a ktp_damage_events row for the same attacker/victim within 300 ms.
-- Measured 99.9% on 12,204 hits across 17 real S10 12-mans, every half at
-- 99.2-100%. Nothing watched it after the investigation closed; a regression
-- in the plugin, the daemon or the engine would look exactly like today until
-- someone re-ran the analysis by hand. This table is that number, per half,
-- so the health script can latch on it and a page can trend it.
--
-- The query behind it is a correlated lookup from each clean shot row into
-- ktp_damage_events on (match_id, attacker_id, victim_id) with a +/-0.3 s
-- window on game_time. ktp_damage_events has single-column indexes on match,
-- attacker and victim; none covers the triple, so the hand-run analysis took
-- ~4 minutes for 17 matches. idx_damage_pair below turns each lookup into a
-- range seek. INPLACE, concurrent DML allowed, so it is safe to add while the
-- daemon is writing.
--
-- Only halves whose shot rows carry target state are scorable
-- (ktp_stats_shot_detail on -- 12-mans by default, KTPMatchHandler bitmask 4).
-- A half with no such rows gets no row here; the health script reports that
-- as staleness when 12-mans ran, rather than as a clean 100%.

CREATE TABLE IF NOT EXISTS ktp_hitreg_quality (
    id INT AUTO_INCREMENT,
    match_id VARCHAR(64) NOT NULL,
    half TINYINT NOT NULL COMMENT 'ktp_matches.half -- 1/2',
    server_id INT UNSIGNED NOT NULL,
    match_end DATETIME NOT NULL COMMENT 'ktp_matches.end_time, copied so the trailing window needs no join',
    clean_hits INT UNSIGNED NOT NULL COMMENT 'shot rows whose trace hit a live enemy cleanly: tgt_dead=0, tgt_team<>shooter_team, (trace_flags & 15)=0, tgt_player_id resolved',
    registered_300ms INT UNSIGNED NOT NULL COMMENT 'of clean_hits, with a ktp_damage_events row for the same attacker/victim within 0.30 s game_time',
    registered_1s INT UNSIGNED NOT NULL COMMENT 'same within 1.0 s -- separates a late row from a missing one',
    dead_target_hits INT UNSIGNED NOT NULL COMMENT 'trace hit a target already dead (burst tail); excluded from the rate',
    teammate_hits INT UNSIGNED NOT NULL COMMENT 'trace hit a teammate; excluded from the rate',
    computed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (id),
    UNIQUE KEY uk_hitreg_match_half (match_id, half),
    KEY idx_hitreg_match_end (match_end)
    -- No FOREIGN KEY: same MyISAM/InnoDB mismatch as every other ktp_* table.
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Per-half hit registration: clean live-enemy trace hits vs damage rows within 300 ms';

SET @exists := (SELECT COUNT(*) FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_damage_events' AND INDEX_NAME='idx_damage_pair');
SET @ddl := IF(@exists, 'DO 0',
    'ALTER TABLE ktp_damage_events ADD INDEX idx_damage_pair (match_id, attacker_id, victim_id, game_time), ALGORITHM=INPLACE, LOCK=NONE');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Verify:
--
--   SHOW INDEX FROM ktp_damage_events WHERE Key_name = 'idx_damage_pair';
--
-- Then, once the health script has run against a finished 12-man half:
--
--   SELECT match_id, half, clean_hits, registered_300ms,
--          ROUND(100*registered_300ms/clean_hits, 1) AS reg_pct, computed_at
--   FROM ktp_hitreg_quality ORDER BY match_end DESC LIMIT 20;
--
-- reg_pct at or above 99.5 is the measured normal; the health script warns
-- below 99.0 over a trailing 48 h once at least 300 clean hits have landed.
