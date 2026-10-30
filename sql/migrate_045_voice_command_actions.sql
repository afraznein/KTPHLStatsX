-- ENGINE: mysql (hlstatsx on the data server -- NOT the Supabase editor)
-- KTP HLStatsX Migration 045: seed the DoD voice-menu commands as actions.
--
-- STATUS: APPLIED to production 2026-10-20 22:55 ET on operator authorisation
--   (ledger row `dpl-feb6`, andsmit9/ktp-coordination NEIN-DEPLOY.md). This line read
--   "proposed, not applied" for ten days after it ran. A migration file is what the next
--   person reads to decide whether to run something, so leaving it stale is the dangerous
--   direction: it makes a done thing look owed.
--   Follow-on, recorded because the ORDER went wrong and the symptom is silent: the daemon
--   restart that loads these rows into the action cache ran 76 minutes BEFORE the apply
--   (21:39 vs 22:55), so until the next restart every `voice_*` line was tallied as an
--   unresolved action and dropped -- lost rows only, no match impact.
--
-- Apply once as: sudo mysql hlstatsx < migrate_045_voice_command_actions.sql
-- Idempotent: INSERT IGNORE against the (code, game, team) unique key, so a
-- second run inserts nothing. `id` is omitted on purpose -- the daemon resolves
-- actions by code, and AUTO_INCREMENT avoids colliding with an id already used
-- on any given install (same reasoning as migration 003).
--
-- DEPLOY ORDER: migration FIRST, then the plugin (KTPAMXX stats_logging
--   1.28.0). No daemon change: the stock PlayerAction path already records
--   any `"<player>" triggered "<code>"` line whose code is in hlstats_Actions,
--   and hlstats.pl's recordEvent() injects match_id gated on KTP_ROUND_LIVE.
--   The daemon caches hlstats_Actions at startup (HLstats_Game.pm), so RESTART
--   the daemon after applying, or the new codes are reported as unresolved
--   actions and dropped until it next starts. A plugin emitting these lines
--   against a daemon that has not loaded the rows loses them silently --
--   which is exactly how the Philly LAN lost every capture event.
--
-- WHY. Players asked how often voice commands (voice_negative and the rest)
-- are used in matches. The plugin side is one client_command hook; the only
-- thing standing between the log line and a row is this seed, because
-- doEvent_PlayerAction records nothing for a code it cannot resolve.
--
-- THE LIST. These 27 are every voice_* string dod.so (DoD 1.3, build 4502)
-- handles by name in its ClientCommand -- extracted from the binary, not from
-- a wiki. voice_menu and voice_serverdebug are also in that binary but are not
-- voice-menu picks and are deliberately left out. Client-only strings
-- (voice_modenable, voice_showbanned, voice_ban, voice_clientdebug) never
-- reach the server and are not here either.
--
-- Deliberate values, as in migration 003:
--   reward_player = 0 -- no HLStatsX skill points. KTPR reads the event rows,
--     not the skill column; a non-zero reward would re-rate the ladder as a
--     side effect of counting chatter.
--   for_PlayerActions = '1', for_PlayerPlayerActions = '0' -- a voice command
--     has no victim, so it belongs in hlstats_Events_PlayerActions only.
--     Setting both writes every line twice.
--
-- Hidden by construction: rows land in hlstats_Events_PlayerActions keyed by
-- match_id and nothing on the website reads them until someone writes a query.

INSERT IGNORE INTO hlstats_Actions
    (game, code, reward_player, reward_team, team, description,
     for_PlayerActions, for_PlayerPlayerActions, for_TeamActions, for_WorldActions, count)
