# SDD ledger — plan: docs/superpowers/plans/2026-08-23-aci-vn2-performance-workshop.md

Worktree: `/home/jungwoonlee/aci/.worktrees/aci-vn2-workshop`
Starting branch: `feature/aci-vn2-workshop`
Starting commit: `e555087`
Spec: `docs/superpowers/specs/2026-08-23-aci-vn2-performance-workshop-design.md`
Baseline: no implementation tests exist yet; repository contains only approved spec and plan documents.

## Pre-flight conflict scan

| Scope | Producer / requirement | Consumer / test | Finding |
| --- | --- | --- | --- |
| Task 1 self | `nearest_rank`, failure-preserving scenario summaries, three output formats | Unit tests name the same functions and semantics | Clean |
| Task 2 self | Polling collector, schema version 1, persisted evidence before nonzero exit | Tests cover first observation and timeout preservation | Clean |
| Task 3 self | Pool status normalization and health/capacity wait | Fake CLI tests cover healthy, degraded, timeout; long and short option aliases are specified | Clean |
| Task 4 self | Render five Pod documents and orchestrate runs | Render-only tests verify count, label, and pinned digest | Clean |
| Task 5 self | Azure preflight and environment JSON | Fake CLI tests cover version, provider, historical feature, Owner, SKU | Clean |
| Task 6 self | Ordered, idempotent cleanup | Fake command log verifies destructive sequence and absent-RG behavior | Clean |
| Task 7 self | README and stable module navigation skeleton | Overview test checks content, links, and 150-minute total | Clean |
| Task 8 self | Provider/RBAC verification and AKS foundation commands | Documentation test names exact required commands | Clean |
| Task 9 self | Dual release install with one admission controller | Documentation test pins release names, version, values, labels | Clean |
| Task 10 self | Four scenarios and deterministic pool recycle | Documentation test pins scenario and capacity commands | Clean |
| Task 11 self | Statistical interpretation, troubleshooting, cleanup | Documentation test pins warnings, events, limits, cleanup | Clean |
| Task 12 self | Full validation and credential-free CI | Validator runs all focused tests and repository contract checks | Clean |
| Tasks 1 → 4 | Task 1 defines raw-summary consumption and output locations | Task 4 writes schema-version-1 raw files | Clean; Task 4 must use Task 1 scenario names and raw paths |
| Tasks 1 → 11 | Task 1 provides summary CLI and report files | Task 11 documents summary invocation and interpretation | Clean |
| Tasks 2 → 4 | Task 2 collector CLI applies one rendered run and writes raw JSON | Task 4 loops collector across scenarios/runs | Clean |
| Tasks 3 → 4 | Task 3 pool checker supports expected running capacity | Task 4 gates standby runs and refill | Clean |
| Tasks 3 → 10 | Task 3 supports `-g` and `-n` aliases | Task 10 documentation uses those aliases | Clean after plan self-review correction |
| Tasks 4 → 10 | Task 4 owns scenario names, render template, output layout | Task 10 teaches exact runner invocations | Clean |
| Tasks 5 → 8 | Task 5 defines preflight command and metadata | Task 8 teaches prerequisites and foundation | Clean |
| Tasks 6 → 11 | Task 6 defines cleanup interface | Task 11 teaches cleanup and residual check | Clean |
| Tasks 7 → 8 | Task 7 creates `docs/01` and `docs/02` stable shells | Task 8 fills those files | Clean |
| Tasks 7 → 9 | Task 7 creates `docs/03` stable shell | Task 9 fills it | Clean |
| Tasks 7 → 10 | Task 7 creates `docs/04` and `docs/05` stable shells | Task 10 fills them | Clean |
| Tasks 7 → 11 | Task 7 creates `docs/06` and `docs/07` stable shells | Task 11 fills them | Clean |
| Tasks 7 → 12 | Task 7 creates README contract | Task 12 adds operator smoke checklist and validates it | Clean |
| Tasks 8 → 9 | Task 8 creates AKS labels, identity permissions, delegated subnet | Task 9 consumes them for dual VN2 | Clean |
| Tasks 9 → 10 | Task 9 exports one pool name and two Ready node labels | Task 10 runs workloads against those paths | Clean |
| Tasks 10 → 11 | Task 10 creates twelve raw files | Task 11 summarizes and interprets them | Clean |
| Tasks 1-11 → 12 | Prior tasks create every script, manifest, test, and module | Task 12 integrates validation and CI | Clean |

No pre-execution rulings were required.

Task 1: fix round 1/5 (2 addressed, 0 open — preserved evidence; malformed JSON now fails explicitly; commits 4f377d6..be5c066)
Task 1: complete (commits e555087..be5c066, review clean)
Task 2: minor (deferred): `sitecustomize.py` adds repo-wide startup behavior solely for slash-form unittest compatibility; final review should decide whether to remove it.
Task 2: minor (deferred): invalid-scenario unit test emits argparse usage text; final review should decide whether to capture stderr for pristine output.
Task 2: fix round 1/5 (3 addressed, 0 open — seeded missing Pods; persisted failure evidence; constrained scenarios; commits e6c8c71..d04b698)
Task 2: complete (commits be5c066..d04b698, review clean)
Task 3: minor (deferred): `--interval-seconds` defaults to 5 instead of requiring explicit input; final review should decide whether the default is acceptable workshop UX.
Task 3: minor (deferred): elapsed-time timeout test allows 1.2s for a 0.4s budget and may be sensitive on heavily loaded CI.
Task 3: fix round 1/5 (1 addressed, 0 open — bounded status probes and sleeps by remaining time; commits 8086fc9..9042e0c)
Task 3: complete (commits d04b698..9042e0c, review clean)
Task 4: fix round 1/5 (2 addressed, 0 open — final standby refill check; diagnostics no longer mask collector status; commits b7a56eb..320e6d3)
Task 4: complete (commits 9042e0c..320e6d3, review clean)
Task 5: Ruling: accept either direct subscription-scope Owner or inherited Owner effective at the subscription — the spec requires a dedicated subscription Owner, not inheritance provenance; checking with inherited assignments included is sufficient — if wrong, users with direct Owner would be incorrectly accepted, but direct Owner has the required permissions.
Task 5: fix round 1/5 (1 addressed, 0 open — restricted VM SKU entries now fail closed; commits a4b34a8..78a16b1)
Task 5: complete (commits 320e6d3..78a16b1, review clean with controller ruling)
Task 6: fix round 1/5 (3 addressed, 0 open — Azure subscription/RG scope validated before deletion; group existence is tri-state; polling errors report residual IDs; commits 7e028dc..ef6435c)
Task 6: complete (commits 78a16b1..ef6435c, review clean)
Task 7: minor (deferred): Module 03 objective says two labels separate four paths, but the topology has three node paths and four scenarios; Task 9 should clarify this wording.
Task 7: complete (commits ef6435c..4b6251a, review clean)

Task 7: complete (workshop overview README, module shells, docs navigation contract, focused docs test + full suite green)
Task 8: complete (docs/01-02 now cover provider registration, historical feature/GA flow, Standby Pool Resource Provider RBAC, Azure foundation AKS/NAT/kubelet grants, focused doc test + full suite green)
