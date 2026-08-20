-- KTP HLStatsX Migration 003: seed the DoD "assist" action
-- Run on data server: mysql -u hlstatsx -p hlstatsx < migrate_003_assist_action.sql
--
-- Pairs with KTPAMXX's ktp_stats_capture.inc, which emits
--     "Assister<uid><steamid><Team>" triggered "assist" against "Victim<...>"
--       (matchid "KTP-42") (half "2")
--       (event_epoch "1787154601") (game_time "245.32")
-- Migration 017 adds a private canonical companion table for those producer
-- fields. This generic action remains enabled and rating-neutral.
-- from stats_logging.sma. The daemon already handles that line shape (the same
-- generic player-vs-player path KTP's own headshot_kill marker rides) and needs
-- no code change -- but doEvent_PlayerPlayerAction only records an action that
-- exists in hlstats_Actions. Without this row the line parses and is silently
-- discarded, which is exactly how the Philly LAN lost every capture event.
--
-- Column shape matches the fleet's existing DoD rows verbatim (compare
-- dod_control_point / dod_capture_area, ids 337/338).
--
-- Two deliberate values:
--
--   reward_player = 0 -- assists award NO HLStatsX skill points. The skill
--     column is HLStatsX's own ELO; KTPR computes its own rating from the event
--     rows and does not read it. Giving assists a non-zero reward would silently
--     re-rate every player on the ladder as a side effect of adding a stat.
--
--   for_PlayerActions = '0' -- load-bearing, not cosmetic. The dispatcher calls
--     doEvent_PlayerPlayerAction AND doEvent_PlayerAction for the same line,
--     each gated on its own flag ({ppaction} / {paction}). Setting both would
--     write the assist twice -- once with victim attribution, once without --
--     and apply the skill reward twice. PlayerPlayerActions is the one we want:
--     it is the only table that records who the assist was against.
--
-- Idempotent: INSERT IGNORE against the (code, game, team) unique key, so
-- re-running is safe. `id` is intentionally omitted -- the daemon resolves
-- actions by code, and letting AUTO_INCREMENT assign avoids colliding with an
-- id already used on any given install.

INSERT IGNORE INTO hlstats_Actions
    (game, code, reward_player, reward_team, team, description,
     for_PlayerActions, for_PlayerPlayerActions, for_TeamActions, for_WorldActions, count)
VALUES
    ('dod', 'assist', 0, 0, '', 'Assists', '0', '1', '0', '0', 0);

-- Verify: expects exactly one row, for_PlayerPlayerActions='1', reward_player=0.
--
--   SELECT id, game, code, reward_player, for_PlayerActions, for_PlayerPlayerActions
--   FROM hlstats_Actions WHERE game='dod' AND code='assist';
--
-- Then, after a match with assists in it, expects a non-zero count:
--
--   SELECT COUNT(*) FROM hlstats_Events_PlayerPlayerActions ppa
--   JOIN hlstats_Actions a ON a.id = ppa.actionId
--   WHERE a.code = 'assist';
--
-- A zero count there with players demonstrably assisting means the plugin side
-- is not emitting -- check that ktp_stats_capture is 1 on the game server.
