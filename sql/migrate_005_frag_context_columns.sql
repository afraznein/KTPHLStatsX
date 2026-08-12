-- KTP HLStatsX Migration 005: frag-context columns on hlstats_Events_Frags
-- Run on data server: mysql -u hlstatsx -p hlstatsx < migrate_005_frag_context_columns.sql
--
-- Pairs with KTPAMXX's ktp_stats_capture.inc, which emits, on every kill:
--     "Killer<uid><steamid><Team>" triggered "frag_context" against
--     "Victim<uid><steamid><Team>" with "weapon"
--     (headshot "0") (k_prone "0") (v_prone "0") (k_scope "0") (v_scope "0")
--     (k_clip "8") (k_ammo "72") (v_clip "-1") (v_ammo "-1")
--
-- This line RETIRES the old "headshot_kill" marker (headshot-only). The
-- daemon's frag_context handler (hlstats.pl) uses the identical technique
-- that marker used -- flush the frag queue, then UPDATE the most recent
-- matching row -- so `headshot` needs no new column (it already exists from
-- the old marker); everything else here is new.
--
-- Idempotent on both MySQL and MariaDB: each column is guarded by an
-- information_schema lookup and applied through a prepared statement, same
-- shape as ktp_schema.sql. See that file's header for why a bare
-- `ADD COLUMN IF NOT EXISTS` is not portable.
--
-- Column meaning:
--   k_prone / v_prone   -- dod_get_pronestate raw value: 0 standing,
--                           1 going prone / MG teardown, 2 setting up an MG
--                           while down. Not a bool -- the raw value is kept.
--   k_scope / v_scope    -- 0/1, tracked live from the dod_client_scope
--                           forward (DODX has no getter).
--   k_clip / k_ammo       -- killer's current weapon clip/ammo at the moment
--   v_clip / v_ammo          of the kill. -1 is a sentinel for "not
--                            applicable" (melee, grenades) or "read failed",
--                            never a fabricated empty magazine.
--
-- The database MUST be named on the command line -- see ktp_schema.sql's
-- header for why (DATABASE() is NULL otherwise and every guard chooses to
-- apply, so the first ALTER aborts the batch at ERROR 1046).

-- hlstats_Events_Frags.k_prone
SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_Frags'
                   AND COLUMN_NAME = 'k_prone');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE hlstats_Events_Frags ADD COLUMN k_prone TINYINT NOT NULL DEFAULT 0');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- hlstats_Events_Frags.v_prone
SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_Frags'
                   AND COLUMN_NAME = 'v_prone');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE hlstats_Events_Frags ADD COLUMN v_prone TINYINT NOT NULL DEFAULT 0');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- hlstats_Events_Frags.k_scope
SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_Frags'
                   AND COLUMN_NAME = 'k_scope');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE hlstats_Events_Frags ADD COLUMN k_scope TINYINT NOT NULL DEFAULT 0');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- hlstats_Events_Frags.v_scope
SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_Frags'
                   AND COLUMN_NAME = 'v_scope');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE hlstats_Events_Frags ADD COLUMN v_scope TINYINT NOT NULL DEFAULT 0');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- hlstats_Events_Frags.k_clip
SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_Frags'
                   AND COLUMN_NAME = 'k_clip');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE hlstats_Events_Frags ADD COLUMN k_clip SMALLINT NOT NULL DEFAULT -1');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- hlstats_Events_Frags.k_ammo
SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_Frags'
                   AND COLUMN_NAME = 'k_ammo');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE hlstats_Events_Frags ADD COLUMN k_ammo SMALLINT NOT NULL DEFAULT -1');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- hlstats_Events_Frags.v_clip
SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_Frags'
                   AND COLUMN_NAME = 'v_clip');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE hlstats_Events_Frags ADD COLUMN v_clip SMALLINT NOT NULL DEFAULT -1');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- hlstats_Events_Frags.v_ammo
SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_Frags'
                   AND COLUMN_NAME = 'v_ammo');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE hlstats_Events_Frags ADD COLUMN v_ammo SMALLINT NOT NULL DEFAULT -1');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Verify: expects 8 rows.
--
--   SELECT COLUMN_NAME FROM information_schema.COLUMNS
--   WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'hlstats_Events_Frags'
--     AND COLUMN_NAME IN ('k_prone','v_prone','k_scope','v_scope',
--                          'k_clip','k_ammo','v_clip','v_ammo');
--
-- Then, after a match containing a kill:
--
--   SELECT killerId, victimId, weapon, headshot, k_prone, v_prone,
--          k_scope, v_scope, k_clip, k_ammo, v_clip, v_ammo
--   FROM hlstats_Events_Frags ORDER BY id DESC LIMIT 5;
--
-- All-default rows (0/0/0/0/-1/-1/-1/-1) after a match with real kills means
-- the plugin side is not emitting frag_context or the daemon isn't matching
-- it. Check `ktp_stats_capture` is 1 on the game server, then look for the
-- raw "frag_context" line in the server log -- if the line is present and
-- the row is not updated, the problem is the daemon match (killerId /
-- victimId / weapon mismatch); if the line is absent, the problem is
-- plugin-side emission.
