-- KTP HLStatsX Migration 030: the trace target's player id on
-- ktp_shot_events. Apply after migration 029 (shot target state).
--
-- WHY. 029 recorded what the target's state WAS, which splits a confirmed hit
-- that produced no damage into already-dead / teammate / not-damageable /
-- unexplained. It did not record WHO the target was, and without that a shot
-- can only be correlated to ktp_damage_events by (attacker, time window).
--
-- That correlation cannot distinguish the two cases the whole stream exists to
-- separate:
--
--   * this shot hit its target and damage was recorded for that target, and
--   * this shot registered nothing, while an unrelated shot by the same player
--     landed on somebody else inside the same window and supplied the match.
--
-- Both look identical without a victim. The error is one-directional and runs
-- in the reassuring direction -- it can only ever turn a genuine registration
-- failure into an apparent success, never the reverse -- so any failure rate
-- measured without this column is a floor, not an estimate. On a 694-row
-- bot-lane sample the attacker-and-time join credited 100 of 115 clean
-- live-enemy hits with damage; how many of those 100 were credited to a
-- different victim's damage row is exactly what could not be asked.
--
-- Stored as the durable player id, not as the engine userid the producer sends
-- and not as an entindex. An entindex is a slot number reused after a
-- disconnect, and a userid is unique only for the lifetime of one connection;
-- neither joins to anything. The daemon resolves the userid against its live
-- player set at ingest (ktpResolveShotTargetPlayerId) so this column joins
-- ktp_damage_events.victim_id directly.
--
-- NULLABLE, and NULL is the normal state twice over: the producer sends the
-- 029 target group only when a trace-time stash belongs to that exact shot,
-- and resolution can additionally fail -- for a target who has since left, or
-- where a reconnect leaves two live objects sharing a userid and the resolver
-- refuses to guess. Both must stay NULL. A -1 sentinel or a raw userid written
-- here would be a plausible-looking id in the wrong id space, joining to an
-- unrelated player rather than to nothing, which is worse than the gap it
-- papers over.
--
-- INT to match ktp_damage_events.victim_id and hlstats_Players.playerId; a
-- narrower column would silently truncate once player ids outgrow it.

SET @clauses := CONCAT_WS(', ',
    IF((SELECT COUNT(*)=0 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_shot_events' AND COLUMN_NAME='tgt_player_id'), 'ADD COLUMN tgt_player_id INT DEFAULT NULL COMMENT ''player the trace hit, resolved from the engine userid -- joins ktp_damage_events.victim_id''', NULL)
);
SET @ddl := IF(@clauses IS NULL OR @clauses = '', 'DO 0', CONCAT('ALTER TABLE ktp_shot_events ', @clauses));
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Verify: an exact shot-to-damage join, which (attacker, time) alone could not
-- express. Counts clean live-enemy hits that damaged THAT target, and is the
-- denominator the residual should be measured against from here on.
--
--   SELECT COUNT(*)
--   FROM ktp_shot_events s
--   JOIN ktp_damage_events d
--     ON d.match_id = s.match_id
--    AND d.attacker_id = s.player_id
--    AND d.victim_id = s.tgt_player_id
--    AND ABS(d.game_time - s.game_time) < 0.30
--   WHERE s.tgt_dead = 0 AND s.tgt_team <> s.shooter_team
--     AND (s.trace_flags & 15) = 0;
