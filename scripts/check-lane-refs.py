#!/usr/bin/env python3
"""Fail when the Lane B caller feeds the harness a repository ref from a
different lineage than the harness itself.

`.github/workflows/corpus-regression.yml` calls KTPInfrastructure's
lane-b-stats-e2e.yml, and GitHub will not accept an expression in `uses:` — the
harness pin is always a literal. The reusable workflow assembles an artifact set
by running `git show <ref>:<path>` in each repository it is handed, so every
`*_ref` the caller supplies is an opportunity to pair a harness from one lineage
with sources from another. When that happens the lane dies during artifact
assembly, naming a missing file, for a reason no pull request caused and no
pull request can fix.

The rule this enforces:

  - `daemon_ref` is an expression, because KTPHLStatsX is the artifact under
    test here; pinning it would leave the lane reporting on code the pull
    request never touched
  - every other `*_ref` is a literal equal to the `uses:` pin, so the harness
    and everything it assembles come from one lineage

Which input is the artifact under test is per-repository, and that is the whole
reason this file exists separately from KTPAMXX's copy. There the plugin is
under test and `daemon_ref` must be pinned; here the daemon is under test and
`amxx_ref` must be pinned. A check that hardcoded the other repo's spelling
would demand the exact wiring that is broken here and report it clean.

No toolchain, no build, stdlib only:

    python3 scripts/check-lane-refs.py            # check this tree
    python3 scripts/check-lane-refs.py --selftest # prove the gate can fail
"""

import argparse
import os
import re
import sys

WORKFLOW = os.path.join(".github", "workflows", "corpus-regression.yml")

# The reusable workflow this caller is expected to invoke. Matching on it keeps the
# check pointed at the Lane B call even if the file grows unrelated jobs.
LANE_B = "KTPInfrastructure/.github/workflows/lane-b-stats-e2e.yml"

# The one ref that must track the pull request rather than the harness. This
# repository IS the daemon, so the daemon ref is what the lane is measuring.
UNDER_TEST = "daemon_ref"

EXPRESSION = re.compile(r"\$\{\{")


def parse(text):
    """Return (uses_ref, {input: value}, errors) for the Lane B call in `text`.

    Hand-rolled rather than PyYAML so the gate has no install step and cannot be
    skipped by a missing dependency. Only the shape this file actually uses is
    understood: a `uses:` line naming the lane, then a `with:` block of scalars.
    """
    errors = []
    uses_ref = None
    inputs = {}

    lines = text.splitlines()
    lane_at = None
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("uses:") and LANE_B in stripped:
            lane_at = i
            target = stripped.split("uses:", 1)[1].strip()
            if "@" not in target:
                errors.append(
                    "the Lane B `uses:` has no @ref pin: {!r}".format(target))
            else:
                uses_ref = target.rsplit("@", 1)[1].strip()
            break

    if lane_at is None:
        errors.append("no `uses:` line referencing {} was found in {}".format(
            LANE_B, WORKFLOW))
        return uses_ref, inputs, errors

    # Walk forward to the `with:` block belonging to this call. `with:` is a SIBLING
    # of `uses:` at the same indent, so only a strict dedent ends the job — that is
    # what stops a later job's inputs being attributed to this one.
    uses_indent = len(lines[lane_at]) - len(lines[lane_at].lstrip())
    with_indent = None
    for line in lines[lane_at + 1:]:
        if not line.strip() or line.strip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        if with_indent is None:
            if indent < uses_indent:
                break
            if line.strip() == "with:":
                with_indent = indent
            continue
        if indent <= with_indent:
            break
        key, sep, value = line.strip().partition(":")
        if sep:
            inputs[key.strip()] = value.strip()

    if with_indent is None:
        errors.append("the Lane B call has no `with:` block")

    return uses_ref, inputs, errors


