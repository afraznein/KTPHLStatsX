# Schema 23 position-state and map-revision contract

Migration 025 is the persistence prerequisite for `stats_logging` 1.19.0 and
daemon 0.3.16. It adds nullable columns to the existing manifest and position
tables so historical rows remain valid and visibly unavailable rather than
being rewritten with invented state.

A schema-23 manifest is accepted only when it advertises both
`position_state` and `map_revision`, names `sha256`, and carries one canonical
lowercase 64-character digest of the running `maps/<map>.bsp`. Every position
sample must say `alive=1`, `spectator=0`, and repeat that digest. The daemon
requires an accepted manifest for the same server/match/half, validates the
state bits, and rejects a sample whose revision differs. Rejections contribute
to the existing `position` daemon-rejected health counter.

Schema 21 and 22 manifests remain readable for their prior capabilities, but
neither authorizes this position contract. Existing `NULL` state or revision
columns are legacy evidence only and cannot satisfy Infrastructure readiness.
Migration 025 can be rerun: each column and the revision lookup index is added
only when absent.

This contract is capture and provenance only. It does not classify positions
or enable positional scoring.
