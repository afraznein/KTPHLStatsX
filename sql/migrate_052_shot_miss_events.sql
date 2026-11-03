-- ENGINE: mysql (hlstatsx on the data server -- NOT the Supabase editor)
-- KTP HLStatsX Migration 052: ktp_shot_miss_events, the record a shot that hit
-- nobody leaves behind (stats_logging 1.37.0, capability `shot_miss`).
--
-- STATUS: proposed, not applied.
--
-- Apply once as: sudo mysql hlstatsx < migrate_052_shot_miss_events.sql
-- Idempotent: CREATE TABLE IF NOT EXISTS, so a second run is a no-op.
--
-- DEPLOY ORDER: this migration, then the daemon, then the producer. The daemon
--   names every column below in one batched INSERT, so a daemon ahead of this
--   migration loses EVERY row of the stream. Schema ahead of code is inert;
--   code ahead of schema is data loss.
--
--   🔴 AND THE DAEMON MUST LAND BEFORE THE PRODUCER IS FIELDED, which is a
--   stronger constraint than this stream's own rows. ksc_emit_health loops the
--   producer's whole event enum, so a plugin that GAINS a stream emits a
--   KTP_CAPTURE_HEALTH row for it whether or not it announces the capability --
--   and a type missing from the daemon's health allow-list is rejected for the
--   WHOLE half, taking every other stream's accounting with it. `move` did
--   exactly that on 2026-09-29. KTPInfrastructure's CAPTURE_EVENT_TYPES_OPTIONAL
--   has to learn the name for the same reason, and first.
--
--   No KSC_SCHEMA_CONTRACT bump: the capability bit is the gate, so a producer
--   without it is refused on the bit rather than having its manifest rejected.
--
-- WHY. The shot row's whole diagnostic group -- target state, ping/loss, trace
-- mechanics, hitgroup -- is stamped from inside the player-hit filter, so a shot
-- that resolved against the world carries sentinels across all of it and its ray
-- is lost with them. That is the population the zero-spread counterfactual needs
-- most: a shot that missed is the only one with a counterfactual to ask about.
-- dodx_get_shot_miss (the cmd's first shooter-owned trace) and
-- dodx_get_shot_traces (how many traces that cmd owned) are the only record such
-- a shot leaves, and nothing consumed either until this stream.
--
-- A SEPARATE TABLE, not columns on ktp_shot_events, because the wire could not
-- carry it: the shot line's worst case sits inside fifty bytes of the ceiling
-- where ReHLDS's Log_Printf truncates it, and the ray is three coordinate
-- triples. Join on (server_id, match_id, half, shot_sequence) against
-- ktp_shot_events.producer_sequence -- the shot row holds this one's map,
-- position, angles and weapon state, so none of it is duplicated here.
--
-- MEASURE-ONLY, and that is a contract rather than a phase. A ray says where a
-- bullet went; it never says whether the shooter should have hit. Nothing here
-- or in the handler applies a threshold, a ratio or a conclusion.
--
-- NULL semantics, which differ per group and are the easiest thing to get wrong:
--   * trace_frac is the RAY's presence key, and the native says why in terms: a
--     real fraction is 0..10000 and a world coordinate has no out-of-range value
--     to test instead. The producer's -1 is "no sample" and stores NULL, taking
--     the flags, the entity, the trace weapon and all nine coordinates with it.
--   * cmd_traces_any has its OWN presence key. It is a separate stash on the
--     same cmd and can survive when the ray does not; -1 is "no count", 0 is
--     real. A row with a count and no ray is a legitimate measurement.
--   * trace_ent and trace_weapon_id are SIGNED. Once a ray exists, -1 is real
--     data on both ("no edict at all", and no weapon stamped at trace time);
--     without one it is the array's pre-read fill. trace_frac is what tells the
--     two apart, which is the whole reason the presence key is a separate field.
--   * The coordinates land NULL together or not at all. An absent ray reaches
--     the daemon as an EMPTY field and must never become 0 0 0, which is a legal
--     world coordinate and would read as a measurement.
--   * trace_flags 0 is real: the trace started in open space, stopped short of
--     its full length, and hit no player.
--
-- ⚠️ trace_flags bit3 means the cmd's first trace hit a PLAYER -- so that row is
-- not a miss at all. Those rows are STORED rather than filtered out: the native
-- declines to make that call, and filtering producer-side would make this
-- table's population depend on a producer guess instead of a stored fact.
-- Filter on `trace_flags & 8` at read time.
--
-- ⚠️ The ray is the cmd's FIRST shooter-owned trace, which is not provably the
-- bullet's: the bullet traces in PostThink and a trace from player Think or a
-- touch handler runs earlier in the same cmd. cmd_traces_any is the control --
-- a count of 1 means this trace was the cmd's only one.
--
-- 🔴 READING-END OBLIGATION. A new ktp_* table is unreadable by the analytics and
-- API accounts until a per-table GRANT SELECT is applied, and the symptom is NOT
-- "denied": information_schema hides a table the asking account cannot see, so a
-- probe reports the table ABSENT and the reader concludes this migration never
-- ran. Three tables have been lost that way (ktp_hitreg_quality 2026-09-22,
-- ktp_move_census and ktp_aim_vis 2026-10-05). The grant is deliberately NOT run
-- here -- MySQL ERROR 1410 on a missing account would break a fresh install and
-- the parity container -- so it is staged separately in the operator queue,
-- per-table and SELECT only, never ON hlstatsx.*.

CREATE TABLE IF NOT EXISTS ktp_shot_miss_events (
    id BIGINT UNSIGNED AUTO_INCREMENT,
    server_id INT UNSIGNED NOT NULL,
    match_id VARCHAR(64) DEFAULT NULL,
    half TINYINT NOT NULL DEFAULT 0 COMMENT '0=no match context, 1/2=half, 3+=OT',
    player_id INT NOT NULL,
    weapon_id SMALLINT UNSIGNED NOT NULL COMMENT 'the weapon ACTUATED; trace_weapon_id is what was held at trace time, and a disagreement is itself a signal',

    shot_sequence BIGINT UNSIGNED DEFAULT NULL COMMENT 'joins ktp_shot_events.producer_sequence within the same (server_id, match_id, half); NULL when the shot row''s sequence was unusable',
    cmd_traces_any INT UNSIGNED DEFAULT NULL COMMENT 'traces the shooter owned in this usercmd, whatever they hit; own presence key, so it survives when the ray does not. NULL is no count; 0 is real',

    trace_frac SMALLINT UNSIGNED DEFAULT NULL COMMENT 'the RAY GROUP''S PRESENCE KEY: trace fraction x10000, 0-10000. NULL means no sample and every ray field below is NULL with it',
    trace_flags TINYINT UNSIGNED DEFAULT NULL COMMENT 'bit0 started in solid, bit1 all in solid, bit2 ran full length and hit nothing, bit3 HIT A PLAYER (so not a miss -- filter on & 8). 0 is real',
    trace_ent MEDIUMINT DEFAULT NULL COMMENT 'SIGNED: what the trace resolved against. 0 is worldspawn, above 0 that entity, -1 no edict at all -- all three real once trace_frac is non-NULL',
    trace_weapon_id SMALLINT DEFAULT NULL COMMENT 'SIGNED: weapon held at trace time, DATA not a validation key; -1 (none stamped) is real once trace_frac is non-NULL',

    ray_start_x MEDIUMINT DEFAULT NULL COMMENT 'where the trace started, integer world units -- same precision as ktp_shot_events.pos_x, so the two are directly comparable',
    ray_start_y MEDIUMINT DEFAULT NULL,
    ray_start_z MEDIUMINT DEFAULT NULL,
    ray_aim_x MEDIUMINT DEFAULT NULL COMMENT 'where it was AIMED, not where it stopped',
    ray_aim_y MEDIUMINT DEFAULT NULL,
    ray_aim_z MEDIUMINT DEFAULT NULL,
    ray_end_x MEDIUMINT DEFAULT NULL COMMENT 'where it stopped',
    ray_end_y MEDIUMINT DEFAULT NULL,
    ray_end_z MEDIUMINT DEFAULT NULL,

    game_time FLOAT NOT NULL COMMENT 'the forward''s own gametime param, seconds since map start',
    event_epoch BIGINT UNSIGNED DEFAULT NULL COMMENT 'producer wall-clock, for AC-ledger join',
    producer_sequence BIGINT UNSIGNED DEFAULT NULL,
    event_time DATETIME NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (id),
    -- Same dedup contract as migration 028 and every ktp_* table since: a
    -- duplicate key here can only be a retried resend of the same marker, never
    -- two different shots, so the daemon's batch no-ops it. NULL never collides
    -- with NULL, so a marker that arrived without a usable sequence loses only
    -- its guard. In the CREATE TABLE from the start, unlike 027, which shipped
    -- without it and needed 028 to add it.
    UNIQUE KEY uniq_producer (server_id, match_id, half, producer_sequence),
    KEY idx_server (server_id),
    KEY idx_match (match_id),
    KEY idx_player (player_id),
    KEY idx_event_time (event_time),
    -- The join path back to the shot row.
    KEY idx_shot_join (server_id, match_id, half, shot_sequence)
    -- No FOREIGN KEY to hlstats_Servers/hlstats_Players: the HLStatsX base
    -- tables are MyISAM, same reason as every other ktp_* table here.
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='The ray and trace count of a shot that hit nobody -- the only record such a shot leaves. Joins ktp_shot_events on shot_sequence';

-- Verify, once a 1.37.0 producer has played a human half with
-- ktp_stats_shot_detail 1:
--
--   SELECT COUNT(*) AS rows_total,
--          SUM(trace_frac IS NOT NULL) AS with_ray,
--          SUM(cmd_traces_any IS NOT NULL) AS with_count,
--          SUM(trace_flags & 8 <> 0) AS first_trace_hit_a_player,
--          SUM(shot_sequence IS NOT NULL) AS joinable
--   FROM ktp_shot_miss_events
--   WHERE event_time >= '<first 1.37.0 half>';
--
-- And the join that is the point of the stream -- a shot with no target state
-- that nonetheless traced somewhere:
--
--   SELECT s.id, s.weapon_id, m.trace_frac, m.cmd_traces_any,
--          m.ray_start_x, m.ray_start_y, m.ray_start_z,
--          m.ray_end_x, m.ray_end_y, m.ray_end_z
--   FROM ktp_shot_events s
--   JOIN ktp_shot_miss_events m
--     ON  m.server_id = s.server_id
--     AND m.match_id  = s.match_id
--     AND m.half      = s.half
--     AND m.shot_sequence = s.producer_sequence
--   WHERE s.tgt_dead IS NULL
--     AND (m.trace_flags & 8) = 0
--   LIMIT 20;