VALUES
    ('dod', 'voice_areaclear',      0, 0, '', 'Voice: Area Clear',       '1', '0', '0', '0', 0),
    ('dod', 'voice_attack',         0, 0, '', 'Voice: Attack',           '1', '0', '0', '0', 0),
    ('dod', 'voice_backup',         0, 0, '', 'Voice: Need Backup',      '1', '0', '0', '0', 0),
    ('dod', 'voice_bazookaspotted', 0, 0, '', 'Voice: Bazooka Spotted',  '1', '0', '0', '0', 0),
    ('dod', 'voice_ceasefire',      0, 0, '', 'Voice: Cease Fire',       '1', '0', '0', '0', 0),
    ('dod', 'voice_cover',          0, 0, '', 'Voice: Cover Me',         '1', '0', '0', '0', 0),
    ('dod', 'voice_displace',       0, 0, '', 'Voice: Displace',         '1', '0', '0', '0', 0),
    ('dod', 'voice_enemyahead',     0, 0, '', 'Voice: Enemy Ahead',      '1', '0', '0', '0', 0),
    ('dod', 'voice_enemybehind',    0, 0, '', 'Voice: Enemy Behind',     '1', '0', '0', '0', 0),
    ('dod', 'voice_fallback',       0, 0, '', 'Voice: Fall Back',        '1', '0', '0', '0', 0),
    ('dod', 'voice_fireinhole',     0, 0, '', 'Voice: Fire In The Hole', '1', '0', '0', '0', 0),
    ('dod', 'voice_fireleft',       0, 0, '', 'Voice: Fire Left',        '1', '0', '0', '0', 0),
    ('dod', 'voice_fireright',      0, 0, '', 'Voice: Fire Right',       '1', '0', '0', '0', 0),
    ('dod', 'voice_gogogo',         0, 0, '', 'Voice: Go Go Go',         '1', '0', '0', '0', 0),
    ('dod', 'voice_grenade',        0, 0, '', 'Voice: Grenade',          '1', '0', '0', '0', 0),
    ('dod', 'voice_hold',           0, 0, '', 'Voice: Hold',             '1', '0', '0', '0', 0),
    ('dod', 'voice_left',           0, 0, '', 'Voice: Left Flank',       '1', '0', '0', '0', 0),
    ('dod', 'voice_mgahead',        0, 0, '', 'Voice: MG Ahead',         '1', '0', '0', '0', 0),
    ('dod', 'voice_moveupmg',       0, 0, '', 'Voice: Move Up MG',       '1', '0', '0', '0', 0),
    ('dod', 'voice_needammo',       0, 0, '', 'Voice: Need Ammo',        '1', '0', '0', '0', 0),
    ('dod', 'voice_negative',       0, 0, '', 'Voice: Negative',         '1', '0', '0', '0', 0),
    ('dod', 'voice_right',          0, 0, '', 'Voice: Right Flank',      '1', '0', '0', '0', 0),
    ('dod', 'voice_sniper',         0, 0, '', 'Voice: Sniper',           '1', '0', '0', '0', 0),
    ('dod', 'voice_sticktogether',  0, 0, '', 'Voice: Stick Together',   '1', '0', '0', '0', 0),
    ('dod', 'voice_usebazooka',     0, 0, '', 'Voice: Use Bazooka',      '1', '0', '0', '0', 0),
    ('dod', 'voice_usegrens',       0, 0, '', 'Voice: Use Grenades',     '1', '0', '0', '0', 0),
    ('dod', 'voice_yessir',         0, 0, '', 'Voice: Yes Sir',          '1', '0', '0', '0', 0);

-- Verify: expects 27 rows, all for_PlayerActions='1', reward_player=0.
--
--   SELECT COUNT(*), SUM(for_PlayerActions='1'), SUM(reward_player)
--   FROM hlstats_Actions WHERE game='dod' AND code LIKE 'voice\_%';
--
-- Then, after a match on stats_logging 1.28.0, expects a non-zero count:
--
--   SELECT a.code, COUNT(*) FROM hlstats_Events_PlayerActions pa
--   JOIN hlstats_Actions a ON a.id = pa.actionId
--   WHERE a.code LIKE 'voice\_%' AND pa.match_id IS NOT NULL
--   GROUP BY a.code ORDER BY 2 DESC;
