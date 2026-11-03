# Display corruption diagnosis — 2026-10-28/29

The maintained regression harnesses are in `sim/scripts/run_display_content.ps1`,
`run_sdram_refresh_regression.ps1` and `run_sdram_frame_retention.ps1`.
The diagnosis, validation scope and board acceptance steps are documented in
[`docs/display_fix_2026-10-29.md`](../../docs/display_fix_2026-10-29.md).

`evidence/` contains curated verdicts and small logs for the failing two-group
read replay, refresh defects, and final regressions. Each result retains source
SHA-256 identities. Historical results describe the sources recorded in that
result; the final build manifest identifies the release inputs.

Other subdirectories are **local diagnostic experiments**, not production
sources. They retain raw captures, generated SD fixtures, simulator libraries,
temporary probes and alternative wrappers for audit. They are deliberately
excluded from Git; do not compile those wrappers into the TD project.
