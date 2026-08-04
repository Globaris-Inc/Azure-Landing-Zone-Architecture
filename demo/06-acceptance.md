# 06-acceptance.md — Section 13.7 acceptance criteria

> Companion to [`06-acceptance.sh`](06-acceptance.sh). PROMPT.md §13.7 lists
> five acceptance criteria for the synthetic layer; this document defines
> the validation method, the pass threshold, and the operator-facing
> command for each.

---

## Preconditions

Acceptance validation assumes the synthetic layer has been **applied with
`enable_synthetic_workload = true` for ≥24 hours**, so the §13.2 k6 +
§13.3 red-team CAJs have fired at least once on their crons, and Defender
+ Sentinel + Cost Management have had their respective ingestion windows.

Required env vars (with sensible defaults):

| Var | Default | Used by |
| --- | ------- | ------- |
| `ORG_PREFIX`   | `globaris` | All criteria — RG / LAW naming |
| `ENVIRONMENT`  | `poc`      | All criteria |
| `SECURITY_RG`  | `rg-security-${ORG_PREFIX}-${ENVIRONMENT}` | Criterion 1 |
| `SECURITY_LAW` | `law-security-${ORG_PREFIX}-${ENVIRONMENT}-r2` (ADR-075 generation suffix) | Criterion 1 |
| `LANDINGZONES_SUB_ID` | _(required)_ | Criteria 2, 3, 5 |

---

## Criterion 1 — Sentinel ≥ 5 distinct incident types in 24h

> **Source:** PROMPT.md §13.7 — "Sentinel ≥ 5 distinct incident types
> within 24 hours."

### Validation

```kql
SecurityIncident
| where TimeGenerated > ago(24h)
| where Status != "Closed" or ClosedTimeUTC > ago(24h)
| summarize distinct_types = dcount(Title) by tostring(AlertProductNames)
| summarize total_distinct = sum(distinct_types)
```

### Pass

`total_distinct >= 5`

### Operator command

```bash
az monitor log-analytics query \
  --workspace "$(az monitor log-analytics workspace show \
    --resource-group "$SECURITY_RG" --workspace-name "$SECURITY_LAW" \
    --query customerId -o tsv)" \
  --analytics-query 'SecurityIncident | where TimeGenerated > ago(24h) | summarize d = dcount(Title)' \
  --query 'tables[0].rows[0][0]' -o tsv
```

### What feeds this

- §13.3 `failed_signin_burst` → brute-force rule
- §13.3 `impossible_travel_{east,west}` paired runs → impossible-travel rule
- §13.3 `resource_anomaly` → AzureActivity-derived rule
- §13.3 `storage_anomaly` → Defender for Storage anomaly + KQL rule
- §13.3 `kv_probing` → KV bulk-secret-access rule
- §13.2 `k6_anomalous` (60% failed-login bias) → secondary brute-force signal

Five distinct rules + the MS-incident pass-through from Defender means we
should comfortably clear 5 distinct titles within 24h once all CAJs have
fired.

---

## Criterion 2 — Cost dashboard ≥ 3 distinct cost trends

> **Source:** PROMPT.md §13.7 — "Cost dashboard ≥ 3 distinct cost trends."

### Validation

`az consumption usage list` on the Landing Zones subscription for the
trailing 30 days, then count distinct `meterCategory` values. "Trend" is
interpreted as "service category showing recurring spend" — VM compute,
managed disks, storage, container apps, key vault, automation, etc.

### Pass

`distinct_meter_categories >= 3`

### Operator command

```bash
az consumption usage list \
  --subscription "$LANDINGZONES_SUB_ID" \
  --top 1000 \
  --start-date "$(date -u -d '-30 days' +%Y-%m-%d)" \
  --end-date "$(date -u +%Y-%m-%d)" \
  --query 'length([].meterCategory | sort(@) | unique(@))'
```

### What feeds this

- §13.4 oversized VM → "Virtual Machines" + "Standard SSD Managed Disks"
- §13.4 unattached PSSD → "Premium SSD Managed Disks"
- §13.4 hot-tier SA + §13.1 + §13.3 SAs → "Storage"
- §13.2 + §13.3 Container Apps Jobs → "Container Apps"
- §13.6 Automation runbooks → "Automation"
- §13.3 decoy KV → "Key Vault"

Six+ distinct categories are expected; threshold of 3 is the floor.

---

## Criterion 3 — Defender ≥ 10 active recommendations, ≥ 3 auto-remediable

> **Source:** PROMPT.md §13.7 — "Defender for Cloud ≥ 10 active
> recommendations across synthetic resources, ≥ 3 auto-remediable."

### Validation

