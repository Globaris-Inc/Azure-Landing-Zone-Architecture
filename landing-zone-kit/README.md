# Landing-Zone Build Kit

A reusable, battle-tested starting point for building an **Azure landing zone** (application *or* platform)
as Infrastructure-as-Code (Terraform + Azure Verified Modules, OIDC CI/CD). Distilled from a full AVD
landing-zone build that went all the way to a live, verified deployment — and back. **AVD (application LZ)
and the ALZ Hub & Spoke platform build that hosts this copy are the worked examples; this kit is the
generalized process.** It applies to the next LZ too (e.g. a security landing zone).

> The irreplaceable parts of this kit are the **[LESSONS](LESSONS.md)** (the things only a real `apply`
> teaches) and the **[decision framework](OPEN-QUESTIONS-template.md)** (the forks every LZ must answer).
> The code templates are valuable but replaceable; the lessons are not.

---

## What's in the kit

| File | What it gives you |
|------|-------------------|
| [README.md](README.md) | This — how to use the kit + order of operations |
| [LESSONS.md](LESSONS.md) | **The live-apply reality checklist** — the gotchas static review/`validate` can't catch, as pre-emptive guardrails |
| [OPEN-QUESTIONS-template.md](OPEN-QUESTIONS-template.md) | The recurring decision forks (identity, region, RBAC, state posture, gating…) with recommended defaults |

The **code templates** (the things you copy) are the proven repo artifacts themselves — see
The reusable artifacts are `bootstrap/`, `envs/`, `.github/workflows/`, `scripts/preflight.sh`,
`.githooks/pre-commit`.

---

## How to start a new landing zone with this kit

1. **Read [LESSONS.md](LESSONS.md) first.** It's a pre-flight checklist — most of these will apply
   verbatim to any Azure LZ, and pre-empting them saves you the failed-apply discovery loop we went through.
2. **Answer the [decision framework](OPEN-QUESTIONS-template.md)** with the project owner. Lock identity
   model, region, subscription/RG topology, RBAC scope, state-backend posture, and deploy gating *before*
   writing Terraform. Record each as an ADR.
3. **Copy the templates** and parameterize (names, the new workload
   token, the design areas). The CI workflows + state backend + review gate are largely generic — they
   carry over with minimal edits.
4. **Work the build under the process:** one section per session, **Architect → (Cloud
   Engineer | DevSecOps) → Code Reviewer** per change, the review gate enforced by hooks + `preflight.sh`.
5. **Bootstrap, then deploy via CI.** `bootstrap` once (creates the deterministic-named CMK state backend
   + OIDC), then `manual-deploy` (plan → apply, gated). `cleanup-demo` resets between demos.

## The roles (who does what)

| Role | Owns | Engage |
|------|------|--------|
| **Cloud Solutions Architect** | topology, identity/network model, module selection, ADRs, this kit | **first**, when an approach is ambiguous or has trade-offs |
| **Cloud Engineer** | `modules/`, the composition root, `bootstrap/` Terraform, `envs/*.tfvars`, local validation | to implement Terraform logic |
| **DevSecOps Engineer** | `.github/workflows/`, OIDC, state-backend specifics, `envs/*.backend.hcl`, `policies/`, posture | to implement the pipeline/security |
| **Code Reviewer** | correctness, AVM/version pinning, security, `preflight.sh` — the merge gate | **last**, before every commit |

Hand-off order per change: **Architect → Cloud Engineer _or_ DevSecOps (by domain; both in sequence if it
spans lanes) → Code Reviewer.**
