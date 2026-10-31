-- ENGINE: mysql (hlstatsx on the data server -- NOT the Supabase editor)
-- KTP HLStatsX Migration 051: seed `own_weapon_kill`, a player-vs-player action.
--
-- STATUS: APPLIED to production, confirmed BY EFFECT 2026-10-30 ~20:00 ET. This line read
--   "proposed, not applied" while the row was live, so read the date as when it was MEASURED.
--   THE APPLY SITTING ITSELF WAS NOT RECORDED ANYWHERE: no `dpl-c8b6` ledger tick, no CHANGELOG
--   sentence, and no copy of this file anywhere on the data server. Who ran it and when is not
--   recoverable; that it ran is.
--   EVIDENCE -- this file's own verify SELECT (foot of file) returns `own_weapon_kill 1 0`, the
--   exact triple it was written to print. The row is id 794 with description
--   'Killed with their own gun', reward_player 0, for_PlayerActions 0, for_PlayerPlayerActions 1.
--   CONTROLS, because a row that is merely PRESENT could have shipped with the install:
--   `own_weapon_kill` occurs 0 times in /opt/hlstatsx/sql/install.sql and ktp_schema.sql, while
--   install.sql carries `hlstats_Actions` 4 times and `Target_Bombed` 3 times (so the probe can
--   see seeds at all) and `voicemenu` 0 times (so migration-added codes are genuinely absent from
--   it). id 794 is MAX(id), immediately after 049's 27 voicemenu rows. The row came from a
--   migration, not from the install.
--   Re-derive it with:
--     SELECT code, for_PlayerPlayerActions, reward_player FROM hlstats_Actions
--      WHERE game='dod' AND code='own_weapon_kill';
--   expecting `own_weapon_kill 1 0`, with `code='assist'` as the positive control and a nonsense
--   code at 0.
--
-- DEPLOY ORDER IS ONLY HALF DONE, AND THE HALF THAT IS MISSING IS THE ONE THIS FILE WARNS ABOUT:
--   the SIGHUP below had NOT happened as of the same measurement. `Reading database config`
--   (printEvent("CONFIG", ...) in readDatabaseConfig) appears 0 times in the hlstatsx journal
--   since 2026-10-30 19:00 ET across 39,116 lines, against 1 occurrence in the 2026-10-27
--   14:44-14:50 daemon-start window as the control that proves the phrase is visible there; the
--   daemon PID is unchanged since 2026-10-27 14:44:48 with NRestarts 0. So the action cache does
--   NOT yet carry this code. Do the reload before fielding 1.35.0, or every own-weapon line is
--   tallied once as an unresolved action and dropped.
--   The producer is not live either: stats_logging is 1.33.0, 24/24 on the fleet by md5
--   (`7aed80db3390c3d9b736dc22e0fc2161`), measured the same day -- so nothing is being lost yet.
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
