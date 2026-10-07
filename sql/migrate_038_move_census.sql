-- ENGINE: mysql (hlstatsx on the data server -- NOT the Supabase editor)
-- KTP HLStatsX Migration 038: crouch-input and footstep-emission census.
--
-- STATUS: APPLIED to production 2026-09-26 on operator authorisation, straight
--   from this file rather than through the root migration queue.
--
--   🔻 CORRECTED 2026-10-06. This block read "Nothing after it in the deploy order
--   has run: the daemon and producer that write this table are NOT deployed." THAT
--   WAS TRUE WHEN WRITTEN AND FALSE FOR EIGHT DAYS AFTERWARDS, and two agents
--   nearly implemented against it. The whole chain is deployed: the daemon shipped
--   with KTPHLStatsX #131 (live 2026-09-26 13:06 UTC) and the producer with
--   stats_logging 1.25.0, which activated at the 03:00 ET swap on 2026-09-28.
--   Measured 2026-09-30: 15,207 rows over 09-28..09-29 across 8 of 24 server ids;
--   measured again 2026-10-06: ~104,819 rows across 112 matches. THE TABLE HAS BEEN
--   FILLING SINCE 2026-09-28.
--
--   🔑 Why a stale claim is worse in a migration file than on a board: this file
--   is read as a RECORD of what happened, so its prose is trusted more than a note
--   would be. A deploy-status line belongs to a moment; it is kept here only with
--   the date it stopped being true.
--
--   ⛔ STILL OWED AT THE READING END: until the GRANT at the foot of this file is
--   applied to production, no analytics or API account can SELECT this table --
--   and because information_schema hides what the asking account cannot see, a
--   probe reports the table ABSENT rather than denied, i.e. "the migration never
--   ran". The grant is staged for the operator as
--   migrations-to-apply/3_MYSQL_hlstatsx_move_census_aim_vis_select_grants.sql;
--   the copy below exists so a FRESH install is not born with the same gap.
--
--   The bytes that ran are md5 8561151cdc07d0b555c0eeb265332ab4 (this file at
--   144c3e8, before this header edit); the copy kept as the queue's record is
--   migrations-to-apply/applied/MYSQL_hlstatsx_038_move_census_APPLIED_20260926.sql.
--   The step_timer_fires COMMENT was later corrected live (2026-09-30) and here, so a
--   fresh install matches production. CREATE TABLE IF NOT EXISTS makes that edit a
--   no-op on any database that already has the table.
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
-- PUBLICATION: THE FEATURE SET MAY BE PUBLIC, THE THRESHOLDS MAY NOT
-- ============================================================================
-- Operator ruling, recorded 2026-09-27 -- a decision, not a measurement. The
-- feature set this census records, and the resolution it records it at, may
-- stay in the public repos. The column names ship with the code either way, so
-- the feature set is public by construction; and the only evasion that knowing
-- it enables is a player simply stopping the behaviour, which is the remedy we
-- wanted. Publishing it therefore costs nothing.
--
-- A FEATURE SET IS NOT A THRESHOLD. This licenses the feature set and the
-- resolution, and nothing else: detection thresholds stay private, always.
-- Read no wider licence into it -- the reasoning above turns entirely on there
-- being no cut-point here to leak, so it does not carry to work that has one.
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
-- CORRECTED 2026-09-30: the claim below is false. step_timer_fires co-moves with
-- duck actuation, so it is NOT a control for steps_ground and a per-player
-- footstep figure has no control in this stream (see CHANGELOG). The column
-- COMMENT in the CREATE TABLE below now says so, and this paragraph is kept as
-- the record of what shipped.
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
--
-- ============================================================================
-- 🔻 THE NO-MATCH-CONTEXT STATE IS UNREACHABLE, AND TWO PLACES REFUSE IT
-- ============================================================================
-- match_id is nullable and half's COMMENT offers `0=no match context`. No row has
-- ever carried either, and no row can.
--
-- 🔻 CORRECTED 2026-10-06. This block read "The daemon is fully prepared to store
-- both: doEvent_KTPMove starts at `$match_id_sql = "NULL"` with `$half = 0`", and
-- named the PRODUCER as the only refusal. THAT IS FALSE AND IT IS THE DANGEROUS
-- DIRECTION. The handler's defaults are real, but the handler never runs without a
-- context: dispatch authorises first. In hlstats.pl,
--   ktpCaptureManifestAuthorizes() -> ktpCaptureContextKey(), which returns undef
--   unless matchid matches ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$ AND half is an
--   integer in 1..255.
-- An absent matchid or half 0 therefore has no context key, no accepted manifest,
-- and the marker is rejected by ktpRejectCaptureMarker("move", ...) BEFORE
-- doEvent_KTPMove is called. Those defaults are unreachable code.
--
-- ⛔ WHY THAT MATTERS MORE THAN A WORDING FIX: acting on the old text -- flipping
-- the producer alone to emit untracked windows -- would have emitted a wide row per
-- player per window, through warm-up, on all 24 production instances, into a path
-- that drops 100% of it, AND REPORTED SUCCESS. No symptom, no error, and a task that
-- reads as done. The dispatch gate is where the decision lives, so making this state
-- reachable is an authorisation change in THIS repo, not producer scoping.
--
-- The producer refuses it too, which is belt and braces rather than the reason:
-- ksc_move_flush_task tests `if (!tracked)` FIRST and resets the player's counters
-- without emitting.
--
-- What is wrong is that the column COMMENT reads as a description of data, so the
-- next reader queries `WHERE match_id IS NULL`, gets 0 rows, and concludes the
-- untracked play is quiet rather than absent. It is absent.
--
-- The gate has a real reason, which is why this is a note and not a patch: a
-- window spanning the start of a match must not carry warmup movement into it.
-- The producer has the other option already -- ksc_optional_event_context,
-- used by five other streams -- so making the state reachable is a scoping
-- decision about the boundary, plus a producer version bump and a wave -- AND an
-- authorisation change here, without which the wave is a silent no-op.
--
-- ⛔ UNTIL THAT HAPPENS, READ THIS COMMENT AS A CONTRACT, NOT AS A POPULATION.
-- ➡️ And do not reverse it quietly: if the dispatch gate is ever changed to admit
-- an untracked window, delete this block in the same change. A stale "never occurs"
-- is worse than none, because it argues against believing real rows.
-- ✅ That pairing is now ENFORCED, where before it was only asked for:
-- scripts/selftest-move-census.pl asserts that ktpCaptureContextKey still rejects
-- half < 1 and that this file still names it as the refusal point, so widening the
-- gate fails CI until this block is rewritten with it.
--
-- The other choice, for a stream whose producer gates the same way, is NOT NULL
-- on both columns: it advertises only what the producer contract can reach, and
-- a row that cannot exist then fails at the database instead of reading as an
-- empty population.

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
    step_timer_fires INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'engine step-timer resets. NOT a control for steps_ground: it co-moves with duck actuation, so a ratio against it measures its own denominator rather than the steps',

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

