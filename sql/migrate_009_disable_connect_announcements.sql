-- KTP HLStatsX Migration 009: keep rank/points connect announcements off
-- Run on data server:
--   mysql -u hlstatsx -p hlstatsx < migrate_009_disable_connect_announcements.sql
-- Then reload the daemon without a restart:
--   systemctl kill -s HUP hlstatsx
--
-- KTP retains HLStatsX event ingestion and historical ranking, but does not
-- inject rank/points messages into live game-server chat. This upsert covers
-- both existing servers and servers whose ConnectAnnounce row was missing.

INSERT INTO hlstats_Servers_Config (serverId, parameter, value)
SELECT serverId, 'ConnectAnnounce', '0'
FROM hlstats_Servers
ON DUPLICATE KEY UPDATE value = '0';
