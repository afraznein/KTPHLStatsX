-- KTP HLStatsX Migration 034: grenade throw events. Apply after migration 033.
-- No schema-contract bump: the producer declares `grenade_throw` in
-- KSC_CAPABILITIES (KTPAMXX 1.23.0); a daemon without this migration drops
-- the markers.
--
-- WHY. The grenade lifecycle table already has the burst: its `tracked` row
-- fires from CGrenade::Detonate's own TraceLine (production: tracked ->
-- removed 0.00 s apart on 27,827 of 27,830 S10 lifecycles). What nothing
-- recorded was the throw, so cook time (fuse minus flight) and throw-spot
-- geometry were unanswerable. The producer reads the throw off AmmoX -- the
-- grenade ammo channel dropping by one with a grenade in hand -- because no
-- module forward fires at the throw (dod_client_weapon_fire for grenades runs
-- at the burst too).
--
-- Joining a throw to its burst: same match/half, same player_id, compatible
-- weapon (handgrenade/handgrenade_ex -> handgrenade, stickgrenade/_ex ->
-- stickgrenade, mills_bomb), first `tracked` row with game_time in
-- (throw.game_time, throw.game_time + 8]. Analytics does this; the daemon
-- does not correlate.
--
-- Dedup key (server, match, half, producer_sequence), migration-028 contract.

CREATE TABLE IF NOT EXISTS ktp_grenade_throw_events (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    server_id INT UNSIGNED NOT NULL,
    match_id VARCHAR(64) NOT NULL,
    half TINYINT UNSIGNED NOT NULL,
    map_name VARCHAR(32) NOT NULL,
    player_id INT NOT NULL,
    engine_userid INT UNSIGNED NOT NULL,
    weapon_id TINYINT UNSIGNED NOT NULL COMMENT '13, 14, 15, 16 or 36 as held at the throw',
    weapon_type VARCHAR(16) NOT NULL COMMENT 'handgrenade, stickgrenade, mills_bomb, handgrenade_ex, stickgrenade_ex',
    pos_x MEDIUMINT DEFAULT NULL COMMENT 'Private: never publish',
    pos_y MEDIUMINT DEFAULT NULL COMMENT 'Private: never publish',
    pos_z MEDIUMINT DEFAULT NULL COMMENT 'Private: never publish',
    yaw DECIMAL(5,1) DEFAULT NULL COMMENT 'view yaw at the throw; NULL when unreadable',
    pitch DECIMAL(5,1) DEFAULT NULL COMMENT 'view pitch at the throw',
    game_time DECIMAL(10,2) NOT NULL,
    event_epoch BIGINT UNSIGNED NOT NULL,
    producer_sequence BIGINT UNSIGNED NOT NULL,
    event_time DATETIME NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (id),
    UNIQUE KEY uk_grenade_throw_producer_sequence
        (server_id, match_id, half, producer_sequence),
    KEY idx_grenade_throw_player
        (match_id, half, player_id, game_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Grenade throws (AmmoX edge); the burst is ktp_grenade_entity_events kind=tracked';

-- Verify, once a 1.23.0 producer has played a half: flight time distribution
-- should sit under the ~5 s fuse, shorter when cooked.
--
--   SELECT t.weapon_type, COUNT(*) AS throws,
--          ROUND(AVG(b.game_time - t.game_time), 2) AS mean_flight_s
--   FROM ktp_grenade_throw_events t
--   JOIN ktp_grenade_entity_events b
--     ON b.match_id = t.match_id AND b.half = t.half
--    AND b.owner_player_id = t.player_id AND b.entity_kind = 'tracked'
--    AND b.game_time > t.game_time AND b.game_time <= t.game_time + 8
--   GROUP BY t.weapon_type;
