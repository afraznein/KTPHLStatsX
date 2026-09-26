-- ENGINE: mysql (hlstatsx on the data server -- NOT the Supabase editor)
-- KTP HLStatsX Migration 038: crouch-input and footstep-emission census.
--
-- STATUS: APPLIED to production 2026-09-26 on operator authorisation, straight
--   from this file rather than through the root migration queue. Nothing after
--   it in the deploy order has run: the daemon and producer that write this
--   table are NOT deployed. That is the safe direction -- schema ahead of code
--   is harmless, code ahead of schema is data loss.
--   The bytes that ran are md5 8561151cdc07d0b555c0eeb265332ab4 (this file at
--   144c3e8, before this header edit); the copy kept as the queue's record is
--   migrations-to-apply/applied/MYSQL_hlstatsx_038_move_census_APPLIED_20260926.sql.
--
-- Apply once as: sudo mysql hlstatsx < migrate_038_move_census.sql
--
-- DEPLOY ORDER: this migration, then the daemon, then the producer.
--   Schema ahead of code is harmless; code ahead of schema is data loss.
--
--   The producer takes NO new schema ordinal -- it announces a `move`
--   capability at the existing one. That matters here: an unknown SCHEMA gets
--   a producer's whole manifest refused, taking every other capture stream
--   down with it for that half, while an unknown CAPABILITY loses only the
--   stream the receiver cannot read. So a producer that runs ahead of its
--   daemon costs this stream and nothing else.
--
-- Pairs with KTPAMXX's ktp_stats_capture.inc ksc_move_flush_task, gated by the
-- `move` capability in KSC_CAPABILITIES rather than by a schema ordinal. It
-- emits, once per producer window per player who moved:
--     "Player<uid><steamid><Team>" triggered "move_census"
--     (window_ms "30000") (buckets "6") (bucket_width "50") (taps "41")
--     (taps_ground "12 9 14 4 2 0") (taps_air "0 0 1 3 0 0")
--     (ground_ms_standing "8100 2400 5600 900 0 0")
--     (ground_ms_ducked "4200 1100 300 0 0 0")
--     (air_ms_ducked "0 0 0 600 900 0")
--     (stam_tap_sum "3702") (stam_tap_min "61")
--     (steps_ground "37") (steps_ladder "0") (sounds_water "0")
--     (pmove_sounds "37") (step_timer_fires "39")
--     (map "dod_anzio") (matchid "...") (half "1") (game_time "245.32")
--     (event_epoch "...") (sequence "...")
--
-- ============================================================================
-- WHAT THIS IS FOR, AND WHAT IT DELIBERATELY IS NOT
-- ============================================================================
-- A movement census. The four quantities it records -- velocity, ground contact,
-- stamina and footstep emission -- are all server-held, and none of them is
-- visible to a client, so this table is the only place they meet.
--
-- THIS TABLE CARRIES NO THRESHOLD AND SUPPORTS NO VERDICT. There is no
-- positive class yet -- a controlled reproduction has not been run -- so
-- nothing here, in the producer, or in the daemon applies a cut-point. A
-- constant chosen now would be a guess wearing the authority of a measurement.
--
-- ⚠️ THE ONE MISREADING THIS TABLE MUST NOT BE USED FOR. steps_ground alone,
-- or any ratio built from it alone, is not evidence. A player who crouch-walks
-- deliberately emits few footsteps; that is ordinary play and the whole point
-- of crouching. The tap census and the time histograms are stored in the SAME
-- ROW so the two cannot be queried apart by accident. Keep it that way.
--
-- ============================================================================
-- THE HISTOGRAMS
-- ============================================================================
-- Five space-separated fixed-length integer lists, `buckets` values each,
-- indexed by horizontal speed: bucket i covers [i*bucket_width,
-- (i+1)*bucket_width) world units/sec, and the LAST bucket is open-ended.
-- Same storage shape as ktp_duel_stats.bodyhits, which the daemon already
-- splits on whitespace; the daemon rejects a ragged or short list rather than
-- padding it, because a padded cell reads as a measured zero and zero is the
-- value this stream will most often be asked about.
--
-- A histogram, not "time above a threshold", precisely because the threshold
-- is the entire question. Storing the distribution leaves the cut-point to the
-- analysis, where it can be calibrated and changed; storing a single number
-- above a cut-point bakes today's guess into every row forever.
--
-- GROUND AND AIRBORNE ARE NEVER FOLDED TOGETHER. A duck-jump is crouching at
-- running speed by construction, so a combined row cannot be read. The existing
-- ktp_shot_events stance columns already show the two populations are nowhere
-- near each other -- ducked-and-airborne shots are taken at roughly running
-- speed, ducked-and-on-ground at roughly a standstill. Any "crouched while
-- moving fast" figure that ignores ground contact is measuring jumping.
--
-- buckets and bucket_width are STORED, not assumed. The producer's geometry can
-- change; without these columns such a change would silently reinterpret every
-- row already written and no query would notice.
--
-- ============================================================================
-- THE FOOTSTEP COLUMNS, AND THE CONTROL THAT MAKES THEM READABLE
-- ============================================================================
-- steps_ground / steps_ladder / sounds_water / pmove_sounds count what the
-- server's movement code actually emitted for this player, captured at
-- SV_StartSound. The engine sends those to everyone EXCEPT the emitter (the
-- client predicts its own), so what is counted here is exactly what the other
-- players were sent -- not an approximation of it.
--
-- step_timer_fires is the control, and it is not optional. It observes the
-- engine's own step timer resetting, which is a different sensor for the same
-- event. Rows with timer fires but no steps mean the SERVER stopped emitting
-- footsteps -- mp_footsteps off, or a step path that stopped reaching the
-- sound hook. Without it that is indistinguishable from every player on the
-- server moving silently, and the second is the reading that would be believed.
--
--   ⚠️ CHECK IT FIRST, BEFORE ANY PER-PLAYER FIGURE:
--     SELECT SUM(steps_ground) s, SUM(step_timer_fires) t, COUNT(*) n
--     FROM ktp_move_census WHERE event_time > NOW() - INTERVAL 1 DAY;
--   s far below t fleet-wide is a broken sensor, not a quiet fleet. If it is,
--   check mp_footsteps on the instances themselves -- derive it, never assume
--   it, and never assume it is uniform.
--
-- ============================================================================
-- STAMINA
-- ============================================================================
-- stam_tap_sum / stam_tap_min are DoD's v.fuser4 read at each crouch press.
-- Sum plus the tap count (rather than a stored mean) so either can be derived.
-- The stamped rows already in ktp_shot_events span very nearly 0..100 and reach
-- neither below nor above it, which is the range KTPShotGeom.h could only call
-- "believed" -- re-derive from that column rather than trusting this line.
--
-- stam_tap_min is NULLABLE and NULL is the normal state for a window with no
-- taps. Never a sentinel: 0 is a real, reachable stamina reading, so there is
-- no in-range value that can mean "absent".

