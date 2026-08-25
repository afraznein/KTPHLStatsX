-- KTP HLStatsX data repair: backfill match_type for 1.3 Community match ids
--
-- NOT a migration -- a one-time production data repair, proposed for operator
-- review. Deliberately named outside the migrate_NNN pattern so no migration
-- runner picks it up.
--
-- Context (issue #37): every ktp_matches row has match_type NULL because the
-- fleet's KTPMatchHandler build (0.10.166) predates the commit that emits
-- (type "N") on KTP_MATCH_START (a46af28, first in 0.10.167). The daemon side
-- has parsed and written the property since migration 014 -- the write site in
-- doEvent_KTPMatchStart validates 0..5 and the upsert keeps an existing value
-- via COALESCE -- so rows fill themselves going forward once the producer
-- ships. This file recovers the one class of historical row whose type is
-- derivable from the match id alone.
--
-- Why the derivation is sound: generate_match_id() in KTPMatchHandler emits
-- the prefix "1.3-" for exactly one path -- a 1.3 Community 12-man queue
-- (g_is13CommunityMatch with a queue id). Every other id is epoch-SITE or
-- epoch-TEST. So match_id LIKE '1.3-%' identifies match_type 2 (12man) with
-- no ambiguity, and nothing else is derivable from the id shape.
--
-- Measured 2026-08-25: 1,994 distinct matches total, 932 with the 1.3- prefix.
-- The remaining epoch-SITE ids need the demo-archive mapping instead -- see
-- scripts/backfill-match-type-from-demos.py, which generates (and never runs)
-- per-match UPDATEs from the HLTV demo archive's type prefixes.
--
-- ---------------------------------------------------------------------------
-- DRY RUN -- expected ~932 distinct matches, 0 on a re-run after the repair.
-- ---------------------------------------------------------------------------

SELECT COUNT(*) AS rows_to_fill, COUNT(DISTINCT match_id) AS matches_to_fill
FROM ktp_matches
WHERE match_type IS NULL
  AND match_id LIKE '1.3-%';

-- ---------------------------------------------------------------------------
-- The repair. Only NULL rows are eligible, so a value the daemon has since
-- written from the wire is never overwritten.
-- ---------------------------------------------------------------------------

UPDATE ktp_matches
SET match_type = 2
WHERE match_type IS NULL
  AND match_id LIKE '1.3-%';

-- ---------------------------------------------------------------------------
-- VERIFY -- the 1.3 population reports type 2, everything else is still NULL
-- until the demo-archive backfill or the producer fills it.
-- ---------------------------------------------------------------------------

SELECT match_type, COUNT(*) AS rows_, COUNT(DISTINCT match_id) AS matches
FROM ktp_matches
GROUP BY match_type;
