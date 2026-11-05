-- ENGINE: mysql (hlstatsx on the data server -- NOT the Supabase editor)
-- KTP HLStatsX Migration 054: the two producer-observed causal parent links of a
-- death group -- which half of it caused the other.
--
-- STATUS: proposed, not applied. The production copy is staged separately for the
--   operator (see PROVENANCE); nobody re-runs an applied migration against
--   production, so this file exists for a FRESH install and for Lane B.
--
-- Apply once as: sudo mysql hlstatsx < migrate_054_causal_parent_links.sql
-- Idempotent: every statement is guarded on information_schema, so a second run is
--   a handful of catalog lookups and four `DO 0`s -- and in particular does NOT
--   repeat the MyISAM rebuild below.
--
-- ⚠️ 054, NOT 053. 052 is the highest migration in this repo and `migrate_053`
--   resolves 0 times across every remote ref (re-derived at write time, 2026-11-05,
--   against a 51-file `sql/migrate_*` haystack and a positive control of 1 on
--   `migrate_052`). 053 is nevertheless SPOKEN FOR: a concurrent lane staged a file
--   titling itself "KTP HLStatsX Migration 053" into the operator queue the same
--   day. Taking it would have put two different things under one ordinal, so this
--   file leaves the gap. The gap costs nothing -- Lane B's apply order is a list,
--   not an arithmetic sequence.
--
-- DEPLOY ORDER: this migration, then the daemon, then the producer.
--   A fielded producer whose daemon writes a column that does not exist loses the
--   marker outright, with a row count of nothing to show for it. Schema ahead of
--   code is inert; code ahead of schema is data loss. Neither the daemon reader nor
--   the producer exists yet -- measured 2026-11-05, `causal_parent` resolves 0 times
--   in BOTH this repo and KTPAMXX at origin/main (positive control `capture_health`
--   at 10 and 2 files; nonsense-token control 0 in both).
--
--   No KSC_SCHEMA_CONTRACT bump and NO new KSC_EVENT_* type. The links ride the
--   existing frag_context and assist streams as two extra wire properties, and an
--   old daemon ignores an unknown property. ✅ That is also why KTPInfrastructure's
--   capture-health type registry needs NO change here -- unlike `move` (2026-09-29)
--   and `shot_miss`, each of which failed capture_health for a WHOLE half, for every
--   stream, because ksc_emit_health loops the producer's entire event enum.
--
-- 🔴 BLOCKED, AND THE BLOCK IS IN ANOTHER REPO: Lane B refuses a daemon ref that
--   carries a migration it has no apply position for.
--   `KTPInfrastructure tests/e2e_stats/artifacts.py` -> `plan_schema_files` raises
--   `BuildError("daemon ref carries sql/migrate_054_causal_parent_links.sql, which
--   Lane B has no apply position for: add it to DEFAULT_SCHEMA_FILES, or to
--   NOT_APPLIED_MIGRATIONS with the reason it is not applied")`. The highest entry
--   in `DEFAULT_SCHEMA_FILES` on that repo's origin/main is `migrate_052`.
--   ➡️ So the harness registration lands FIRST. That is the standing order for this
--   workstream -- harness, then daemon, then plugin -- and it is why the
--   `corpus-regression / Lane B` check on the PR carrying this file is red until the
--   registration merges. ⛔ A red Lane B here is NOT a defect in this file.
--
-- ⚠️ ONE OF THE THREE ALTERS REBUILDS A 413 MB MyISAM TABLE UNDER A WRITE LOCK, SO
--   APPLY IN AN IDLE WINDOW. Measured on production 2026-11-05:
--   `hlstats_Events_Frags` is MyISAM, 2,027,725 rows, 281 MB data + 132 MB index;
--   MyISAM has no in-place ADD COLUMN, so the ALTER copies the whole table and every
--   live frag write queues behind it. Exactly ONE column goes on that table,
--   deliberately, to keep the rebuild to a single pass -- see the no-index note at
--   statement 1. The other two ALTERs are InnoDB metadata on a 76,732-row table.
--
-- SAFE TO APPLY WHILE THE DAEMON IS RUNNING, AND NOTHING NEEDS RESTARTING FOR THIS
--   FILE ALONE. All three write paths name their columns, so a new column is simply
--   absent from them and takes its DEFAULT NULL: the stock frag INSERT is built
--   column-by-column in `buildEventInsertData` (hlstats.pl:333-351), the
--   frag_context write is a named-column `UPDATE hlstats_Events_Frags SET ...`
--   (hlstats.pl:3310), and the assist write is `INSERT IGNORE INTO ktp_assist_events
--   (<16 named columns>)` (hlstats.pl:7037). A POSITIONAL insert anywhere would have
--   broken on an ADD COLUMN; there is none. The SIGHUP belongs with the daemon
--   change, not with this file.
--
-- NO md5/content-hash guard is needed: this file contains no UPDATE and no DELETE.
--
-- PROVENANCE: `KTPInfrastructure docs/TELEMETRY_CAUSAL_LINKS_V1.md` (56 lines).
--   RULED 2026-11-02 (operator): BUILD IT, against a recommendation to withdraw the
--   spec as deferred -- the subject is which half of a death group caused the other,
--   and its sibling `docs/TELEMETRY_COLLECTION_CONTRACT_V1.md` already shipped
--   naming these links as the one thing it does not cover ("Explicit causal
--   parent/child links ... are not present in v1"). The production copy is staged in
--   the operator queue as `3_MYSQL_hlstatsx_054_causal_parent_links.sql`; the two
--   files carry the same four statements.
--
-- ===========================================================================
-- WHAT THIS MODELS
-- ===========================================================================
--
-- At one DODX death hook (`ksc_on_death`, KTPAMXX plugins/dod/ktp_stats_capture.inc)
-- the producer observes, IN THIS ORDER and before the victim's damage matrix is
-- cleared:
--
--   1. ksc_life_end(victim, "death")   -> mints a KSC_EVENT_LIFE sequence
--   2. ksc_emit_frag_context(...)      -> mints a KSC_EVENT_FRAG sequence, and only
--                                         when !effectiveTeamkill
--   3. the assist loop                 -> mints a KSC_EVENT_ASSIST sequence each
--
-- Because 1 precedes 2 and 2 precedes 3, the life-end key is available to the frag
-- and to every assist, and the frag key is available to every assist. That ordering
-- is what makes these links PRODUCER-OBSERVED rather than reconstructed, which is
-- the whole point of the spec: a consumer must never manufacture one of these
-- relationships by nearest timestamp, common player pair, or a time window.
--
-- ⚠️ TRAP 1 -- `producer_sequence` IS PER-EVENT-TYPE, NOT PRODUCER-GLOBAL, SO A BARE
--    SEQUENCE NUMBER IS AMBIGUOUS AND A SINGLE GENERIC LINK COLUMN WOULD MAKE EVERY
--    LINK UNRESOLVABLE. The spec says the private link key is
--    "(match_id, half, producer_sequence)" and the shipped collection contract says
--    "every captured marker has a producer-global monotonic sequence". Both are
--    stale. KTPAMXX mints every sequence with `ksc_next_type_sequence(KSC_EVENT_<T>)`
--    against `g_kscTypeSequence[KSC_EVENT_COUNT]` -- one counter per type, reset each
--    half. It resolves 21 times in ktp_stats_capture.inc on origin/main, once per
--    stream, and `migrate_028_shot_events_dedup.sql` records the change
--    (fix/shot-sequence-per-type-space) and RELIES on it for its dedup key.
--    So a life-end marker and a frag marker in the same match/half routinely carry
--    the SAME integer while being unrelated events. The real key is
--    (server_id, match_id, half, EVENT_TYPE, producer_sequence) -- note the spec also
--    omits server_id, where every unique key in this schema leads with it.
--    ➡️ That is why these columns name their referent's TYPE. The type is not
--    recoverable from the value. ⛔ Do not collapse them into one
--    `causal_parent_sequence` later; it reads tidier and it is unresolvable.
--
-- ⚠️ TRAP 2 -- A LINK COLUMN HOLDS NULL FOR "NO PARENT", NEVER 0, BECAUSE 0 ALREADY
--    MEANS "UNTRACKED" ON THESE STREAMS. The producer emits
--    `tracked ? ksc_next_type_sequence(KSC_EVENT_FRAG) : 0` for the frag, assist,
--    damage and break streams, and the daemon currently hardens that into a stored 0
--    on BOTH paths this file touches: `int($producer_sequence // 0)` in the assist
--    insert (hlstats.pl:7047) and
--    `", producer_sequence = ".int($ev_properties_hash{"sequence"} // 0)` in the frag
--    clock SQL (hlstats.pl:3211).
--    ➡️ The daemon reader must NOT copy `// 0` onto these columns. ✅ The sentinel
--    has never actually fired in production -- measured 2026-11-05,
--    `producer_sequence = 0` is 0 of 76,732 rows in ktp_assist_events and 0 of 11,455
--    producer-stamped frag rows over two days -- which is exactly why an 0-vs-NULL
--    mistake here would stay invisible for months and then read as a real link.
--
-- WIRE PROPERTY NAMES, fixed here so the three repos agree:
--     (causal_parent_life "<n>")   on frag_context and on assist
--     (causal_parent_frag "<n>")   on assist only
--
-- The spec's explicit non-links are honoured by what is ABSENT:
--   * ktp_damage_events gets NOTHING. "A damage hit is not automatically linked to a
--     later frag." It is a fact about that hit; a later kill does not prove it was
--     causal.
--   * hlstats_Events_PlayerActions gets NOTHING. The generic assist action row
--     "remains compatible evidence but is not a canonical parent relation", and
--     sparing it avoids a second 87 MB MyISAM rebuild.
--   * A teamkill, world death, suicide, disconnect, missing life marker or dropped
--     frag marker leaves the matching column NULL. There is no sentinel for
--     "no parent" and no NOT NULL below.
--
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. hlstats_Events_Frags: the victim's life-end parent.
--    ⚠️ MyISAM, 2,027,725 rows -- this single ALTER is the whole cost of the file.
--    No index is added here, deliberately: a second ALTER is a second full rebuild,
--    and the query that matters ("given this life-end, find its frag") is already
--    narrowed to one match-half by idx_frag_producer_context
--    (producer_match_id, producer_half, event_epoch). Revisit only with a measured
--    plan, and in an idle window.
-- ---------------------------------------------------------------------------
SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'hlstats_Events_Frags'
                   AND COLUMN_NAME = 'causal_parent_life_sequence');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE hlstats_Events_Frags ADD COLUMN causal_parent_life_sequence BIGINT UNSIGNED DEFAULT NULL COMMENT ''KSC_EVENT_LIFE producer_sequence of the victim life-end observed in the same death hook; NULL = no parent, never 0''');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- ---------------------------------------------------------------------------
-- 2. ktp_assist_events: the same life-end parent.
--    InnoDB, 76,732 rows. Placed after producer_sequence to sit beside the key it
--    shares a sequence space with.
-- ---------------------------------------------------------------------------
SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'ktp_assist_events'
                   AND COLUMN_NAME = 'causal_parent_life_sequence');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE ktp_assist_events ADD COLUMN causal_parent_life_sequence BIGINT UNSIGNED DEFAULT NULL COMMENT ''KSC_EVENT_LIFE producer_sequence of the victim life-end observed in the same death hook; NULL = no parent, never 0'' AFTER producer_sequence');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- ---------------------------------------------------------------------------
-- 3. ktp_assist_events: the emitted frag parent.
--    Nullable for the honest no-parent cases the spec enumerates -- a teamkill
--    (ksc_emit_frag_context is skipped entirely when effectiveTeamkill), a world
--    death, a suicide, and a frag marker that was built but dropped by
--    ksc_buffer_event. An assist keeps its life-end key in every one of those.
-- ---------------------------------------------------------------------------
SET @exists := (SELECT COUNT(*) FROM information_schema.COLUMNS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'ktp_assist_events'
                   AND COLUMN_NAME = 'causal_parent_frag_sequence');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE ktp_assist_events ADD COLUMN causal_parent_frag_sequence BIGINT UNSIGNED DEFAULT NULL COMMENT ''KSC_EVENT_FRAG producer_sequence of the frag queued by the same death hook; NULL = none queued (teamkill/world/suicide/dropped marker), never 0'' AFTER causal_parent_life_sequence');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- ---------------------------------------------------------------------------
-- 4. ktp_assist_events: index for the direction analytics resolves in.
--    Cheap here (InnoDB, 76,732 rows, one online pass) and not cheap on Frags,
--    which is why only this side gets one. Deliberately NOT UNIQUE: several assists
--    legitimately share one life-end parent -- that set IS the death group.
--    match_id/half lead it because a link is valid only inside one validated
--    producer context, and because per-type sequences restart every half.
-- ---------------------------------------------------------------------------
SET @exists := (SELECT COUNT(*) FROM information_schema.STATISTICS
                 WHERE TABLE_SCHEMA = DATABASE()
                   AND TABLE_NAME = 'ktp_assist_events'
                   AND INDEX_NAME = 'idx_assist_causal_life');
SET @ddl := IF(@exists > 0, 'DO 0',
    'ALTER TABLE ktp_assist_events ADD INDEX idx_assist_causal_life (match_id, half, causal_parent_life_sequence)');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Verification -- ONE result set, 5 rows. Rows 1-4 must read PASS. Row 5 is the
-- NEGATIVE CONTROL and must read PASS with a count of 0: it asks for a column this
-- file deliberately does NOT create, on a table it deliberately does not touch, so
-- a FAIL there means the query matches more than it means and rows 1-4 prove
-- nothing.
--
-- ⚠️ This reads information_schema, which answers whether the COLUMN EXISTS -- the
-- only question this migration can answer. The columns are 100% NULL until the
-- producer is fielded, and that is the expected result, not a failed apply.
-- ⛔ Do not add a row counting non-NULL values and read its 0 as a failure.
--
--   SET SESSION max_execution_time=10000;
--   SELECT 1 AS n, 'frag life-parent column' AS checks,
--          IF(COUNT(*) = 1, 'PASS', CONCAT('FAIL(', COUNT(*), ')')) AS result
--     FROM information_schema.COLUMNS
--    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'hlstats_Events_Frags'
--      AND COLUMN_NAME = 'causal_parent_life_sequence'
--      AND DATA_TYPE = 'bigint' AND IS_NULLABLE = 'YES'
--   UNION ALL
--   SELECT 2, 'assist life-parent column',
--          IF(COUNT(*) = 1, 'PASS', CONCAT('FAIL(', COUNT(*), ')'))
--     FROM information_schema.COLUMNS
--    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'ktp_assist_events'
--      AND COLUMN_NAME = 'causal_parent_life_sequence'
--      AND DATA_TYPE = 'bigint' AND IS_NULLABLE = 'YES'
--   UNION ALL
--   SELECT 3, 'assist frag-parent column',
--          IF(COUNT(*) = 1, 'PASS', CONCAT('FAIL(', COUNT(*), ')'))
--     FROM information_schema.COLUMNS
--    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'ktp_assist_events'
--      AND COLUMN_NAME = 'causal_parent_frag_sequence'
--      AND DATA_TYPE = 'bigint' AND IS_NULLABLE = 'YES'
--   UNION ALL
--   SELECT 4, 'assist resolve index, 3 parts, non-unique',
--          IF(COUNT(*) = 3 AND MIN(NON_UNIQUE) = 1, 'PASS', CONCAT('FAIL(', COUNT(*), ')'))
--     FROM information_schema.STATISTICS
--    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'ktp_assist_events'
--      AND INDEX_NAME = 'idx_assist_causal_life'
--   UNION ALL
--   SELECT 5, 'NEGATIVE CONTROL: damage table must NOT gain a link column',
--          IF(COUNT(*) = 0, 'PASS', CONCAT('FAIL(', COUNT(*), ')'))
--     FROM information_schema.COLUMNS
--    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'ktp_damage_events'
--      AND COLUMN_NAME LIKE 'causal_parent%'
--   ORDER BY n;
--
-- Pre-apply baseline on production, measured 2026-11-05: rows 1-4 FAIL(0), row 5
-- PASS. No column anywhere in hlstatsx matched '%causal%' or '%parent%' (0 hits),
-- against a positive control of 21 tables carrying a producer_sequence column and a
-- nonsense-token control of 0.
