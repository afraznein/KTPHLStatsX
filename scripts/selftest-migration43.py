#!/usr/bin/env python3
"""Executable migration-043 checks using Infrastructure's ephemeral MySQL.

Point --infrastructure-root at a KTPInfrastructure checkout (the Lane B image
already contains MySQL). Exercises clean apply, rerun, repair after the index is
dropped, and refusal when the index name is taken by another column list.
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

SQL = Path(__file__).resolve().parents[1] / "sql"
INDEX_COLUMNS = (
    "SELECT GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) "
    "FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() "
    "AND TABLE_NAME='ktp_position_samples' AND INDEX_NAME='idx_pos_match_half_time'"
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--infrastructure-root",
        default=os.environ.get("KTP_INFRASTRUCTURE_ROOT"),
        help="KTPInfrastructure checkout containing tests/e2e_stats/ephemeral_mysql.py",
    )
    parser.add_argument(
        "--migration", type=Path,
        default=SQL / "migrate_043_position_samples_time_index.sql",
    )
    args = parser.parse_args()
    if not args.infrastructure_root:
        parser.error("--infrastructure-root or KTP_INFRASTRUCTURE_ROOT is required")

    helper_dir = Path(args.infrastructure_root).resolve() / "tests" / "e2e_stats"
    require((helper_dir / "ephemeral_mysql.py").is_file(),
            f"ephemeral MySQL helper not found under {helper_dir}")
    require(args.migration.is_file(), f"migration not found: {args.migration}")
    sys.path.insert(0, str(helper_dir))
    from ephemeral_mysql import EphemeralMysql, MysqlUnavailable  # type: ignore

    db = EphemeralMysql.start(database="hlstatsx_migration43")
    try:
        db.load_file(SQL / "migrate_008_position_samples.sql")
        require(db.scalar(INDEX_COLUMNS) in (None, "NULL"),
                "control: the index exists before the migration ran")

        db.load_file(args.migration)
        require(db.scalar(INDEX_COLUMNS) == "match_id,half,game_time",
                f"clean apply left {db.scalar(INDEX_COLUMNS)!r}")
        db.load_file(args.migration)
        require(db.count(
            "SELECT COUNT(DISTINCT INDEX_NAME) FROM information_schema.STATISTICS "
            "WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='ktp_position_samples' "
            "AND INDEX_NAME='idx_pos_match_half_time'") == 1,
            "rerun did not leave exactly one idx_pos_match_half_time")

        db.sql("ALTER TABLE ktp_position_samples DROP INDEX idx_pos_match_half_time")
        db.load_file(args.migration)
        require(db.scalar(INDEX_COLUMNS) == "match_id,half,game_time",
                "rerun did not repair a dropped index")

        db.sql("ALTER TABLE ktp_position_samples DROP INDEX idx_pos_match_half_time, "
               "ADD INDEX idx_pos_match_half_time (match_id, game_time)")
        try:
            db.load_file(args.migration)
        except MysqlUnavailable as exc:
            require("ERROR_043_index_name_taken_by_other_columns" in str(exc),
                    f"wrong-column index failed without sentinel: {exc}")
        else:
            raise AssertionError("an index of the same name over other columns was accepted")

        print("migration 043: clean apply, rerun, repair and same-name guard passed")
        return 0
    finally:
        db.stop()


if __name__ == "__main__":
    raise SystemExit(main())
