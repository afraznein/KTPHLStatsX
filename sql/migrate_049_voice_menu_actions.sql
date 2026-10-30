-- ENGINE: mysql (hlstatsx on the data server -- NOT the Supabase editor)
-- KTP HLStatsX Migration 049: seed the 27 DoD voice-MENU picks as their own actions.
--
-- STATUS: APPLIED to production 2026-10-25, per this repo's own CHANGELOG entry
--   "a config reload now clears the unresolved-action tally it just invalidated", which
--   measures the daemon's behaviour "after 049 was applied and SIGHUP'd on 2026-10-25".
--   Its producer is live too: stats_logging 1.33.0 is 24/24 on the fleet, verified by md5
--   2026-10-28 (`7aed80db3390c3d9b736dc22e0fc2161`), swapped at the 03:00 ET restart on
--   2026-10-27.
--   This line read "proposed, not applied" for five days after it ran.
--   WEAKER EVIDENCE THAN ITS SIBLINGS, SAID RATHER THAN FLATTENED: 045-048 each have a
--   ledger tick carrying a timestamp and a file md5 verified on both ends. This one has
--   that CHANGELOG sentence and no `dpl-` row of its own, so it rests on a record written
--   after the fact. Re-derive it if it ever matters:
--     SELECT COUNT(*) FROM hlstats_Actions WHERE game='dod' AND code LIKE 'voicemenu\_%';
--   expects 27, with a nonsense-code control at 0.
--
-- Apply once as: sudo mysql hlstatsx < migrate_049_voice_menu_actions.sql
-- Idempotent: INSERT IGNORE against the (code, game, team) unique key; `id` omitted (003/045 say why).
--
-- DEPLOY ORDER: migration FIRST, then reload the daemon's action cache
--   (`systemctl kill -s HUP hlstatsx.service`; readDatabaseConfig() rebuilds it -- no restart), then
--   KTPAMXX stats_logging 1.33.0. Until the cache carries these codes each line is tallied once as an
--   unresolved action and dropped -- lost rows only, no match impact.
--
-- WHY. Measured 2026-10-25: since voice capture went live the daemon's ONLY unresolved codes were
-- voice_menu1/2/3. Most players send voice through DoD's server-drawn menu (voice_menuN, then
-- `menuselect <slot>`), which names no voice, so migration 045's 27 bound-key codes saw a fraction of
-- the league's negs. 1.33.0 maps (menu, slot) to the voice it plays and logs it as voicemenu_<name>.
--
-- WHY A SEPARATE FAMILY, not the 045 codes: drew wants to keep HOW a command was sent -- bound key
-- (`voice_*`, 045) vs voice menu (`voicemenu_*`, this file) -- as a dimension in the stats
-- (2026-10-25). A distinct code keeps that in hlstats_Events_PlayerActions with no new column and no
-- daemon change. Readers that want "all negs" add `voice_negative` + `voicemenu_negative`.
--
-- THE TABLE. dod.so (DoD 1.3, build 4502) lays its 27 voice commands out as three menus of nine; the
-- description names the menu and slot. Lane B checks every slot against the #Voice_subtitle_* the game
-- sends for the pick.
--
--   reward_player = 0        -- no HLStatsX skill points
--   for_PlayerActions = '1'  -- no victim; PlayerActions only

INSERT IGNORE INTO hlstats_Actions
    (game, code, reward_player, reward_team, team, description,
     for_PlayerActions, for_PlayerPlayerActions, for_TeamActions, for_WorldActions, count)
