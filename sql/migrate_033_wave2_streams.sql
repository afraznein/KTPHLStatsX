-- KTP HLStatsX Migration 033: expansion wave 2, three low-volume streams.
-- Apply after migration 032. No schema-contract bump: the producer declares
-- `score`, `duel` and `player_state` in KSC_CAPABILITIES (KTPAMXX 1.22.0) and
-- a daemon without this migration simply drops the markers.
-- Spec: ENGINE_STATS_EXPANSION_PLAN_20260909.md sections 3.2, 3.5, 3.7.
--
-- WHY. Three facts the module already had and never surfaced:
--   ktp_score_events        the engine's own score attribution -- who was
--                           credited on each cap and every territorial tick,
--                           instead of inferring credit from zone occupancy.
--   ktp_duel_stats          the per-(attacker, victim) matrix dodx keeps for
--                           free (kills, headshots, shots, hits, damage, eight
--                           hit groups), as a delta per half.
--   ktp_player_state_events prone/unprone and bipod deploy/undeploy edges with
--                           position, the prerequisite for any suppression or
--                           lane-control measure.
--
-- Index space on ktp_score_events: cp_index arrives in the game DLL's own
-- order. flag_index is that index ONLY when the producer's
-- dodx_cp_identity_resolved() said DLL order == dodx order; otherwise it is
-- -1 and dll_index keeps the raw value. Never remap on the analytics side.
--
-- Dedup key is (server, match, half, producer_sequence) on every table, the
-- same contract as migration 028; the daemon inserts with INSERT IGNORE.

CREATE TABLE IF NOT EXISTS ktp_score_events (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    server_id INT UNSIGNED NOT NULL,
    match_id VARCHAR(64) NOT NULL,
    half TINYINT UNSIGNED NOT NULL,
    map_name VARCHAR(32) NOT NULL,
    player_id INT NOT NULL,
    engine_userid INT UNSIGNED NOT NULL,
    delta SMALLINT NOT NULL COMMENT 'points awarded by this event',
    total INT NOT NULL COMMENT 'player scoreboard total after the award',
    flag_index TINYINT NOT NULL COMMENT 'dodx flag index when identity_resolved=1, else -1',
    dll_index TINYINT NOT NULL COMMENT 'raw cp_index from the game DLL, -1 when not CP-related',
    flag_name VARCHAR(32) DEFAULT NULL,
    identity_resolved TINYINT UNSIGNED NOT NULL,
    game_time DECIMAL(10,2) NOT NULL,
    event_epoch BIGINT UNSIGNED NOT NULL,
    producer_sequence BIGINT UNSIGNED NOT NULL,
    event_time DATETIME NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (id),
    UNIQUE KEY uk_score_producer_sequence
        (server_id, match_id, half, producer_sequence),
    KEY idx_score_player
        (match_id, half, player_id, event_epoch),
    KEY idx_score_flag
        (match_id, half, flag_index, event_epoch)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Engine score attribution per player (caps and territorial ticks)';

CREATE TABLE IF NOT EXISTS ktp_duel_stats (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    server_id INT UNSIGNED NOT NULL,
    match_id VARCHAR(64) NOT NULL,
    half TINYINT UNSIGNED NOT NULL,
    map_name VARCHAR(32) NOT NULL,
    attacker_id INT NOT NULL,
    attacker_userid INT UNSIGNED NOT NULL,
    victim_id INT NOT NULL,
    victim_userid INT UNSIGNED NOT NULL,
    kills SMALLINT NOT NULL,
    deaths SMALLINT NOT NULL,
    headshots SMALLINT NOT NULL,
    teamkills SMALLINT NOT NULL,
    shots INT NOT NULL,
    hits INT NOT NULL,
    damage INT NOT NULL,
    bh_generic SMALLINT NOT NULL,
    bh_head SMALLINT NOT NULL,
    bh_chest SMALLINT NOT NULL,
    bh_stomach SMALLINT NOT NULL,
    bh_leftarm SMALLINT NOT NULL,
    bh_rightarm SMALLINT NOT NULL,
    bh_leftleg SMALLINT NOT NULL,
    bh_rightleg SMALLINT NOT NULL,
    event_epoch BIGINT UNSIGNED NOT NULL,
    producer_sequence BIGINT UNSIGNED NOT NULL,
    event_time DATETIME NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (id),
    UNIQUE KEY uk_duel_producer_sequence
        (server_id, match_id, half, producer_sequence),
    KEY idx_duel_pair
        (match_id, half, attacker_id, victim_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Per-half delta of dodx get_user_vstats(attacker, victim); values as the module reports them';

CREATE TABLE IF NOT EXISTS ktp_player_state_events (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    server_id INT UNSIGNED NOT NULL,
    match_id VARCHAR(64) NOT NULL,
    half TINYINT UNSIGNED NOT NULL,
    map_name VARCHAR(32) NOT NULL,
    player_id INT NOT NULL,
    engine_userid INT UNSIGNED NOT NULL,
    kind VARCHAR(8) NOT NULL COMMENT 'prone, unprone, deploy, undeploy',
    player_class TINYINT DEFAULT NULL,
    pos_x MEDIUMINT DEFAULT NULL COMMENT 'Private: never publish',
    pos_y MEDIUMINT DEFAULT NULL COMMENT 'Private: never publish',
    pos_z MEDIUMINT DEFAULT NULL COMMENT 'Private: never publish',
    yaw DECIMAL(5,1) DEFAULT NULL COMMENT 'degrees; NULL when unreadable',
    game_time DECIMAL(10,2) NOT NULL,
    event_epoch BIGINT UNSIGNED NOT NULL,
    producer_sequence BIGINT UNSIGNED NOT NULL,
    event_time DATETIME NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (id),
    UNIQUE KEY uk_player_state_producer_sequence
        (server_id, match_id, half, producer_sequence),
    KEY idx_player_state_player
        (match_id, half, player_id, game_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Prone and bipod-deploy edges with position';

-- Verify, once a 1.22.0 producer has played a half:
--
--   SELECT identity_resolved, COUNT(*) FROM ktp_score_events GROUP BY 1;
--   SELECT kind, COUNT(*) FROM ktp_player_state_events GROUP BY 1;
--   SELECT COUNT(*) AS pairs, SUM(kills) AS kills FROM ktp_duel_stats;
