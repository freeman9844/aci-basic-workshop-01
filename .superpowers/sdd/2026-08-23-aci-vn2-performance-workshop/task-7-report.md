# Task 7 Report: Workshop Overview and Module Flow

## Summary
- Added `README.md` with quick clone guidance, architecture Mermaid, four-scenario overview, prerequisite and cost warnings, module table, completion checklist, and mandatory cleanup guidance.
- Added stable Korean module shells in `docs/01-prerequisites.md` through `docs/07-limitations-troubleshooting-cleanup.md`.
- Added `tests/docs/test-overview.sh` to verify required overview content, exact module duration totals, and bidirectional previous/next navigation.

## TDD
1. Wrote `tests/docs/test-overview.sh` first.
2. Ran `bash tests/docs/test-overview.sh` and confirmed failure because `README.md` and the seven module files did not exist.
3. Implemented the minimum documentation needed for the overview contract, then reran the focused test until it passed.

## RED evidence
Command:
```bash
cd /home/jungwoonlee/aci/.worktrees/aci-vn2-workshop && bash tests/docs/test-overview.sh
```
Output:
```text
Missing required documentation file(s): README.md, docs/01-prerequisites.md, docs/02-azure-foundation.md, docs/03-install-dual-vn2.md, docs/04-baseline-ondemand-benchmark.md, docs/05-standby-cache-benchmark.md, docs/06-analyze-results.md, docs/07-limitations-troubleshooting-cleanup.md
```

## GREEN evidence
Command:
```bash
cd /home/jungwoonlee/aci/.worktrees/aci-vn2-workshop && bash tests/docs/test-overview.sh
```
Output:
```text
(exit 0)
```

## Full-suite evidence
Command:
```bash
cd /home/jungwoonlee/aci/.worktrees/aci-vn2-workshop && bash tests/scripts/test-check-standby-pool.sh && bash tests/scripts/test-cleanup.sh && bash tests/scripts/test-preflight.sh && bash tests/scripts/test-run-benchmark.sh && bash tests/docs/test-overview.sh && python3 -m unittest discover -s tests -p 'test_*.py' && git diff --check
```
Output:
```text
(exit 0)
```

## Files
- `README.md`
- `docs/01-prerequisites.md`
- `docs/02-azure-foundation.md`
- `docs/03-install-dual-vn2.md`
- `docs/04-baseline-ondemand-benchmark.md`
- `docs/05-standby-cache-benchmark.md`
- `docs/06-analyze-results.md`
- `docs/07-limitations-troubleshooting-cleanup.md`
- `tests/docs/test-overview.sh`

## Notes
- README carries the required Korean terms and explicit cost/cleanup warnings so participants see them before any Azure provisioning work.
- Each module shell includes a Korean title, objective, duration, prior-state contract, concrete next actions, and stable previous/next navigation for later expansion.
