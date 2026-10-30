-- ENGINE: mysql (hlstatsx on the data server -- NOT the Supabase editor)
-- KTP HLStatsX Migration 051: seed `own_weapon_kill`, a player-vs-player action.
--
-- STATUS: proposed, not applied.
--
-- Apply once as: sudo mysql hlstatsx < migrate_051_own_weapon_kill_action.sql
-- Idempotent: INSERT IGNORE against the (code, game, team) unique key; `id` omitted (003/045 say why).
--
-- DEPLOY ORDER: migration FIRST, then reload the daemon's action cache
--   (`systemctl kill -s HUP hlstatsx.service`; readDatabaseConfig() rebuilds it -- no restart), then
--   KTPAMXX stats_logging 1.35.0. Until the cache carries this code each line is tallied once as an
--   unresolved action and dropped -- lost rows only, no match impact.
--
-- WHAT. A hidden fun stat (drew, 2026-10-30): a player killed with THEIR OWN gun -- one they spawned
-- with, dropped (death or drop key), and someone else picked up. stats_logging 1.35.0 keeps an owner
-- stamp on every carried primary (DODX dod_client_weaponpickup + a ground-gun ledger) and, on a kill
-- whose gun's first owner is the victim, logs
--   "<killer>" triggered "own_weapon_kill" against "<victim>" with "<weapon>" (attacker_position ..)
--   (victim_position ..) (owner_drop "death"|"drop") (since_drop_s "<s>")
-- doEvent_PlayerPlayerAction stores killer, victim, positions and time in
-- hlstats_Events_PlayerPlayerActions; the weapon and match come from the frag row at the same
-- eventTime with the same killer/victim. No daemon code.
--
-- Measured before building (coordination research/stats-own-weapon-kills, S10 official matches):
-- 13% of kills use a picked-up gun; a heuristic owner match puts own-weapon kills at ~5-10 a match.
--
--   reward_player = 0              -- no HLStatsX skill points; a fun stat, not a rating input
--   for_PlayerPlayerActions = '1'  -- killer and victim both named

INSERT IGNORE INTO hlstats_Actions
    (game, code, reward_player, reward_team, team, description,
     for_PlayerActions, for_PlayerPlayerActions, for_TeamActions, for_WorldActions, count)
VALUES
    ('dod', 'own_weapon_kill', 0, 0, '', 'Killed with their own gun', '0', '1', '0', '0', 0);

SELECT code, for_PlayerPlayerActions, reward_player
FROM hlstats_Actions
WHERE game = 'dod' AND code = 'own_weapon_kill';
