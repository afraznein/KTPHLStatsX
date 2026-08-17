-- KTP HLStatsX Migration 015: compact per-match flag ownership timeline
-- Run on data server before deploying a daemon/plugin that emits
-- KTP_FLAG_STATE markers:
--   mysql -u hlstatsx -p hlstatsx < migrate_015_flag_state_events.sql
--
-- One baseline row per flag and half, followed by rows only when ownership
-- changes. Joining each position sample to the latest preceding state for the
-- same (match, half, flag) reconstructs attack/hold/defense context without a
-- high-volume periodic ownership snapshot table.

CREATE TABLE IF NOT EXISTS ktp_flag_state_events (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    server_id INT UNSIGNED NOT NULL,
    match_id VARCHAR(64) NOT NULL,
    half TINYINT NOT NULL COMMENT '1/2=regulation halves, 3+=OT',
    map_name VARCHAR(32) NOT NULL,
    flag_index TINYINT UNSIGNED NOT NULL,
    flag_name VARCHAR(64) DEFAULT NULL,
    owner_team TINYINT UNSIGNED NOT NULL COMMENT '0=neutral, 1=Allies, 2=Axis',
    is_initial TINYINT(1) NOT NULL DEFAULT 0 COMMENT '1=baseline at start of this match context',
    game_time DECIMAL(10,2) NOT NULL DEFAULT 0,
    event_time DATETIME NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (id),
    KEY idx_match_timeline (match_id, half, flag_index, game_time, id),
    KEY idx_server_time (server_id, event_time),
    KEY idx_map_flag (map_name, flag_index)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Event-based flag ownership timeline: one half baseline plus owner changes';

-- Verify after an all-bot match:
--
--   SELECT match_id, half, map_name, flag_index, flag_name, owner_team,
--          is_initial, game_time, event_time
--   FROM ktp_flag_state_events
--   ORDER BY match_id, half, game_time, id;
--
-- Every populated half should begin with one is_initial=1 row per flag.
