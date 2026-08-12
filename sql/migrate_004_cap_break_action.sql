-- KTP HLStatsX Migration 004: seed the DoD "cap_break" action
-- Run on data server: mysql -u hlstatsx -p hlstatsx < migrate_004_cap_break_action.sql
--
-- Pairs with KTPAMXX's ktp_stats_capture.inc, which emits
--     "Breaker<uid><steamid><Team>" triggered "cap_break" (flag "Flagname")
-- when a player kills an enemy off a point their team was capturing. As with
-- the assist action, the daemon already handles this line shape and needs no
-- code change -- but doEvent_PlayerAction only records actions that exist in
-- hlstats_Actions, so without this row every break is parsed and discarded.
--
-- Mirror of migrate_003, with the flags the other way round: a break is a
-- single-player action (there is no "against" target), so for_PlayerActions='1'
-- and for_PlayerPlayerActions='0'.
--
-- reward_player = 0 for the same reason as the assist action: the skill column
-- is HLStatsX's own ELO, which KTPR does not read. Rewarding breaks would
-- silently re-rate the ladder as a side effect of adding a stat. The existing
-- DoD capture actions DO carry rewards (dod_control_point = 6) -- that is
-- deliberate divergence, not an oversight: those predate KTPR and their
-- weighting is already baked into historical skill values.
--
-- NOT persisted yet: the (flag "...") property. doEvent_PlayerAction stores
-- playerId/actionId/reward/position and drops unrecognised properties, so this
-- records THAT a player broke a cap, not WHICH point. Position lands in the
-- position-enrichment phase; parsing the flag name is the break-context phase.
--
-- Idempotent: INSERT IGNORE against the (code, game, team) unique key.

INSERT IGNORE INTO hlstats_Actions
    (game, code, reward_player, reward_team, team, description,
     for_PlayerActions, for_PlayerPlayerActions, for_TeamActions, for_WorldActions, count)
VALUES
    ('dod', 'cap_break', 0, 0, '', 'Cap Breaks', '1', '0', '0', '0', 0);

-- Verify: expects one row, for_PlayerActions='1', reward_player=0.
--
--   SELECT id, game, code, reward_player, for_PlayerActions, for_PlayerPlayerActions
--   FROM hlstats_Actions WHERE game='dod' AND code='cap_break';
--
-- Then, after a match containing a break:
--
--   SELECT COUNT(*) FROM hlstats_Events_PlayerActions pa
--   JOIN hlstats_Actions a ON a.id = pa.actionId
--   WHERE a.code = 'cap_break';
--
-- Zero there after a match where someone demonstrably broke a cap means the
-- plugin side is not emitting or not detecting. Check `ktp_stats_capture` is 1
-- on the game server, then look for the raw line in the server log -- if the
-- line is present and the row is not, the problem is this seed row; if the line
-- is absent, the problem is detection.
