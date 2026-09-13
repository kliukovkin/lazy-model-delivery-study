# V9-B observations from the FIRST rig (us-east-1a) — NOT used in any comparison

These are preserved, not deleted, per the pre-registration's rule 0.3.

us-east-1a ran out of `i4i.2xlarge` capacity mid-campaign (spot reclaimed twice
with `instance-terminated-no-capacity`, then on-demand refused with
`InsufficientInstanceCapacity`), so V9-B was rebuilt in us-east-1b and every
number quoted in RUN-REPORT-v9 §4 comes from that second rig.

What is here:
- `k1-node1-node1/` — a complete, valid k=1 baseline: 280/280 files, 150.3 GB,
  **0 read errors**, `read_s = 1174.2`, du_http+fs 9.05 GB against an 80 GB
  budget, 3,055,565 evictions, partition 100% full at 90% pre-fill.
- `k1-node1-registry/` — its registry side: NIC tx delta **158.71 GB** over
  1181.6 s, mean 133 MB/s, peak 162 MB/s = 10.9% of that rig's 1.49 GB/s NIC.
- `ceilings.txt` — the first rig's measured ceilings.

Why it is excluded: rule 0.2 forbids comparing absolute numbers across
instances, and these were taken on different instances in a different AZ from the
k=3 rounds. Quoting them beside the second rig's k=3 egress would be exactly the
cross-session comparison v8's E1 showed to be worth 16% of nothing.