def check_text(text):
    """Return a list of error strings. Empty means the pairing invariant holds."""
    uses_ref, inputs, errors = parse(text)
    if errors:
        return errors

    refs = sorted(k for k in inputs if k.endswith("_ref"))
    if not refs:
        # No `*_ref` inputs at all means the extraction died rather than that the
        # call is clean, and a dead probe must not read as agreement.
        return ["extracted no *_ref inputs from the Lane B call — dead probe"]

    if UNDER_TEST not in inputs:
        errors.append(
            "{} is not passed; the lane would test the harness lineage's own "
            "daemon instead of this pull request".format(UNDER_TEST))
    elif not EXPRESSION.search(inputs[UNDER_TEST]):
        errors.append(
            "{} is pinned to the literal {!r}. It must follow the pull request "
            "head, or the lane reports on code the PR did not change.".format(
                UNDER_TEST, inputs[UNDER_TEST]))

    for name in refs:
        if name == UNDER_TEST:
            continue
        value = inputs[name]
        if EXPRESSION.search(value):
            errors.append(
                "{} is a GitHub expression ({}). Every ref but {} must be a "
                "literal equal to the `uses:` pin {!r}, or the harness and the "
                "repositories it assembles can come from different lineages.".format(
                    name, value, UNDER_TEST, uses_ref))
        elif value != uses_ref:
            errors.append(
                "{} is {!r} but the harness is pinned at {!r}. Straddling two "
                "lineages fails during artifact assembly for reasons unrelated "
                "to the pull request.".format(name, value, uses_ref))

    return errors


def check(root):
    path = os.path.join(root, WORKFLOW)
    try:
        with open(path, "r", encoding="utf-8") as fp:
            text = fp.read()
    except OSError as exc:
        return ["cannot read {}: {}".format(WORKFLOW, exc)]
    return check_text(text)


def _fixture(uses_ref="preprod", daemon="${{ github.event.pull_request.head.sha }}",
             amxx="preprod", infra="preprod", extra=""):
    return (
        "name: Corpus Regression\n"
        "on:\n"
        "  pull_request:\n"
        "    branches: [preprod, main]\n"
        "jobs:\n"
        "  corpus-regression:\n"
        "    uses: afraznein/" + LANE_B + "@" + uses_ref + "\n"
        "    with:\n"
        "      lane: corpus\n"
        "      infrastructure_ref: " + infra + "\n"
        "      amxx_ref: " + amxx + "\n"
        "      daemon_ref: " + daemon + "\n"
        + extra +
        "    secrets: inherit\n"
    )


def selftest():
    """Prove the gate discriminates, in both directions.

    A gate is only evidence if it still fails on input it is meant to reject, so
    the negative cases below include the exact regression this check exists for.
    """
    failures = []

    def expect_pass(label, text):
        errs = check_text(text)
        if errs:
            failures.append("{}: expected clean, got {}".format(label, errs))

    def expect_fail(label, text):
        if not check_text(text):
            failures.append("{}: expected a failure, got a clean result".format(label))

    expect_pass("all refs on the harness lineage", _fixture())

    expect_fail(
        "amxx_ref follows the PR base ref (the real regression)",
        _fixture(amxx="${{ github.event.pull_request.base.ref || github.ref_name }}"))
    expect_fail(
        "amxx_ref literal from another lineage",
        _fixture(amxx="main"))
    expect_fail(
        "infrastructure_ref drifts off the uses: pin",
        _fixture(infra="main"))
    expect_fail(
        "daemon_ref pinned, so the lane cannot see the PR",
        _fixture(daemon="preprod"))
    expect_fail(
        "matchhandler_ref supplied from a context",
        _fixture(extra="      matchhandler_ref: ${{ github.ref_name }}\n"))
    expect_fail(
        "no @ref on the uses: line",
        _fixture().replace("@preprod\n", "\n", 1))
    expect_fail(
        "the Lane B call is absent",
        "name: Corpus Regression\njobs:\n  other:\n    runs-on: ubuntu-latest\n")

    if failures:
        for line in failures:
            print("SELFTEST FAILED: " + line, file=sys.stderr)
        return 1
    print("selftest: the gate accepts a paired call and rejects each way it can straddle lineages")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", default=".", help="repository root to check")
    ap.add_argument("--selftest", action="store_true",
                    help="prove the gate can fail, then exit")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    errors = check(args.root)
    if errors:
        for err in errors:
            print("::error::" + err, file=sys.stderr)
        return 1

    print("OK: every Lane B ref but {} is a literal on the harness lineage".format(UNDER_TEST))
    return 0


if __name__ == "__main__":
    sys.exit(main())
