-- KTP HLStatsX Migration 028: dedup guard on ktp_shot_events.
-- Apply after migration 027 (shot-context stream).
--
-- flushShotEvents() batches ~2,500 shot markers/match into one multi-row
-- INSERT via execNonQuery. execNonQuery retries once on any transient
-- failure ("the common failure here is a connection that died between the
-- ping and the write" -- its own comment) by re-running the identical query
-- text. If the first attempt's write actually reached MySQL and committed
-- but the ack was lost before Perl saw it, the retry inserts the whole
-- batch a second time with fresh auto-increment ids -- a silent duplicate,
-- not a loss. Observed on Lane B (2 of 5 post-fix runs, 2026-09-11/12):
-- ktp_shot_events row count exceeded shot markers in the source log by a
-- small amount (481 vs 472; 671 vs 670), consistent with exactly one
-- retried tail flush, not every flush.
--
-- Every real shot row's (server_id, match_id, half, producer_sequence) is
-- unique by construction: producer_sequence is now KTPAMXX's per-type
-- counter (ksc_next_type_sequence(KSC_EVENT_SHOT), fix/shot-sequence-per-
-- type-space), so two DIFFERENT shots in the same match/half can never
-- carry the same value, and a retried duplicate of the SAME shot always
-- does. That makes the natural key a safe dedup guard: add it as a UNIQUE
-- index and change the INSERT to ON DUPLICATE KEY UPDATE id=id (paired
-- daemon change), so a retried duplicate becomes a harmless no-op instead
-- of a phantom row.
--
-- Rows with no usable producer_sequence (the daemon now writes NULL there,
-- not 0, when the raw log field is missing/non-numeric) or no match_id are
-- excluded from both steps below: NULL is never equal to NULL, in a JOIN
-- condition or a UNIQUE index, so such rows can neither be flagged as
-- duplicates here nor collide against each other later.
--
-- `half` here is the DAEMON's resolved half (ktpResolveValidatedProducerEventContext's
-- epoch-window classification), not the raw producer field, same as every
-- other per-half key in this schema (ktp_capture_health included). A shot
-- near a half boundary that the daemon resolves into the wrong half could
-- in principle collide with an unrelated real shot there, since KTPAMXX's
-- per-type sequence also restarts every half. Pre-existing exposure of the
-- half-resolution design generally, not something this dedup key
-- introduces -- out of scope here.

-- Existing duplicates are pre-existing data the index below does not
-- retroactively clean up -- the ADD UNIQUE INDEX would simply fail
-- (ER_DUP_ENTRY) on any database that already has one. Remove them first,
-- keeping the lowest id per (server_id, match_id, half, producer_sequence)
-- group. Naturally idempotent: a second run finds nothing left to delete.
DELETE t1 FROM ktp_shot_events t1
INNER JOIN ktp_shot_events t2
    ON t1.server_id = t2.server_id
   AND t1.match_id = t2.match_id
   AND t1.half = t2.half
   AND t1.producer_sequence = t2.producer_sequence
   AND t1.id > t2.id
WHERE t1.producer_sequence IS NOT NULL AND t1.match_id IS NOT NULL;

SET @exists := (SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_shot_events' AND INDEX_NAME='uniq_shot_producer_sequence');
SET @ddl := IF(@exists, 'DO 0', 'ALTER TABLE ktp_shot_events ADD UNIQUE INDEX uniq_shot_producer_sequence (server_id, match_id, half, producer_sequence)');
PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- Verify: no duplicate (server_id, match_id, half, producer_sequence) groups
-- remain.
--
--   SELECT server_id, match_id, half, producer_sequence, COUNT(*) c
--   FROM ktp_shot_events
--   WHERE producer_sequence IS NOT NULL AND match_id IS NOT NULL
--   GROUP BY server_id, match_id, half, producer_sequence
--   HAVING c > 1;
