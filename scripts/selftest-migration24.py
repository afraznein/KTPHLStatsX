#!/usr/bin/env python3
"""Exercise migration 024 clean apply, rerun, legacy NULLs, and repair."""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--infrastructure-root",
        default=os.environ.get("KTP_INFRASTRUCTURE_ROOT"),
    )
    parser.add_argument(
        "--migration",
        type=Path,
        default=Path(__file__).resolve().parents[1]
        / "sql" / "migrate_024_position_state_map_revision.sql",
    )
    args = parser.parse_args()
    if not args.infrastructure_root:
        parser.error("--infrastructure-root or KTP_INFRASTRUCTURE_ROOT is required")

    helper_dir = Path(args.infrastructure_root).resolve() / "tests" / "e2e_stats"
    require((helper_dir / "ephemeral_mysql.py").is_file(), "ephemeral MySQL helper missing")
    require(args.migration.is_file(), f"migration missing: {args.migration}")
    sys.path.insert(0, str(helper_dir))
    from ephemeral_mysql import EphemeralMysql  # type: ignore

    db = EphemeralMysql.start(database="hlstatsx_migration24")
    try:
        db.sql(
            "CREATE TABLE ktp_capture_manifests ("
            "id BIGINT UNSIGNED NOT NULL PRIMARY KEY, "
            "life_buffer_entries SMALLINT UNSIGNED NOT NULL) ENGINE=InnoDB"
        )
        db.sql(
            "CREATE TABLE ktp_position_samples ("
            "id BIGINT UNSIGNED NOT NULL PRIMARY KEY, "
            "match_id VARCHAR(64) DEFAULT NULL, half TINYINT NOT NULL DEFAULT 0, "
            "pos_z MEDIUMINT NOT NULL, game_time FLOAT NOT NULL) ENGINE=InnoDB"
        )
        db.sql("INSERT INTO ktp_capture_manifests (id, life_buffer_entries) VALUES (1, 64)")
        db.sql(
            "INSERT INTO ktp_position_samples (id, match_id, half, pos_z, game_time) "
            "VALUES (1, 'legacy-TEST', 1, 0, 1.0)"
        )

        db.load_file(args.migration)
        db.load_file(args.migration)
        require(
            db.count(
                "SELECT COUNT(*) FROM information_schema.COLUMNS "
                "WHERE TABLE_SCHEMA=DATABASE() AND ((TABLE_NAME='ktp_capture_manifests' "
                "AND COLUMN_NAME IN ('map_revision_algorithm','map_revision_sha256')) OR "
                "(TABLE_NAME='ktp_position_samples' AND COLUMN_NAME IN "
                "('is_alive','is_spectator','map_revision_sha256')))"
            ) == 5,
            "clean/rerun did not leave all five migration columns",
        )
        require(
            db.count(
                "SELECT COUNT(*) FROM ktp_position_samples WHERE id=1 AND "
                "is_alive IS NULL AND is_spectator IS NULL AND map_revision_sha256 IS NULL"
            ) == 1,
            "legacy row did not retain explicit NULL/unavailable state",
        )

        db.sql("ALTER TABLE ktp_position_samples DROP INDEX idx_position_map_revision")
        db.sql("ALTER TABLE ktp_position_samples DROP COLUMN is_alive")
        db.load_file(args.migration)
        require(
            db.count(
                "SELECT COUNT(*) FROM information_schema.STATISTICS "
                "WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_position_samples' "
                "AND INDEX_NAME='idx_position_map_revision'"
            ) == 3,
            "rerun did not repair the three-column revision index",
        )
        require(
            db.count(
                "SELECT COUNT(*) FROM information_schema.COLUMNS "
                "WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_position_samples' "
                "AND COLUMN_NAME='is_alive'"
            ) == 1,
            "rerun did not repair the missing state column",
        )
        print("migration 024: clean apply, rerun, legacy NULLs, and repair passed")
        return 0
    finally:
        db.stop()


if __name__ == "__main__":
    raise SystemExit(main())
