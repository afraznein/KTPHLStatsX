-- KTP HLStatsX Migration 006: per-hit damage ledger
-- Run on data server: mysql -u hlstatsx -p hlstatsx < migrate_006_damage_ledger.sql
--
-- Pairs with KTPAMXX's ktp_stats_capture.inc, which emits, on every hit
-- (enemy, team, and self alike):
--     "Attacker<uid><steamid><Team>" triggered "damage" against
--     "Victim<uid><steamid><Team>" with "weapon"
--     (damage "137") (damage_capped "100") (hitplace "1")
--     (matchid "KTP-42") (half "2")
--     (game_time "245.32") (event_epoch "1787154601")
--
-- New event type 605 in hlstats.pl (following the KTP_MATCH_* 600-604 /
-- headshot_kill 900 / frag_context 901 numbering), with its own
-- doEvent_KTPDamage handler and INSERT -- NOT routed through the daemon's
-- generic recordEvent/hlstats_Events_* batching, which is config-driven
-- around the stock event tables and not a natural fit for a wholly new
-- table. Direct per-event INSERT, same as the KTP_MATCH_* markers.
--
-- `CREATE TABLE IF NOT EXISTS` is standard SQL on both MySQL and MariaDB --
-- unlike `ADD COLUMN`/`CREATE INDEX IF NOT EXISTS`, which are MariaDB-only
-- (see ktp_schema.sql's header) -- so this table needs no information_schema
-- guard the way migrate_005's column additions did.
--
-- ⚠️ damage_capped, not damage, is the KTPR-facing column. DoD's raw per-hit
-- damage is the nominal weapon value with multipliers applied (headshot,
-- wallbang) and is NOT clamped to a player's actual 0-100 HP pool -- a
-- single hit can log 400+. That number says "how strong this weapon+hitzone
-- combo is on paper," not "how much this hit mattered." damage_capped is
-- MIN(damage, 100), computed plugin-side (KSC_DAMAGE_CAP), matching the
-- convention CS2 uses for the same reason. Raw damage is kept for anyone who
-- genuinely wants the uncapped weapon-power reading -- nothing is discarded
-- — but any per-player rating or aggregate stat should sum damage_capped.
--
-- game_time is DoD/AMXX's get_gametime() (seconds since map start), standing
-- in for "tick" from the original phase spec: AMXX exposes no raw network
-- tick counter to Pawn. Ordering/correlation purpose is the same -- which
-- hits happened near each other in time -- documented as a substitution
-- rather than claimed as something it isn't.

CREATE TABLE IF NOT EXISTS ktp_damage_events (
    id INT AUTO_INCREMENT,
    server_id INT UNSIGNED NOT NULL,
    match_id VARCHAR(64) DEFAULT NULL,
    half TINYINT NOT NULL DEFAULT 0 COMMENT '0=no match context, 1/2=half, 3+=OT',
    attacker_id INT NOT NULL,
    victim_id INT NOT NULL,
    weapon VARCHAR(32) NOT NULL,
    damage SMALLINT NOT NULL COMMENT 'raw engine value, not clamped to HP',
    damage_capped TINYINT UNSIGNED NOT NULL COMMENT 'MIN(damage, 100) -- read this one for stats',
    hitplace TINYINT NOT NULL,
    producer_match_id VARCHAR(64) DEFAULT NULL COMMENT 'producer context; use this for timed analytics',
    producer_half TINYINT UNSIGNED DEFAULT NULL COMMENT 'producer half; use this for timed analytics',
    game_time FLOAT NOT NULL COMMENT 'get_gametime() at the hit, seconds since map start',
    event_epoch BIGINT UNSIGNED DEFAULT NULL COMMENT 'producer get_systime() at hit',
    event_time DATETIME NOT NULL COMMENT 'FROM_UNIXTIME(event_epoch); legacy emitters fall back to receipt time',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (id),
    KEY idx_server (server_id),
    KEY idx_match (match_id),
    KEY idx_attacker (attacker_id),
    KEY idx_victim (victim_id),
    KEY idx_event_time (event_time),
    KEY idx_damage_producer_context (producer_match_id, producer_half, event_epoch)
    -- No FOREIGN KEY to hlstats_Servers or hlstats_Players: the HLStatsX base
    -- tables are MyISAM, which has no FK support, so an InnoDB FK referencing
    -- them fails with errno 1824 -- same reason ktp_matches has none.
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Per-hit damage ledger -- every client_damage hit, capped and raw';

-- Verify: table exists with the expected columns.
--
--   SELECT COLUMN_NAME, DATA_TYPE FROM information_schema.COLUMNS
--   WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'ktp_damage_events'
--   ORDER BY ORDINAL_POSITION;
--
-- Then, after a match with real hits:
--
--   SELECT attacker_id, victim_id, weapon, damage, damage_capped, hitplace,
--          match_id, half
--   FROM ktp_damage_events ORDER BY id DESC LIMIT 10;
--
--   -- Sanity: damage_capped must never exceed 100, and must never exceed
--   -- damage itself.
--   SELECT COUNT(*) FROM ktp_damage_events
--   WHERE damage_capped > 100 OR damage_capped > damage;
--
-- Zero rows after a match with real combat means the plugin side is not
-- emitting or the daemon isn't matching it. Check `ktp_stats_capture` is 1
-- on the game server, then look for the raw "damage" line in the server
-- log -- if the line is present and the row is not, the problem is this
-- migration or the daemon handler; if the line is absent, the problem is
-- plugin-side emission. The last query returning non-zero is a real defect
-- in the cap logic, not a coverage gap -- it should never happen.
