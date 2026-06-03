# synthetic/ — Synthetic Workload Layer

Implements [`PROMPT.md`](../PROMPT.md) §13 — workloads, telemetry, security
signals, and cost-generating patterns layered on top of the platform.

This layer is **separate from `platform/` and `landing-zones/`** so it can be
applied, destroyed, or toggled independently without touching ALZ foundations.

---

## Kill switch

Every resource in this module is gated by `var.enable_synthetic_workload`.

| Value   | Behaviour                                                                 |
| ------- | ------------------------------------------------------------------------- |
| `false` | Plan shows zero resources. Existing synthetic resources are **destroyed** on apply. |
| `true`  | Plan/apply creates the full synthetic stack (§13.1–§13.4 once all parts ship). |

Toggle is held in `envs/poc.tfvars`. To tear the layer down without ceremony:

```bash
cd synthetic
terraform apply -var-file=../envs/poc.tfvars -var='enable_synthetic_workload=false'
```

PROMPT.md §13.6 acceptance criterion: this completes in <5 minutes.

---

## Section 13 ship status

| Subsection | Scope                                                | Status     |
| ---------- | ---------------------------------------------------- | ---------- |
| 13.1       | Workload targets (corp-a1 REST API, online-p1 queue) | 🟢 Done |
| 13.2       | k6 load generator (Container Apps Jobs)              | 🟢 Done |
| 13.3       | Red-team simulator ACI (security signals)            | ⬜ Next session |
| 13.4       | Cost-generating patterns                             | ⬜ Next session |
| 13.5       | Demo orchestration scripts                           | ⬜ Day 12 |
| 13.6       | Cost guardrails (sandbox budget, kill switch, weekly cleanup) | ⬜ Day 12 |
| 13.7       | Acceptance criteria validation                       | ⬜ Day 12 |

---

## 13.1 — Workload Targets (this commit)

### corp-a1: REST API stub

- Existing App Service from `landing-zones/corp-a1` is the runtime target.
- `synthetic/apps/corp-a1-api/` — zero-dependency Node 20 HTTP server.
- `terraform apply`:
  1. zips `apps/corp-a1-api/` via the `archive_file` data source,
  2. uploads it to a dedicated synthetic storage account,
  3. mints a 1h read-only container SAS,
  4. invokes `az webapp deploy --src-url <sas>` via a `null_resource` whose
     trigger is the zip md5 hash.

Endpoints exposed once deployed:

| Method | Path             | Behaviour                                                 |
| ------ | ---------------- | --------------------------------------------------------- |
| GET    | `/`              | Liveness JSON                                             |
| GET    | `/api/healthz`   | `{ ok, version, uptimeSeconds }`                          |
| GET    | `/api/products`  | Static catalog                                            |
| POST   | `/api/login`     | 200 for `demo/demo123`; 401 otherwise (drives §13.3 signal) |
| POST   | `/api/checkout`  | Echoes a mock `orderId`, totals the cart                  |

> **SQL is not wired yet.** The stub returns in-memory data. Hooking the
> existing private SQL DB requires App Service System-Assigned Managed
> Identity + Entra DB role grants; deferred to a §13.x refinement once the
> demo flow is locked in.

### corp-a2: cold standby

- No synthetic workload deployed today.
- The existing App Service / SQL / Recovery Services Vault from
  `landing-zones/corp-a2` remain the demo failover targets.
- ASR replication policy + corp-a1 SQL geo-replication land in §13.5 (demo
  orchestration) on Day 12.

### online-p1: contact-form queue

- Dedicated synthetic Storage Account hosts `contact-form-submissions` queue.
- Queue diagnostic settings stream to the Platform LA workspace so submissions
  surface in KQL.

> **Front-end HTML + Function code are out of scope for the infra layer.**
> The Static Web App ships from `landing-zones/online-p1`; the contact form
> page and its managed Azure Function are application artifacts deployed via a
> downstream CI step using `landing-zones/online-p1` output
> `static_web_app_api_key`.