-- ---------------------------------------------------------------------------
-- THE READING END. This table was unreadable for eight days after it started
-- filling, and the symptom was not "denied" anywhere: information_schema hides a
-- table the asking account cannot see, so a probe reports it ABSENT and the reader
-- concludes the migration never ran. Three tables have now been lost this way
-- (ktp_hitreg_quality 09-22, ktp_move_census and ktp_aim_vis 10-05).
--
-- ⛔ DELIBERATELY NOT EXECUTED HERE, and that is the decision, not an omission.
-- These accounts are environment-specific, and MySQL refuses a GRANT to an account
-- that does not exist (ERROR 1410) -- so an executable grant would make this schema
-- file fail to apply on any database that lacks them, including a parity container.
-- A schema file that cannot run on a fresh database is worse than a documented step.
--
-- ➡️ AFTER THE TABLE EXISTS, GRANT SELECT ON THIS TABLE to each read account that is
--    expected to query it -- per-table and SELECT only, never `ON hlstatsx.*`. A
--    wildcard would also hand those accounts every FUTURE table in this schema,
--    including the ones deliberately withheld, which is the opposite of what a grant
--    should mean. SELECT is enough: this stream is measure-only and its readers are
--    read-only. ⛔ The account names are deliberately NOT written here -- this repo is
--    public and they are not in it. They live with the staged statement below.
--
--    No FLUSH PRIVILEGES: GRANT updates the in-memory grant structures directly.
--    Verify BY USE, connecting AS the account -- not with `sudo -u`, which
--    authenticates as root via getlogin() and passes on a grant that is not there.
--
-- 📌 For PRODUCTION this file is not the vehicle: 038 is already applied there and
--    nobody re-runs an applied file. The statement, with its grantees and the before/
--    after checks, is staged for the operator in the root migration queue as
--    3_MYSQL_hlstatsx_move_census_aim_vis_select_grants.sql.

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
-- CORRECTED 2026-09-30: step_timer_fires does not separate the cases below. See
-- the correction above the footstep-columns paragraph.
-- ⚠️ Any query that reports a footstep rate must carry the tap census and
-- step_timer_fires alongside it. A step count on its own is not interpretable:
-- a player who crouch-walks deliberately emits few footsteps, which is ordinary
-- play. The tap census and step_timer_fires are what separate the cases.