VALUES
    ('dod', 'voicemenu_attack'        , 0, 0, '', 'Voice menu 1.1: Attack'            , '1', '0', '0', '0', 0),
    ('dod', 'voicemenu_hold'          , 0, 0, '', 'Voice menu 1.2: Hold'              , '1', '0', '0', '0', 0),
    ('dod', 'voicemenu_fallback'      , 0, 0, '', 'Voice menu 1.3: Fall Back'         , '1', '0', '0', '0', 0),
    ('dod', 'voicemenu_left'          , 0, 0, '', 'Voice menu 1.4: Left Flank'        , '1', '0', '0', '0', 0),
    ('dod', 'voicemenu_right'         , 0, 0, '', 'Voice menu 1.5: Right Flank'       , '1', '0', '0', '0', 0),
    ('dod', 'voicemenu_sticktogether' , 0, 0, '', 'Voice menu 1.6: Stick Together'    , '1', '0', '0', '0', 0),
    ('dod', 'voicemenu_cover'         , 0, 0, '', 'Voice menu 1.7: Cover Me'          , '1', '0', '0', '0', 0),
    ('dod', 'voicemenu_usegrens'      , 0, 0, '', 'Voice menu 1.8: Use Grenades'      , '1', '0', '0', '0', 0),
    ('dod', 'voicemenu_ceasefire'     , 0, 0, '', 'Voice menu 1.9: Cease Fire'        , '1', '0', '0', '0', 0),
    ('dod', 'voicemenu_yessir'        , 0, 0, '', 'Voice menu 2.1: Yes Sir'           , '1', '0', '0', '0', 0),
    ('dod', 'voicemenu_negative'      , 0, 0, '', 'Voice menu 2.2: Negative'          , '1', '0', '0', '0', 0),
    ('dod', 'voicemenu_backup'        , 0, 0, '', 'Voice menu 2.3: Need Backup'       , '1', '0', '0', '0', 0),
    ('dod', 'voicemenu_fireinhole'    , 0, 0, '', 'Voice menu 2.4: Fire In The Hole'  , '1', '0', '0', '0', 0),
    ('dod', 'voicemenu_grenade'       , 0, 0, '', 'Voice menu 2.5: Grenade'           , '1', '0', '0', '0', 0),
    ('dod', 'voicemenu_sniper'        , 0, 0, '', 'Voice menu 2.6: Sniper'            , '1', '0', '0', '0', 0),
    ('dod', 'voicemenu_fireleft'      , 0, 0, '', 'Voice menu 2.7: Fire Left'         , '1', '0', '0', '0', 0),
    ('dod', 'voicemenu_fireright'     , 0, 0, '', 'Voice menu 2.8: Fire Right'        , '1', '0', '0', '0', 0),
    ('dod', 'voicemenu_areaclear'     , 0, 0, '', 'Voice menu 2.9: Area Clear'        , '1', '0', '0', '0', 0),
    ('dod', 'voicemenu_gogogo'        , 0, 0, '', 'Voice menu 3.1: Go Go Go'          , '1', '0', '0', '0', 0),
    ('dod', 'voicemenu_displace'      , 0, 0, '', 'Voice menu 3.2: Displace'          , '1', '0', '0', '0', 0),
    ('dod', 'voicemenu_enemyahead'    , 0, 0, '', 'Voice menu 3.3: Enemy Ahead'       , '1', '0', '0', '0', 0),
    ('dod', 'voicemenu_enemybehind'   , 0, 0, '', 'Voice menu 3.4: Enemy Behind'      , '1', '0', '0', '0', 0),
    ('dod', 'voicemenu_mgahead'       , 0, 0, '', 'Voice menu 3.5: MG Ahead'          , '1', '0', '0', '0', 0),
    ('dod', 'voicemenu_moveupmg'      , 0, 0, '', 'Voice menu 3.6: Move Up MG'        , '1', '0', '0', '0', 0),
    ('dod', 'voicemenu_needammo'      , 0, 0, '', 'Voice menu 3.7: Need Ammo'         , '1', '0', '0', '0', 0),
    ('dod', 'voicemenu_usebazooka'    , 0, 0, '', 'Voice menu 3.8: Use Bazooka'       , '1', '0', '0', '0', 0),
    ('dod', 'voicemenu_bazookaspotted', 0, 0, '', 'Voice menu 3.9: Bazooka Spotted'   , '1', '0', '0', '0', 0);

-- Verify: expects 27 rows, all for_PlayerActions='1', reward_player=0.
--
--   SELECT COUNT(*), SUM(for_PlayerActions='1'), SUM(reward_player)
--   FROM hlstats_Actions WHERE game='dod' AND code LIKE 'voicemenu\_%';
--
-- After a match on 1.33.0, bound vs menu per command:
--
--   SELECT REPLACE(a.code, 'voicemenu_', 'voice_') AS command,
--          SUM(a.code LIKE 'voice\_%') AS bound, SUM(a.code LIKE 'voicemenu\_%') AS menu
--   FROM hlstats_Events_PlayerActions pa JOIN hlstats_Actions a ON a.id = pa.actionId
--   WHERE (a.code LIKE 'voice\_%' OR a.code LIKE 'voicemenu\_%') AND pa.match_id IS NOT NULL
--   GROUP BY command ORDER BY bound + menu DESC;
