-- ENGINE: mysql (hlstatsx on the data server -- NOT the Supabase editor)
-- KTP HLStatsX Migration 042: aim-vs-transmission census (tier 2.7).
--
-- STATUS: NOT APPLIED. Nothing writes this table yet, by design.
--
-- DEPLOY ORDER: this migration, then the daemon, then the producer.
--   Schema ahead of code is harmless; code ahead of schema is data loss.
--
--   The producer takes NO new schema ordinal -- it announces an `aim_vis`
--   capability at the existing one, the same way `move` does. An unknown SCHEMA
--   gets a producer's whole manifest refused, taking every other capture stream
--   down with it for that half, while an unknown CAPABILITY loses only the
--   stream the receiver cannot read. So a producer that runs ahead of its daemon
--   costs this stream and nothing else.
--
-- WHY THIS FILE EXISTS BEFORE ANY PRODUCER DOES. The module half of this sensor
-- has been live on the whole fleet for weeks with no reader and no destination:
-- it records per-send pack visibility on every instance and throws the output
-- away. The destination is the harder half and it goes first, because the
-- opposite ordering has already been paid for once on this stream's siblings.
--
-- Pairs with KTPAMXX's dodx natives dodx_get_aim_vis_stats /
-- dodx_reset_aim_vis_stats (modules/dod/dodx/NBase.cpp, declared in
-- plugins/include/dodx.inc). The producer, once written, emits once per flush
-- interval per player who aimed at a live enemy at all:
--     "Player<uid><steamid><Team>" triggered "aim_vis"
--     (interval_ms "30000") (samples_known "412") (samples_unpacked "3")
--     (samples_unknown "11") (window_ms_sum "61800") (window_ms_max "187")
--     (recorder_live "1")
--     (map "dod_anzio") (matchid "...") (half "1") (game_time "245.32")
--     (event_epoch "...") (sequence "...")
--
-- ============================================================================
-- WHAT THIS IS FOR, AND WHAT IT DELIBERATELY IS NOT
-- ============================================================================
-- Each sample is taken when the game's own aim trace lands on a live enemy, and
-- asks one question: was that enemy present in ANY entity pack the server sent
-- this player inside a window covering client interpolation plus that player's
-- measured ping -- how far in the past their screen legitimately runs.
--
-- THIS TABLE CARRIES NO THRESHOLD, NO RATIO AND SUPPORTS NO VERDICT. There is
-- no cut point here, in the daemon, or in the module. A constant chosen now
-- would be a guess wearing the authority of a measurement, and any consumer
-- that applies one is private, not this.
--
-- ⚠️ ONLY ONE DIRECTION IS SOUND, AND IT IS THE ABSENCE.
--   not packed in the window -> the client was never sent that entity, so no
--     renderer, stock or otherwise, had anything to draw. That is the whole
--     instrument.
--   packed -> NOTHING. PVS is leaf-based and generous; entities stay packed
--     while standing behind a wall.
-- A query that reads "packed" as "legitimately seen" has stopped measuring
-- behaviour and started measuring level geometry. That is why there is no
-- samples_packed column: the only way to get one is
-- samples_known - samples_unpacked - and writing that subtraction out is a
-- deliberate speed bump in front of the wrong reading.
--
-- ⚠️ THREE STATES, NOT TWO. samples_known is the denominator: samples that got
-- an answer either way. samples_unpacked is the SUBSET of it that answered
-- "never sent". samples_unknown got no answer at all -- recording had not yet
-- covered a full window for both slots, the recorder was inactive, or a clock
-- boundary intervened. Unknown counts toward NEITHER side. Folding it into
-- either one fabricates a rate.
--
-- ⚠️ THE DENOMINATOR IS AS LOAD-BEARING AS THE NUMERATOR, which is why both
-- live in the same row and always travel together. This stream is a RATE, never
-- an event: a player can sweep a crosshair through a wall across a spot an enemy
-- happens to occupy, and over a session that is noise. A query that reports
-- samples_unpacked without samples_known beside it is not interpretable, and a
-- retention policy that keeps the numerator rows and drops the rest makes every
-- rate computed afterwards wrong.
--
-- ⚠️ recorder_live 0 MEANS THE INSTRUMENT WAS OFF FOR THAT INTERVAL. Every
-- sample then lands in samples_unknown and the row says nothing about the
-- player. It is stored per row rather than assumed, because the hook registers
-- only where the engine exposes the packet hookchain.
--
-- ⚠️ THE ABSENCE OF A ROW IS NOT A CLEAN READING. A row is emitted only for a
-- player with at least one sample in the interval; a player who never put a
-- crosshair on a live enemy produces none. "No row" means "no aim-on-enemy
-- samples", which is indistinguishable from an unplayed interval and from a
-- producer that never shipped. Never read it as "nothing was found".
--
-- ⚠️ window_ms_sum / window_ms_max DESCRIBE THE LOOKBACK USED PER SAMPLE, not
-- the flush interval. interval_ms is the flush interval. The two are different
-- quantities in the same row and the names are the only thing separating them:
-- the lookback is tens to hundreds of milliseconds derived from a player's own
-- ping, and the interval is tens of seconds. A pre-existing sibling column
-- called window_ms on ktp_move_census IS the flush interval, so the collision
-- is live across tables -- read the COMMENTs, not the name.
--
-- ============================================================================
-- WHY THIS STREAM IS TRACKED-ONLY, STATED HERE SO NOTHING ADVERTISES OTHERWISE
-- ============================================================================
-- match_id and half are NOT NULL and there is no no-match-context sentinel.
-- ktp_move_census took the other choice: its match_id is nullable and its half
-- COMMENT documents a 0 that means "no match context" -- and its producer gates
-- on tracked context and therefore cannot emit either one. The schema there
-- advertises a state that has never occurred, and the next reader believes the
-- data exists. Do not repeat it: if untracked aim samples are ever wanted, the
-- producer change and the column change land together, in that order.

