# Scrubbing note — paper3 artifact tree

Every file in `paper3/` was scrubbed **before the first `git add`**, on the
working copy, and the result was verified by re-scanning for each pattern before
anything was staged. Categories are listed below; the values themselves are
deliberately not reproduced here.

Redactions are **labelled placeholders**, not deletions, so that a reader can
tell a redaction from missing data. Where a placeholder appears, a value of that
category was present in the original run.

## Categories redacted

| category | placeholder | replacements | files |
| --- | --- | --- | --- |
| IAM ARNs | `REDACTED-IAM-ARN` | 6 | 6 |
| AWS account ID (12-digit) | `REDACTED-AWS-ACCOUNT-ID` | — (all occurrences were inside the ARNs above) | — |
| IAM user name | `REDACTED-IAM-USER` | 6 | 6 |
| AWS CLI profile name | `REDACTED-AWS-PROFILE` | 13 | 8 |
| SSH private-key path (`*.pem`) | `REDACTED-KEY.pem` | 7 | 7 |
| EC2 key-pair name | `REDACTED-KEYPAIR` | 6 | 6 |
| Subnet ID | `REDACTED-SUBNET-ID` | 1 | 1 |
| Security-group name | `REDACTED-SG-NAME` | 12 | 6 |
| Public IPv4 addresses of rig hosts | `REDACTED-PUBLIC-IP` | 17 | 7 |
| Absolute workstation paths | `$PROJECT` / `$HOME` | 1 | 1 |

**69 replacements across 25 files.**

## Verified absent after scrubbing

Re-scanned across the whole tree, all returning zero: the account ID, any
`arn:aws:` string, the IAM user name, the profile name, the key-pair name, any
real `*.pem` path, `subnet-<hex>` / `sg-<hex>` IDs, the security-group name,
absolute `/Users/...` paths, `AKIA`-form access keys, `aws_access_key` /
`aws_secret`, any `BEGIN ... PRIVATE KEY` block, and any public IPv4 literal.

No security-group **ID**, access key, secret, or private key material was present
in the sources in the first place; those categories were scanned for and found
absent rather than redacted.

## Deliberately kept

- **Private addresses `172.31.x.x`** — they appear throughout the logs and
  samplers, carry no information outside the rig's VPC, and removing them would
  make the multi-host logs unreadable. Explicitly permitted by the task.
- **`169.254.169.254`** — the EC2 instance metadata service. A universal
  well-known address that says nothing about this account.
- **Instance / volume / snapshot / AMI IDs** (`i-…`, `vol-…`, `snap-…`, `ami-…`).
  These are not in the task's redaction list and they are load-bearing for
  reading the run reports (which rig ran which campaign, which snapshot the
  artifacts were restored from). They are inert without the account ID, which is
  redacted. Recorded here as a conscious decision rather than an oversight.
- **Hostnames of the form `ip-172-31-x-x`** — derived from the private address.

## Post-scrub integrity check

Scrubbing edited script bodies, so the scripts were re-parsed afterwards:
**143 `.sh` files and 26 `.py` files all parse cleanly.** One scrubbing artifact
was found and fixed in this step: the key-path pattern initially consumed the `-`
of a `${VAR:-default}` parameter expansion in
`campaign-6-tenancy-fleet/scripts-as-run/52-v9b-registry.sh`, changing its shell
semantics. It was repaired and re-verified.

## Exclusions (not scrubbed — removed entirely)

See `README.md` § "What is not here" for the size-based exclusions and why.
No file was excluded *because* it could not be scrubbed cleanly; every excluded
file was excluded for size or redundancy.
