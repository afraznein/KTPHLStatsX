-- KTP HLStatsX: end-to-end validation of the 016/017 capture path (issue #31)
--
-- Read-only. Run on the data server after the first real match on an instance
-- whose stats_logging emits life_boundary and canonical assist markers:
--
--     mysql -N hlstatsx < sql/validate_016_017_end_to_end.sql
--
-- The Phase B gate asks that one post-deployment real match populate the newly
-- captured sources under real conditions. This script picks the most recent
-- match that produced ktp_damage_events (the proof a capture producer was
-- active for it -- the positive control every later zero needs) and reports
-- one row per check. Every FAIL prints the measurement it failed on.
--
-- The daemon side of a FAIL is diagnosed from the journal, which SQL cannot
-- reach. Pair this script with:
--
--     journalctl -u hlstatsx --since <match start> --until <match end> \
--       | grep -cE 'KTP_LIFE_DROP|KTP_ASSIST_DROP'
--
-- Markers arriving but dropped shows there as nonzero drops with zero rows
-- here. Markers never arriving shows as zero both places -- that combination
-- means the producer build does not emit them (measured 2026-08-24: two full
-- Denver 4 matches, 3,363 damage/position journal lines, zero life_boundary
-- mentions, zero drops -- the Aug 21 canary predates the emitter).

-- Target: newest match with damage-ledger rows.
SET @m := (SELECT match_id FROM ktp_damage_events ORDER BY id DESC LIMIT 1);

SELECT 'target_match' AS above_checks_use, @m AS match_id,
       (SELECT COUNT(DISTINCT half) FROM ktp_matches WHERE match_id = @m) AS halves,
       (SELECT MIN(start_time) FROM ktp_matches WHERE match_id = @m) AS started;

SELECT * FROM (

SELECT 1 AS ord, 'control_producer_active' AS chk,
       IF(COUNT(*) > 0, 'PASS', 'NOT APPLICABLE - no capture-producer match exists yet') AS result,
       CONCAT(COUNT(*), ' ktp_damage_events rows') AS detail
FROM ktp_damage_events WHERE match_id = @m

UNION ALL

SELECT 2, 'control_negative',
       IF(COUNT(*) = 0, 'PASS', 'FAIL - bogus match id returned rows'),
       CONCAT(COUNT(*), ' rows for a match id that cannot exist')
FROM ktp_life_events WHERE match_id = 'no-such-match-000'

UNION ALL

SELECT 3, 'life_rows_exist',
       IF(COUNT(*) > 0, 'PASS', 'FAIL - producer active (check 1) but zero life boundaries persisted'),
       CONCAT(COUNT(*), ' ktp_life_events rows')
FROM ktp_life_events WHERE match_id = @m

UNION ALL

SELECT 4, 'life_both_kinds',
       IF(COUNT(DISTINCT boundary_kind) = 2, 'PASS',
          'FAIL - a real match must produce both start and end boundaries'),
       CONCAT('kinds present: ', IFNULL(GROUP_CONCAT(DISTINCT boundary_kind), 'none'))
FROM ktp_life_events WHERE match_id = @m

UNION ALL

SELECT 5, 'life_starts_cover_ends',
       IF(SUM(boundary_kind = 'start') >= SUM(boundary_kind = 'end'), 'PASS',
          'FAIL - more ends than starts means pairing cannot close'),
       CONCAT(IFNULL(SUM(boundary_kind = 'start'), 0), ' starts / ', IFNULL(SUM(boundary_kind = 'end'), 0), ' ends')
FROM ktp_life_events WHERE match_id = @m

UNION ALL

SELECT 6, 'life_covers_every_half',
       IF((SELECT COUNT(DISTINCT half) FROM ktp_life_events WHERE match_id = @m) >=
          (SELECT COUNT(DISTINCT half) FROM ktp_matches WHERE match_id = @m),
          'PASS', 'FAIL - a played half produced no boundaries'),
       CONCAT((SELECT COUNT(DISTINCT half) FROM ktp_life_events WHERE match_id = @m),
              ' of ',
              (SELECT COUNT(DISTINCT half) FROM ktp_matches WHERE match_id = @m),
              ' halves have life rows')

UNION ALL

SELECT 7, 'life_reasons_in_contract',
       IF(COUNT(*) = 0, 'PASS', 'FAIL - reason outside the 016 semantic pairs'),
       CONCAT(COUNT(*), ' rows outside start:spawn/context_live, end:death/disconnect')
FROM ktp_life_events
WHERE match_id = @m
  AND NOT ((boundary_kind = 'start' AND reason IN ('spawn', 'context_live')) OR
           (boundary_kind = 'end'   AND reason IN ('death', 'disconnect')))

UNION ALL

SELECT 8, 'assist_rows',
       IF(COUNT(*) > 0, 'PASS',
          'WARN - zero canonical assists over a full match is possible but unlikely, read the journal for KTP_ASSIST_DROP'),
       CONCAT(COUNT(*), ' ktp_assist_events rows')
FROM ktp_assist_events WHERE match_id = @m

UNION ALL

SELECT 9, 'assists_carry_positions',
       IF(SUM(assister_pos_x IS NOT NULL) = COUNT(*) OR COUNT(*) = 0, 'PASS',
          'WARN - some assists arrived without positions'),
       CONCAT(IFNULL(SUM(assister_pos_x IS NOT NULL), 0), ' of ', COUNT(*), ' assists have assister positions')
FROM ktp_assist_events WHERE match_id = @m

) checks ORDER BY ord;
