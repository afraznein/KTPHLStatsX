-- KTP HLStatsX Migration 026: persisted match analytics reports + season aggregates.
-- Apply after migration 025. Read side: website/API and MMR research both read
-- these tables; the website never recomputes scoring (see
-- handover/WEBSITE_SHADOW_STATS_PROMOTION_HANDOVER_20260906.md).
--
-- Both tables are append-only revision stores. Regeneration inserts a new
-- revision row; nothing ever UPDATEs a persisted report in place.

CREATE TABLE IF NOT EXISTS ktp_match_reports (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    match_id VARCHAR(64) NOT NULL,
    schema_version INT UNSIGNED NOT NULL,
    revision INT UNSIGNED NOT NULL DEFAULT 1,
    generated_at DATETIME NOT NULL,
    quality_status VARCHAR(16) NOT NULL,
    -- 1 only when every hard quality check passes, ignoring the cosmetic
    -- match_id_shape FAIL on legacy '1.3-' ids. The read API serves only
    -- publishable=1 rows.
    publishable TINYINT UNSIGNED NOT NULL DEFAULT 0,
    report_sha256 CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    report MEDIUMTEXT CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uq_match_schema_revision (match_id, schema_version, revision),
    KEY idx_match_latest (match_id, id),
    KEY idx_publishable (publishable, schema_version)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

CREATE TABLE IF NOT EXISTS ktp_web_season_aggregates (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    -- e.g. 'leaderboard_ktpr_v2', 'map_profiles', 'head_to_head'
    kind VARCHAR(64) NOT NULL,
    revision INT UNSIGNED NOT NULL DEFAULT 1,
    generated_at DATETIME NOT NULL,
    source_report_count INT UNSIGNED NOT NULL,
    -- max report schema_version aggregated; display alongside the numbers
    report_schema_version INT UNSIGNED NOT NULL,
    payload_sha256 CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    payload MEDIUMTEXT CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uq_kind_revision (kind, revision),
    KEY idx_kind_latest (kind, id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- Verification:
-- SELECT match_id, schema_version, revision, quality_status, publishable,
--        LENGTH(report) AS bytes FROM ktp_match_reports
-- ORDER BY id DESC LIMIT 5;
-- SELECT kind, revision, source_report_count, generated_at
-- FROM ktp_web_season_aggregates ORDER BY id DESC LIMIT 5;
