-- ENGINE: mysql (hlstatsx on the data server -- NOT the Supabase editor)
--
-- Seeds the one `voice_` code DoD 1.3 emits that migration 045 missed.
--
-- WHY THIS IS NOT A DUPLICATE OF 045. That migration seeded 27 voice commands
-- including `voice_usebazooka` and `voice_bazookaspotted`, which is why this
-- looks covered and is not: the engine also sends a bare `voice_bazooka`, and
-- no row matches it. The three nearby codes make the gap easy to read past.
--
-- HOW IT WAS FOUND, because the obvious reading was wrong. The hourly ingest
-- monitor has been failing with `unresolved_actions=4` and advising "Seed the
-- actions table". Three of those four are `voice_menu1..3`, which are
-- DELIBERATELY unseeded -- stats_logging 1.33.0 consumes them as a menu-open
-- and maps the following pick to `voicemenu_<name>` (migration 049), so
-- seeding them is the one thing that must not happen. The fourth is this code,
-- and it is a real ongoing loss: `ktpWarnUnresolvedAction` names it in the
-- daemon journal, and every `voice_bazooka` event is parsed and DISCARDED.
--
--   journalctl -u hlstatsx.service --since '<daemon start>' -o cat \
--     | grep -oE "Unresolved action '[^']+'" | sort -u
--
-- APPLY ORDER: 2. Standalone -- pairs with no other file in this queue.
--
-- Idempotent: INSERT IGNORE against the (code, game, team) unique key, so a
-- second run inserts nothing. `id` is omitted on purpose -- the daemon resolves
-- actions by code, and AUTO_INCREMENT avoids colliding with an id already used
-- on any given install (same reasoning as migrations 003 and 045).
--
-- APPLY:  sudo mysql hlstatsx < 2_MYSQL_hlstatsx_050_voice_bazooka_action.sql
-- THEN:   systemctl kill -s HUP hlstatsx.service
--
-- ⛔ THE HUP IS NOT OPTIONAL AND ITS ORDER MATTERS. The daemon caches
-- hlstats_Actions per game at startup (HLstats_Game.pm), so until it reloads
-- this row exists and changes nothing -- events keep being discarded. A reload
-- is enough and a restart is not required: `readDatabaseConfig` does
-- `%g_games = ()`, which forces the action list to be re-queried on next use.
--
-- ⚠️ The monitor will still report an unresolved count after this, and that is
-- expected rather than a failed apply: `%g_ktpUnresolvedActions` records a code
-- the first time it is seen unresolved and is never pruned, so the tally
-- survives both the seed and the reload. KTPHLStatsX#174 is the fix for that
-- half -- it clears the tally inside `reloadConfiguration` -- and it is MERGED
-- BUT NOT INSTALLED on the data server. Install it, then HUP, and the count
-- goes to 0; HUP without it leaves a stale 4 on a daemon that is no longer
-- losing anything.

INSERT IGNORE INTO hlstats_Actions
    (game, code, reward_player, reward_team, team, description,
     for_PlayerActions, for_PlayerPlayerActions, for_TeamActions, for_WorldActions, count)
VALUES
    ('dod', 'voice_bazooka',        0, 0, '', 'Voice: Bazooka',          '1', '0', '0', '0', 0);

-- Verify: expects 28 (the 27 from 045 plus this one), all for_PlayerActions='1'.
--
--   SELECT COUNT(*), SUM(for_PlayerActions='1'), SUM(reward_player)
--   FROM hlstats_Actions WHERE game='dod' AND code LIKE 'voice\_%';
--
-- Then, after a match on a reloaded daemon, expects a non-zero count for this
-- code specifically -- a zero here means the HUP never happened:
--
--   SELECT a.code, COUNT(*) FROM hlstats_Events_PlayerActions pa
--   JOIN hlstats_Actions a ON a.id = pa.actionId
--   WHERE a.code = 'voice_bazooka' AND pa.match_id IS NOT NULL
--   GROUP BY a.code;