CREATE TABLE IF NOT EXISTS ktp_aim_vis (
    id BIGINT UNSIGNED AUTO_INCREMENT,
    server_id INT UNSIGNED NOT NULL,
    match_id VARCHAR(64) NOT NULL COMMENT 'tracked halves only -- see the header. There is no no-match-context sentinel because the producer cannot emit one',
    half TINYINT NOT NULL COMMENT '1/2=half, 3+=OT. No 0: a row with no match context is not emitted',
    player_id INT NOT NULL,
    map_name VARCHAR(32) NOT NULL,

    interval_ms INT UNSIGNED NOT NULL COMMENT 'producer flush interval -- the OUTER bound of the row, NOT a denominator -- a player who died or joined mid-interval covers less of it. The denominator is samples_known. 0 means the producer could not establish the boundary (first flush after load, or a map-change gametime reset), NOT a zero-length interval -- an interval with nothing in it emits no row',

    samples_known INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'THE DENOMINATOR: aim-on-live-enemy samples that got an answer either way. Any rate over this stream divides by this column and by nothing else',
    samples_unpacked INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'the SUBSET of samples_known whose enemy was in no pack sent to this client inside the window: the server had transmitted nothing for any renderer to draw. The sound direction, and the only one',
    samples_unknown INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'samples with NO answer: recording had not covered a full window for both slots, the recorder was inactive, or a clock boundary intervened. Counts toward NEITHER side -- it is not in samples_known and it is not evidence of anything',

    window_ms_sum BIGINT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'sum of the per-sample LOOKBACK window across samples_known samples, saturating. Not the flush interval -- that is interval_ms. Divide by samples_known for the mean lookback actually used',
    window_ms_max INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'widest single per-sample lookback window this interval. The lookback is derived from the player measured ping, so this moves with their connection, not with their play',
    recorder_live TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '1 while the pack recorder hook was registered. 0 means the instrument was OFF: every sample landed in samples_unknown and the row says nothing about the player',

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
    -- player_id is deliberately absent: the producer allocates a fresh sequence
    -- per emitted row, so the sequence already separates two players in one
    -- interval, and adding the player would weaken the guard against a resend
    -- that arrived after a reconnect changed the resolved id.
    UNIQUE KEY uniq_producer (server_id, match_id, half, producer_sequence),
    KEY idx_server (server_id),
    KEY idx_match (match_id),
    KEY idx_player (player_id),
    KEY idx_event_time (event_time)
    -- No FOREIGN KEY to hlstats_Servers/hlstats_Players: the HLStatsX base
    -- tables are MyISAM, same reason as every other ktp_* table here.
    --
    -- No CHECK (samples_unpacked <= samples_known) either, deliberately. The
    -- constraint is real and the daemon enforces it on the way in, where a
    -- violation can be attributed to the producer that sent it and named in a
    -- log line. Enforced here instead it would surface as an insert failure on
    -- a live stream, on a server whose MySQL version is not pinned anywhere in
    -- this repo -- and a CHECK that silently parses and does nothing is worse
    -- than no CHECK, because it reads like a guarantee.
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Aim-vs-transmission census (tier 2.7), one row per player per producer interval. MEASURE-ONLY: no threshold, no ratio, no verdict. Only the ABSENCE direction is sound, and samples_unpacked is uninterpretable without samples_known in the same row.';

-- Expected volume: at most one row per connected player per producer interval,
-- and only for a player who aimed at a live enemy at all. Bounded above by
-- ktp_move_census, which charges standing-still time and so emits for every
-- alive player every interval, where this one does not.

-- ============================================================================
-- VERIFY (run after applying; each must return what its comment says)
-- ============================================================================
-- The table exists with the expected column set:
--   SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE
--   FROM information_schema.COLUMNS
--   WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'ktp_aim_vis'
--   ORDER BY ORDINAL_POSITION;
--   -- expect 18 rows; match_id and half both NO
--
-- Control for that query, so an empty result cannot be read as a clean pass:
--   SELECT COUNT(*) FROM information_schema.COLUMNS
--   WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'ktp_move_census';
--   -- expect non-zero; a 0 here means the query is blind, not that nothing applied
--
-- There is deliberately no samples_packed column. This must return 0:
--   SELECT COUNT(*) FROM information_schema.COLUMNS
--   WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'ktp_aim_vis'
--     AND COLUMN_NAME = 'samples_packed';
--
-- Row count immediately after applying, and until the producer ships:
--   SELECT COUNT(*) FROM ktp_aim_vis;   -- expect 0
