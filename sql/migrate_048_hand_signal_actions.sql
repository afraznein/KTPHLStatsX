-- ENGINE: mysql (hlstatsx on the data server -- NOT the Supabase editor)
-- KTP HLStatsX Migration 048: seed the DoD hand signals as actions.
--
-- STATUS: proposed, not applied.
--
-- Apply once as: sudo mysql hlstatsx < migrate_048_hand_signal_actions.sql
-- Idempotent: INSERT IGNORE against the (code, game, team) unique key; `id` omitted so
-- AUTO_INCREMENT assigns it (migrations 003 and 045 explain why).
--
-- DEPLOY ORDER: migration FIRST, then the plugin (KTPAMXX stats_logging 1.32.0), with a
--   daemon action-cache reload between them: `readDatabaseConfig()` rebuilds the cache on
--   SIGHUP or a new-server registration (knowledge/KTPHLStatsX.md, corrected 2026-10-23), so
--   `systemctl kill -s HUP hlstatsx.service` after the apply is enough; a restart also works.
--   Until the cache carries these codes the daemon tallies each line once as an unresolved
--   action and drops it -- lost rows only, no match impact.
--
-- WHY. Same ask as migration 045, one family over: players pointed out that hand signals are
-- used the same way voice commands are (and taunt the same way). The plugin hook is the same
-- one, widened to the `signal_` prefix; this seed is the only daemon-side change.
--
-- THE LIST. These 16 are every `signal_*` string dod.so (DoD 1.3, build 4502) handles by name
-- in its ClientCommand -- read from the binary. The client registers none of them itself
-- (its menu sends the name through), so there is no client-only subset to exclude.
--
--   reward_player = 0        -- no HLStatsX skill points; KTPR reads the event rows
--   for_PlayerActions = '1'  -- no victim; PlayerActions only, never PlayerPlayerActions

INSERT IGNORE INTO hlstats_Actions
    (game, code, reward_player, reward_team, team, description,
     for_PlayerActions, for_PlayerPlayerActions, for_TeamActions, for_WorldActions, count)
VALUES
    ('dod', 'signal_areaclear',     0, 0, '', 'Signal: Area Clear',     '1', '0', '0', '0', 0),
    ('dod', 'signal_backup',        0, 0, '', 'Signal: Need Backup',    '1', '0', '0', '0', 0),
    ('dod', 'signal_coveringfire',  0, 0, '', 'Signal: Covering Fire',  '1', '0', '0', '0', 0),
    ('dod', 'signal_enemyleft',     0, 0, '', 'Signal: Enemy Left',     '1', '0', '0', '0', 0),
    ('dod', 'signal_enemyright',    0, 0, '', 'Signal: Enemy Right',    '1', '0', '0', '0', 0),
    ('dod', 'signal_enemyspotted',  0, 0, '', 'Signal: Enemy Spotted',  '1', '0', '0', '0', 0),
    ('dod', 'signal_fallback',      0, 0, '', 'Signal: Fall Back',      '1', '0', '0', '0', 0),
    ('dod', 'signal_flankleft',     0, 0, '', 'Signal: Flank Left',     '1', '0', '0', '0', 0),
    ('dod', 'signal_flankright',    0, 0, '', 'Signal: Flank Right',    '1', '0', '0', '0', 0),
    ('dod', 'signal_grenade',       0, 0, '', 'Signal: Grenade',        '1', '0', '0', '0', 0),
    ('dod', 'signal_holdposition',  0, 0, '', 'Signal: Hold Position',  '1', '0', '0', '0', 0),
    ('dod', 'signal_moveout',       0, 0, '', 'Signal: Move Out',       '1', '0', '0', '0', 0),
    ('dod', 'signal_no',            0, 0, '', 'Signal: No',             '1', '0', '0', '0', 0),
    ('dod', 'signal_sniper',        0, 0, '', 'Signal: Sniper',         '1', '0', '0', '0', 0),
    ('dod', 'signal_sticktogether', 0, 0, '', 'Signal: Stick Together', '1', '0', '0', '0', 0),
    ('dod', 'signal_yes',           0, 0, '', 'Signal: Yes',            '1', '0', '0', '0', 0);

-- Verify: expects 16 rows, all for_PlayerActions='1', reward_player=0.
--
--   SELECT COUNT(*), SUM(for_PlayerActions='1'), SUM(reward_player)
--   FROM hlstats_Actions WHERE game='dod' AND code LIKE 'signal\_%';
--
-- Then, after a match on stats_logging 1.32.0 with the cache reloaded:
--
--   SELECT a.code, COUNT(*) FROM hlstats_Events_PlayerActions pa
--   JOIN hlstats_Actions a ON a.id = pa.actionId
--   WHERE a.code LIKE 'signal\_%' AND pa.match_id IS NOT NULL
--   GROUP BY a.code ORDER BY 2 DESC;
