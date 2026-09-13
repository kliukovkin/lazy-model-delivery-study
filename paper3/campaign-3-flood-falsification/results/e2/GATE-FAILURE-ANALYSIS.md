# E2 gate failure — diagnosis

Written after the first complete ABBA crossover. `GATE-FAILURE.md` beside this
file is the machine-generated record; this is the analysis the pre-registration
requires rig time to be spent on instead of on a dirty comparison
(PRE-REGISTRATION-v6.md §2.3).

## What failed

| gate | result |
| --- | --- |
| **G1** — the four warm references agree within 5% | **PASS**, max deviation **1.8%** (604.1, 603.6, 620.6, 610.2; mean 609.6) |
| **G2** — within each run, pass 3 is within 5% of pass 2 | **FAIL** on run3 (11.3%) and run4 (5.8%) |

G1 passing is the headline improvement over v5, whose two arms differed by
**21.6%**. The baselines of the four v6 arm-runs agree to better than 2%, so the
arms genuinely did share a starting state. What failed is narrower: in two of
the four runs the warm-up had not *converged* by the time the reference pass was
taken.

## It is not sampling noise, and that was checked rather than assumed

Each warm pass yields 28 latencies (one round over 28 files), and a 5% tolerance
on a 28-sample median could plausibly be tighter than the statistic's own error.
It is not:

| run | pass-3 p50 | IQR | bootstrap 95% CI of that p50 | CI width |
| --- | --- | --- | --- | --- |
| run1-lru | 603.0 | 16.9 | [597.8, 610.4] | 2.1% |
| run2-2q | 603.0 | 27.6 | [592.8, 612.7] | 3.3% |
| run3-2q | 620.6 | 31.2 | [608.8, 626.5] | 2.8% |
| run4-lru | 610.0 | 14.2 | [601.9, 613.0] | 1.8% |

And directly: two independent 28-sample medians resampled from a single run's
own latency distribution differ by more than 5% in **0.0% of 4000 bootstrap
pairs**. A 5% pass-to-pass difference is therefore far outside what sampling
error produces, and G2's tolerance was not too tight.

## What the two failures look like

| run | pass 2 | pass 3 | difference | direction |
| --- | --- | --- | --- | --- |
| run1-lru | 587.6 | 603.0 | 2.6% | — |
| run2-2q | 587.2 | 603.0 | 2.7% | — |
| run3-2q | **699.8** | 620.6 | **11.3%** | pass 2 much slower — still warming |
| run4-lru | 576.4 | **610.0** | **5.8%** | pass 3 slower — drifted the other way |

The two failures point in opposite directions, so this is not "the warm-up is
uniformly too short". It is that a **fixed** number of warm passes does not
guarantee a converged state: three passes happened to be enough in two runs and
not in the other two, and nothing in the protocol noticed.

## Consequence for the comparison

None is computed, as pre-registered. For the record, and explicitly **not** as a
result: the measured p50s were lru 539.1 / 535.2 and 2q 532.1 / 644.1. The two
2q arms differ from each other by 112 ms, which is larger than any difference
between the policies, so even with a passing gate this crossover would have
reported **"not separable at N=2"** under the effect-size rule in §2.4. The run3
anomaly shows up in both the warm-up and the measurement, which is consistent
with one arm having run in a different state throughout rather than with a
policy effect.

## Fix, and why it is not a weakening of the gate

An **adaptive warm-up**: keep running warm passes until two consecutive passes
agree within the same 5% the gate already uses, then take the last as the
reference; cap the number of passes, and mark the arm INVALID if it never
converges.

The tolerance is unchanged — this does not move the bar after seeing the data.
What changes is that the protocol now *achieves* the condition the gate tests,
instead of assuming three passes achieve it and failing afterwards. The cost is
about 15 s per extra pass.

## What is preserved

All four arm-runs keep their full bundles. They are valid measurements of a
system in a state that was not uniform across arms, which is precisely what the
gate is for, and they are the evidence for this diagnosis.