CREATE TABLE IF NOT EXISTS ktp_move_census (
    id BIGINT UNSIGNED AUTO_INCREMENT,
    server_id INT UNSIGNED NOT NULL,
    match_id VARCHAR(64) DEFAULT NULL,
    half TINYINT NOT NULL DEFAULT 0 COMMENT '0=no match context, 1/2=half, 3+=OT',
    player_id INT NOT NULL,
    map_name VARCHAR(32) NOT NULL,

    window_ms INT UNSIGNED NOT NULL COMMENT 'producer flush interval; the OUTER bound, not the denominator -- a player who died or joined mid-window covers less of it. Sum the ms histograms for observed time. 0 means the producer could not establish the boundary (first flush after load, or a map-change gametime reset), NOT a zero-length window -- a window with nothing in it emits no row.',
    buckets TINYINT UNSIGNED NOT NULL COMMENT 'values in each histogram below',
    bucket_width SMALLINT UNSIGNED NOT NULL COMMENT 'world units/sec per bucket; last bucket is open-ended',

    taps INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'rising IN_DUCK edges this window; equals the sum of taps_ground + taps_air',
    taps_ground VARCHAR(160) NOT NULL DEFAULT '' COMMENT 'duck presses while on the ground, by speed bucket',
    taps_air VARCHAR(160) NOT NULL DEFAULT '' COMMENT 'duck presses while airborne, by speed bucket -- duck-jumps live here',
    ground_ms_standing VARCHAR(160) NOT NULL DEFAULT '' COMMENT 'ms on the ground upright, by speed bucket; step-eligible time',
    ground_ms_ducked VARCHAR(160) NOT NULL DEFAULT '' COMMENT 'ms on the ground crouched, by speed bucket; step-eligible time at the crouched cadence',
    air_ms_ducked VARCHAR(160) NOT NULL DEFAULT '' COMMENT 'ms airborne crouched, by speed bucket; NOT step-eligible',

    stam_tap_sum INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'sum of v.fuser4 over every tap; divide by taps for the mean',
    stam_tap_min SMALLINT DEFAULT NULL COMMENT 'lowest v.fuser4 at any tap. NULL = no tap this window; 0 is a real reading, so there is no sentinel',

    steps_ground INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'surface footsteps the movement code emitted to other players',
    steps_ladder INT UNSIGNED NOT NULL DEFAULT 0,
    sounds_water INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'wade/swim -- not driven by the step timer',
    pmove_sounds INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'every player sound the movement code emitted; the superset',
    step_timer_fires INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'CONTROL: engine step-timer resets, an independent sensor for the same event as steps_ground. Read it before any per-player footstep figure.',

    game_time FLOAT NOT NULL COMMENT 'producer gametime at flush, seconds since map start',
    event_epoch BIGINT UNSIGNED DEFAULT NULL COMMENT 'producer wall-clock',
    producer_sequence BIGINT UNSIGNED DEFAULT NULL,
    event_time DATETIME NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (id),
    -- Same dedup contract as migration 028 and every ktp_* table since: a
    -- duplicate key here can only be a retried resend of the same marker, so
    -- the daemon inserts with INSERT IGNORE. NULL never collides with NULL, so
    -- a marker that arrived without a usable sequence loses only its guard.
    UNIQUE KEY uniq_producer (server_id, match_id, half, producer_sequence),
    KEY idx_server (server_id),
    KEY idx_match (match_id),
    KEY idx_player (player_id),
    KEY idx_event_time (event_time)
    -- No FOREIGN KEY to hlstats_Servers/hlstats_Players: the HLStatsX base
    -- tables are MyISAM, same reason as every other ktp_* table here.
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Crouch-input and footstep-emission census, one row per player per producer window. MEASURE-ONLY: no threshold, no verdict, and steps are not readable without the tap census in the same row.';

-- Expected volume: at most one row per connected player per producer window,
-- and only for a player who moved at all. The window is long relative to
-- ktp_position_samples' interval, so this stream is far lighter than that one --
-- which is why it is not batched. Derive the real rate from the table.

-- ---------------------------------------------------------------------------
-- Verify: the table exists with the geometry columns.
--
--   SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE
--   FROM information_schema.COLUMNS
--   WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'ktp_move_census'
--   ORDER BY ORDINAL_POSITION;
--
-- Verify: the sensor control, BEFORE reading any per-player number.
--
--   SELECT SUM(steps_ground) AS steps, SUM(step_timer_fires) AS timer_fires,
--          SUM(pmove_sounds) AS all_move_sounds, COUNT(*) AS rows_seen
--   FROM ktp_move_census;
--
-- Exploding a histogram in SQL. The lists are fixed-length, so a small numbers
-- table does it; this is spelled out here rather than left to be reinvented.
--
--   WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM n WHERE i < 31)
--   SELECT c.player_id,
--          n.i AS bucket,
--          n.i * c.bucket_width AS speed_lo,
--          SUM(CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(c.taps_ground, ' ', n.i+1),
--                                   ' ', -1) AS UNSIGNED)) AS taps,
--          SUM(CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(c.ground_ms_ducked, ' ', n.i+1),
--                                   ' ', -1) AS UNSIGNED)) AS ducked_ms,
--          SUM(CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(c.ground_ms_standing, ' ', n.i+1),
--                                   ' ', -1) AS UNSIGNED)) AS standing_ms
--   FROM ktp_move_census c
--   JOIN n ON n.i < c.buckets
--   WHERE c.match_id IS NOT NULL
--   GROUP BY c.player_id, n.i, c.bucket_width
--   ORDER BY c.player_id, n.i;
--
-- ⚠️ Any query that reports a footstep rate must carry the tap census and
-- step_timer_fires alongside it. A step count on its own is not interpretable:
-- a player who crouch-walks deliberately emits few footsteps, which is ordinary
-- play. The tap census and step_timer_fires are what separate the cases.