`az security assessment list` filtered to `status.code = "Unhealthy"` and
sub-filtered to assessments whose `additionalData.subAssessmentDescription`
or `metadata.remediationDescription` indicates auto-remediation (the
`remediationDescription` field is populated; `quickFix` policy maps to
"Microsoft.Security.QuickFix"-prefixed types).

### Pass

`active_count >= 10` **and** `auto_remediable_count >= 3`

### Operator command

```bash
# Active recommendations across the subscription
az security assessment list \
  --subscription "$LANDINGZONES_SUB_ID" \
  --query "length([?status.code=='Unhealthy'])"

# Subset that carries a remediationDescription (auto-remediable proxy)
az security assessment list \
  --subscription "$LANDINGZONES_SUB_ID" \
  --query "length([?status.code=='Unhealthy' && metadata.remediationDescription!=null])"
```

### What feeds this

- §13.4 oversized VM → "right-size or shutdown" + "enable just-in-time
  access" + "install monitoring agent" + "encrypt OS disk"
- §13.4 unattached PSSD → "delete unattached disk"
- §13.4 hot-tier SA → "lifecycle management not configured" + "secure
  transfer required" + "enable soft delete"
- §13.3 decoy SA + KV → various Defender for Storage / Key Vault
  recommendations
- §13.3 red-team CAJ MIs → "minimize privileged accounts"

Defender produces 12–20 recommendations on the synthetic layer alone once
the 24h evaluation window completes.

---

## Criterion 4 — Walkthrough script executes end-to-end < 20 min

> **Source:** PROMPT.md §13.7 — "Walkthrough script executes end-to-end
> < 20 min."

### Validation

Manual — operator stopwatches a full pass through [`01-walkthrough.md`](01-walkthrough.md).

### Pass

`elapsed < 20:00` from Scene 1 start to Scene 10 end.

### Documentation evidence

`01-walkthrough.md` is **time-budgeted at 15:00 total** across 10 scenes
with hard caps per scene. The script's preamble lists the prerequisite
tab order so the operator does not lose time hunting menus mid-recording.
`05-screen-capture.md` carries the OBS storyboard with IN/OUT timecodes
that match the same 15-minute budget.

The acceptance runner emits this as **`PASS (by design — see
01-walkthrough.md time budget)`** without timing a live execution. A
recorded run is the only fully objective evidence; operator should attach
the recording to a release artifact.

---

## Criterion 5 — Disabling flag returns env to clean platform state

> **Source:** PROMPT.md §13.7 — "Disabling flag returns env to clean
> platform state."

### Validation

Run `terraform plan -var='enable_synthetic_workload=false'` in
`synthetic/`. Parse the summary line for:

- `Plan: A to add, C to change, D to destroy.`

### Pass

`A == 0 and C == 0 and D > 0`

(zero adds, zero changes, positive destroys — the entire synthetic layer
is queued for teardown without re-creating anything.)

### Operator command

```bash
cd synthetic
terraform plan -var-file=../envs/poc.tfvars \
               -var='enable_synthetic_workload=false' \
               -no-color \
  | tail -5 \
  | grep -E 'Plan: [0-9]+ to add, [0-9]+ to change, [0-9]+ to destroy'
```

### What this proves

- Every synthetic resource was created behind a `count = local.enabled`
  (or sub-gate equivalent) — no orphan-with-no-gate.
- Tearing the layer down is genuinely declarative — no manual cleanup
  required for the kill switch.

---

## Running the suite

```bash
cd demo
LANDINGZONES_SUB_ID="$(az account show --query id -o tsv)" ./06-acceptance.sh

# Verbose mode prints the raw query JSON for each criterion
./06-acceptance.sh --verbose
```

Exit code:

- `0` — all criteria PASS
- `1` — at least one criterion FAILED
- `2` — preflight failure (missing CLI, not logged in, missing required env var)

---

## When this is expected to FAIL gracefully

| Scenario | Expected behaviour |
| -------- | ------------------ |
| Synthetic layer applied < 24h ago | Criteria 1 + 3 likely FAIL (ingestion + evaluation windows) — operator re-runs in 24h |
| `enable_synthetic_workload = false` | Criteria 1, 2 (mostly), 3 FAIL by design; criterion 5 PASSES with `Plan: 0 to add, 0 to change, 0 to destroy` (whole layer already empty) |
| Honeypot Entra user not yet created | Criterion 1 still passes — k6_anomalous + 3 non-signin red-team scenarios cover ≥4 distinct titles; need at least the storage_anomaly or kv_probing to push to 5 |
| Recently re-applied (decoy resources < 1h old) | Criterion 3 may show 7–9 recs instead of 10 — Defender re-scans every ~24h |
