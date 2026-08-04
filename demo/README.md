# demo/ — Walkthrough Orchestration

Scripted walkthrough, manual incident triggers, and reset helpers for the
Azure Landing Zone POC. Implements [`PROMPT.md`](../PROMPT.md) §13.5.

| File | Purpose |
| ---- | ------- |
| `01-walkthrough.md`     | 15-min scripted narration with time-budgeted scenes |
| `02-failover-drill.sh`  | SQL Failover Group failover + secondary App Service surface (`--dry-run` / `--setup` / `--rollback`) |
| `03-trigger-incidents.sh` | Manually fire §13.2 k6 + §13.3 red-team CAJs on demand; prints pivot KQL |
| `04-reset.sh`           | Close open Sentinel incidents, re-disable honeypot, clean orphan PIPs |
| `05-screen-capture.md`  | OBS storyboard + post-production checklist for the recorded version |
| `06-acceptance.md`      | §13.7 acceptance criteria mapping (criterion → validation method → pass threshold) |
| `06-acceptance.sh`      | Runs all 5 acceptance criteria; exits non-zero on any fail (`--verbose` flag) |

## Prerequisites

Run **once** before the first demo:

1. `az login` and `az account set --subscription <Landing Zones sub ID>`.
2. `terraform apply -var-file=../envs/poc.tfvars -var='enable_synthetic_workload=true'`
   in `synthetic/`. Apply ≥24h before the demo so Defender / Advisor have
   the recommendation window.
3. Create the honeypot Entra user (Disabled) per [`../synthetic/README.md`](../synthetic/README.md) §13.3 pre-reqs.
4. `./02-failover-drill.sh --setup` to create the SQL Failover Group.

## Quick reference

```bash
# 5-second smoke
./03-trigger-incidents.sh list

# Default 3-shot incident burst
./03-trigger-incidents.sh

# Everything (slow — fires every scenario)
./03-trigger-incidents.sh all

# Dry-run DR drill
./02-failover-drill.sh --dry-run

# Real DR drill (corp-a1 → corp-a2)
./02-failover-drill.sh

# Fail back
./02-failover-drill.sh --rollback

# Reset after a demo
HONEYPOT_UPN=svc-honeypot@<tenant>.onmicrosoft.com ./04-reset.sh

# Acceptance criteria validation (assumes synthetic applied ≥24h ago)
LANDINGZONES_SUB_ID=<sub-guid> ./06-acceptance.sh
LANDINGZONES_SUB_ID=<sub-guid> ./06-acceptance.sh --verbose
```

## Environment overrides

All scripts honour these env vars:

| Var | Default | Notes |
| --- | ------- | ----- |
| `ORG_PREFIX`   | `globaris` | Matches the value in `envs/poc.tfvars` |
| `ENVIRONMENT`  | `poc`      | Matches `envs/poc.tfvars` |
| `HONEYPOT_UPN` | _(unset)_  | Required by `04-reset.sh` for the honeypot re-disable step |
| `SECURITY_RG`  | `rg-security-<org>-<env>` | Overrides the LAW lookup if naming differs |
| `SECURITY_LAW` | `law-security-<org>-<env>-r2` | Same; `-r2` is the ADR-075 generation suffix (tracks `security_law_generation` in `envs/poc.tfvars`) |

## Shell compatibility

`bash 4+` required (the trigger script uses associative arrays). Tested on:

- WSL Ubuntu 24.04
- macOS via Homebrew bash (`brew install bash`)
- Git for Windows' bash (with `az` 2.66+ on PATH)