---

## 13.2 — Load Generator

Three k6 scenarios on **Azure Container Apps Jobs** with cron triggers. The
Container Apps Environment uses the Consumption profile and ships container
stdout to the Platform LA workspace (`ContainerAppConsoleLogs_CL` table).

| Job           | Cron (UTC)        | Local (ET) target | VUs    | Duration | Replica timeout | CPU / RAM     |
| ------------- | ----------------- | ----------------- | ------ | -------- | --------------- | ------------- |
| `caj-k6-baseline-*`  | `0 14 * * 1-5`   | 09:00 weekdays    | ramp → 5    | 8h45m hold | 9h10m           | 0.25 vCPU / 0.5Gi |
| `caj-k6-spike-*`     | `0 17 * * 2,4`   | 12:00 Tue + Thu   | ramp → 50   | 15m total | 20m             | 1.0 vCPU / 2.0Gi |
| `caj-k6-anomalous-*` | `0 8 * * 0`      | 03:00 Sun         | ramp → 200  | 5m total  | 10m             | 1.0 vCPU / 2.0Gi |

Scripts live in `synthetic/k6/` and are uploaded as files to the `k6-scripts`
Azure File share on the existing corp-a1 synthetic storage account. Container
Apps mounts the share read-only at `/scripts` so each job runs
`k6 run /scripts/<scenario>.js`.

`TARGET_BASE_URL` env var is set to the corp-a1 App Service hostname (the
13.1 REST API stub), so the load lands on `/api/products`, `/api/login`,
`/api/checkout`.

The `anomalous` script biases 60% of requests into failed-login bursts with
`username=attacker-${VU}` + `x-test-geo: simulated-nonapproved-eu`, seeding
the §6 brute-force + blocked-country detection rules. Real cross-region
simulation belongs to §13.3.

> **Pre-req:** `var.platform_law_workspace_id` must be set when
> `var.enable_synthetic_workload = true`. Without it the §13.2 sub-section
> plans/applies zero resources (the Container Apps Environment needs the
> Log Analytics workspace ID to be created).

**Manual demo trigger:**

```bash
az containerapp job start \
  --resource-group rg-synthetic-corp-a1-<org>-<env> \
  --name caj-k6-anomalous-<org>-<env>
```

---

## Provider + module choices

| Concern              | Choice                       | Why                                        |
| -------------------- | ---------------------------- | ------------------------------------------ |
| Code zip build       | `hashicorp/archive` v2.7.x   | TF-native, no external build step          |
| App Service deploy   | `null_resource` → `az webapp deploy` | No first-class TF resource for "deploy zip to existing App Service" without taking over `app_settings`/`source_control` ownership |
| Storage              | Native `azurerm_storage_*`   | Consistent with `bootstrap/` and `landing-zones/corp-a1/dns_links.tf` |
| Provider versions    | Pinned to `~> 4.71.0` / `~> 2.7.0` / `~> 3.2.4` / `~> 3.8.1` | Same major lines used everywhere else      |

---

## Apply order

```
apply-management-groups
  ↓
apply-management
  ↓
apply-connectivity ── apply-security
  ↓
apply-corp-a1, apply-corp-a2, apply-online-p1   (parallel)
  ↓
apply-synthetic   ←  this module
```

CI: `.github/workflows/apply-on-merge.yml` job `apply-synthetic`.
Triggered on push to `main` touching `synthetic/**` or `envs/**`.

---

## Local apply

```bash
cd synthetic
terraform init \
  -backend-config=../envs/poc.backend.hcl \
  -backend-config=key=synthetic/terraform.tfstate

terraform apply \
  -var-file=../envs/poc.tfvars \
  -var-file=../envs/poc.secret.tfvars
```

Requires `az` CLI logged into the Landing Zones subscription (the
`null_resource` deploy step shells out to it).
