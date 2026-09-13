# Paper 3 measurement artifact — bounded, honest node-level caching

Raw data, evidence bundles, and the harness for the six evaluation campaigns of
paper 3, plus the cross-snapshotter source audit. Every campaign directory keeps
the structure it had on the rig: pre-registration, run report, `results/`, and
`scripts-as-run/`.

Everything here was scrubbed before it was committed — see
[`SCRUBBING-NOTE.md`](SCRUBBING-NOTE.md).

## Campaign directories ↔ the paper

The paper numbers its campaigns **I–VI** in Table `tab:campaigns`
(Section `sec:eval`). The mapping is one-to-one:

| paper | directory | pre-specified question | paper sections / tables |
| --- | --- | --- | --- |
| **I** | [`campaign-1-platform-actuation/`](campaign-1-platform-actuation/) | Can kubelet or the shipped FUSE manager already contain the failure? | §`sec:facts` (F4, F5); Table `tab:ledger` |
| **II** | [`campaign-2-elimination/`](campaign-2-elimination/) | Does pass-through eliminate the failure class? Does a sentinel probe suffice? | Table `tab:elim`; Fig. `fig:sweep`; F3 |
| **III** | [`campaign-3-flood-falsification/`](campaign-3-flood-falsification/) | Does the budget survive its own lossy accounting? | §`sec:c4`; Table `tab:cfour` |
| **IV** | [`campaign-4-confirmation-policy/`](campaign-4-confirmation-policy/) | Do the fixes hold under the original protocols? | §`sec:c4`; Fig. `fig:restart`; policy gate |
| **V** | [`campaign-5-contended-policy/`](campaign-5-contended-policy/) | Does a contended regime separate LRU from 2Q? | §`sec:eval`, "Eviction policy: an honest negative" |
| **VI** | [`campaign-6-tenancy-fleet/`](campaign-6-tenancy-fleet/) | Does the bound survive a second tenant and fleet concurrency? Is registry egress linear in node count? | §`sec:tenancy`; §`sec:limits` |
| — | [`cross-snapshotter-audit/`](cross-snapshotter-audit/) | Is the failure class shared by SOCI and Nydus? | §`sec:audit`; Table `tab:audit` |

On the rig these were spikes v4–v9 respectively; the internal `v4`…`v9` naming
survives inside file names and report titles, and is not an error.

## How to read a campaign

Each directory contains, in the order you should read them:

1. **`PRE-REGISTRATION-v*.md`** — written and locked *before* the rig existed.
   It states what was expected and, importantly, what would falsify it.
2. **`RUN-REPORT-v*.md`** — what actually ran, what happened, and the verdicts
   against the pre-registration. Anomalies and failures are at the top, not
   buried; where a campaign falsified its own expectation, the report says so.
3. **`results/`** — per-trial evidence bundles. A bundle typically carries the
   10 s sampler CSV, both daemons' logs, the full Prometheus metrics dump, the
   kubelet eviction assertion, ENOSPC counts and `df` at three points.
4. **`scripts-as-run/`** — the scripts exactly as executed, including their
   inline commentary on live fixes.

**Verification notes appended to run reports are part of the record.** Several
reports carry corrections written after the fact — a first diagnosis that turned
out to be wrong, a figure that did not reproduce, a post-lock protocol change.
These are appended rather than edited in, and they are as much a part of the
artifact as the original text.

**Trials flagged `-INVALID` are included deliberately.** They failed a
pre-specified entry condition and carry a `WHY-INVALID.txt` saying which one. They
are part of the method, not debris: the campaigns commit to preserving them
rather than silently re-running until a trial passes.

## What is not here

Excluded for size only — nothing was excluded because it could not be scrubbed:

| excluded | count | why |
| --- | --- | --- |
| `*.tar.gz` collection bundles (campaigns IV, V) | 26 | Redundant. Each is an archive of a directory that is also present extracted alongside it. |
| `idx5s/` accounting-index dumps (campaigns IV, V) | 93 | A 5 s-cadence series of full index snapshots, 5.3 GB in total, each largely a duplicate of the one before. |
| Single files > 50 MB (campaigns II, VI) | 9 | Registry access logs (up to 161 MB) and one 125 MB derived access trace. |

The derived, analysed forms of the excluded raw logs **are** included — for
campaign VI that means the per-phase refetch tallies, the per-request timeline
CSVs and the analysis outputs that the paper's §`sec:tenancy` numbers come from.
The excluded raw material is **available on request**.

Total here: ~124 MB across ~1.8 k files.

## Provenance

The system under test is `kliukovkin/stargz-snapshotter`, branch `c2-eviction`,
commit `6e87e34e1d8da4ca10e44b81a1891d583a4e66d5` — the commit the paper
evaluates. The vanilla control is upstream `v0.18.2`. Rigs were AWS `i4i.2xlarge`
in us-east-1, with the chunk cache on a real ~92 GB NVMe partition; each campaign
directory's report names its own instances and, where a campaign moved, its
availability zone.

Absolute times are comparable **only within a session**: every campaign states
this, and no comparison in the paper or in these reports crosses a rig boundary.
