# Evidence inventory — what is file-backed and what is not

The rig self-terminated on its watchdog before `90-collect.sh` ran, so the result
bundles were not retrieved. This file states precisely which evidence survives as
files and which exists only as command output quoted in
`TRANSCRIBED-EVIDENCE.md`. Reports elsewhere in this directory cite one or the
other and say which.

## File-backed (survived on the workstation)

| path | what |
| --- | --- |
| `PRE-REGISTRATION-v6.md` | written and locked before launch, with §7 amendment log |
| `scripts-as-run/` | the complete harness as run, including every live fix |
| `results/CODE-FINDINGS-v6.md` | C1–C4, the defects found in the system under test |
| `results/LIVE-FIXES-v6.md` | G1–G6, the environment/harness fixes |
| `results/pre-checks/` | both arms' raw `/metrics` output, the F2 before/after |
| `results/e1/sut-VERDICT.txt` | E1 SUT scorecard, 7/9 |
| `results/e1/fuse-manager-full.log` | 193 lines of manager log incl. the pre-fix `.corrupt` rebuild |
| `results/e2/run{1,2,3,4}-*/warm-2.txt`, `warm-3.txt`, `resident-latency.txt` | **all four arm-runs' latency data** — 28 + 28 + 112 samples each |
| `results/e2/GATE-FAILURE.md`, `GATE-FAILURE-ANALYSIS.md` | the gate outcome and its diagnosis, reproducible offline |
| `results/TEARDOWN-VERIFICATION.txt` | 0 instances / 0 volumes / 0 snapshots / 0 AMIs |

The E2 gate and comparison can be **fully recomputed** from the surviving latency
files with `scripts-as-run/21-e2-analyse.py results/e2`, and were: the numbers in
the report match what the rig produced.

## Transcribed only (see `TRANSCRIBED-EVIDENCE.md`)

- E1 negative-control VERDICT (3/3)
- E3's full summary table and all four per-trial read probes
- E4's facts and scoring
- E2 run-1-attempt-1's `sampler.csv` extract (the C4 drift series) and the
  post-run filesystem state
- the C1 warning from the manager log, and the ENOSPC fatal
- the environment/identity record

## Lost entirely

- E1's five observation bundles per arm (raw `/metrics` dumps, db-holder lists)
- E2's `sampler.csv`, `metrics-after.txt`, `sweep-read.txt`, `meta.txt` per arm
- E3's per-trial bundles (journals, events, enospc counts, samplers)
- E4's `derived.trace` (324,667 events)
- the identity bundle and final journals

None of the lost material contradicts anything reported; it is supporting detail
for results whose headline numbers are recorded above. It does mean v6 does not
meet the "bundle per trial" convention that v4 and v5 met, and that is a real
shortfall rather than a formality.
