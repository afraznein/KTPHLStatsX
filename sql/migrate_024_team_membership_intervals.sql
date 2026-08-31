-- KTP HLStatsX Migration 024: authoritative player team-membership transitions.
-- Apply before enabling a producer that advertises the `team_membership`
-- schema-22 capability. This is private raw telemetry; no public artifact may
-- expose the match id, player id, game clock, or source event sequence.
--
-- A row records one successful DODX change-team transition. Consumers derive
-- intervals by ordering a player's rows by game_time/id, never by overwriting
-- ktp_match_players.team (which remains only a current roster snapshot).
-- `producer_sequence` is globally monotonic for one producer match/half and
-- makes UDP replay idempotent. The daemon rejects a lower membership sequence
-- during a live process; INSERT IGNORE makes restart/replay a durable no-op.

CREATE TABLE IF NOT EXISTS ktp_team_membership_events (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    server_id INT UNSIGNED NOT NULL,
    match_id VARCHAR(64) NOT NULL,
    half TINYINT UNSIGNED NOT NULL,
    map_name VARCHAR(32) NOT NULL,
    player_id INT NOT NULL,
    engine_userid INT UNSIGNED DEFAULT NULL,
    team TINYINT UNSIGNED NOT NULL COMMENT 'new team: 0=unassigned, 1=Allies, 2=Axis',
    old_team TINYINT UNSIGNED NOT NULL COMMENT 'previous team: 0=unassigned, 1=Allies, 2=Axis',
    game_time DECIMAL(10,2) NOT NULL,
    event_epoch BIGINT UNSIGNED NOT NULL,
    producer_sequence BIGINT UNSIGNED NOT NULL,
    event_time DATETIME NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uk_team_membership_sequence (server_id, match_id, half, producer_sequence),
    KEY idx_membership_player_timeline (match_id, half, player_id, game_time, id),
    KEY idx_membership_server_time (server_id, event_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Validated authoritative player team-transition events for private interval derivation';
