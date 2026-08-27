#!/usr/bin/env python3
"""Executable migration-022 checks using Infrastructure's ephemeral MySQL.

This repository does not ship a database server. Point --infrastructure-root
at a KTPInfrastructure checkout (the Lane B image already contains MySQL) to
exercise clean apply, rerun, missing-index repair, and actionable partial-table
failure against the same production-parity harness used by integration tests.
"""
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
        help="KTPInfrastructure checkout containing tests/e2e_stats/ephemeral_mysql.py",
    )
    parser.add_argument(
        "--migration",
        type=Path,
        default=Path(__file__).resolve().parents[1]
        / "sql"
        / "migrate_022_objective_attempts_grenade_entities.sql",
    )
    args = parser.parse_args()
    if not args.infrastructure_root:
        parser.error("--infrastructure-root or KTP_INFRASTRUCTURE_ROOT is required")

    infrastructure = Path(args.infrastructure_root).resolve()
    helper_dir = infrastructure / "tests" / "e2e_stats"
    require(
        (helper_dir / "ephemeral_mysql.py").is_file(),
        f"ephemeral MySQL helper not found under {helper_dir}",
    )
    require(args.migration.is_file(), f"migration not found: {args.migration}")
    sys.path.insert(0, str(helper_dir))
    from ephemeral_mysql import EphemeralMysql, MysqlUnavailable  # type: ignore

    db = EphemeralMysql.start(database="hlstatsx_migration22")
    try:
        db.load_file(args.migration)
        db.load_file(args.migration)
        require(
            db.count(
                "SELECT COUNT(*) FROM information_schema.TABLES "
                "WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME IN "
                "('ktp_objective_attempt_events','ktp_grenade_entity_events')"
            )
            == 2,
            "clean/rerun did not leave both telemetry tables",
        )

        db.sql(
            "ALTER TABLE ktp_objective_attempt_events "
            "DROP INDEX idx_objective_match_timeline"
        )
        db.sql(
            "ALTER TABLE ktp_grenade_entity_events DROP INDEX idx_grenade_owner"
        )
        db.load_file(args.migration)
        require(
            db.count(
                "SELECT COUNT(DISTINCT INDEX_NAME) FROM information_schema.STATISTICS "
                "WHERE TABLE_SCHEMA=DATABASE() AND "
                "((TABLE_NAME='ktp_objective_attempt_events' AND "
                "INDEX_NAME='idx_objective_match_timeline') OR "
                "(TABLE_NAME='ktp_grenade_entity_events' AND "
                "INDEX_NAME='idx_grenade_owner'))"
            )
            == 2,
            "rerun did not repair missing named indexes",
        )

        db.sql(
            "ALTER TABLE ktp_objective_attempt_events "
            "DROP INDEX uk_objective_producer_sequence, "
            "ADD INDEX uk_objective_producer_sequence "
            "(server_id, match_id, half, producer_sequence)"
        )
        try:
            db.load_file(args.migration)
        except MysqlUnavailable as exc:
            require(
                "ERROR_022_objective_table_partial_or_incompatible" in str(exc),
                f"wrong-uniqueness objective index failed without sentinel: {exc}",
            )
        else:
            raise AssertionError("same-name nonunique objective index was accepted")
        db.sql(
            "ALTER TABLE ktp_objective_attempt_events "
            "DROP INDEX uk_objective_producer_sequence, "
            "ADD UNIQUE KEY uk_objective_producer_sequence "
            "(server_id, match_id, half, producer_sequence)"
        )
        db.load_file(args.migration)

        db.sql(
            "ALTER TABLE ktp_grenade_entity_events "
            "ADD COLUMN incompatible_required INT NOT NULL"
        )
        try:
            db.load_file(args.migration)
        except MysqlUnavailable as exc:
            require(
                "ERROR_022_grenade_table_partial_or_incompatible" in str(exc),
                f"extra required grenade column failed without sentinel: {exc}",
            )
        else:
            raise AssertionError("extra required/no-default grenade column was accepted")
        db.sql(
            "ALTER TABLE ktp_grenade_entity_events "
            "DROP COLUMN incompatible_required"
        )
        db.load_file(args.migration)

        db.sql("ALTER TABLE ktp_objective_attempt_events DROP COLUMN flag_name")
        try:
            db.load_file(args.migration)
        except MysqlUnavailable as exc:
            require(
                "ERROR_022_objective_table_partial_or_incompatible" in str(exc),
                f"partial objective table failed without actionable sentinel: {exc}",
            )
        else:
            raise AssertionError("partial objective table was silently accepted")

        db.sql(
            "ALTER TABLE ktp_objective_attempt_events "
            "ADD COLUMN flag_name VARCHAR(64) NOT NULL AFTER flag_index"
        )
        db.load_file(args.migration)
        db.sql("ALTER TABLE ktp_grenade_entity_events DROP COLUMN pos_z")
        try:
            db.load_file(args.migration)
        except MysqlUnavailable as exc:
            require(
                "ERROR_022_grenade_table_partial_or_incompatible" in str(exc),
                f"partial grenade table failed without actionable sentinel: {exc}",
            )
        else:
            raise AssertionError("partial grenade table was silently accepted")

        print(
            "migration 022: clean apply, rerun, index repair, exact-index and "
            "partial/extra-column guards passed"
        )
        return 0
    finally:
        db.stop()


if __name__ == "__main__":
    raise SystemExit(main())
