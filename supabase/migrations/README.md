# Active migration sequence

This directory is intentionally empty while the recovery gate in
`diese-tech/sal-site#156` is open.

The first SQL file must be a 14-digit, schema-only canonical baseline produced
from a reconciled scratch restore. It must not be assembled by concatenating
the historical site and bot migration directories; those sequences cannot
replay cleanly in either order.

No migration may be added here until the baseline-adoption runbook's entry
conditions are satisfied.
