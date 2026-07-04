# Repository rulesets (source of record)

Version-controlled GitHub **repository rulesets**. These JSON files are the reviewable source of the repo's
branch-protection configuration — GitHub does **not** auto-apply a ruleset from a file in the repo, so
changing a file here does nothing until it is (re)imported.

## Files

| File | Applies to | Purpose |
|------|-----------|---------|
| `main-branch-protection.json` | default branch (`main`) | PR required (1 approval, dismiss-stale), no force-push / no deletion, required `validate.yml` status checks (`terraform fmt -check` + the 10 `validate — <root>` jobs). Repo admins may bypass. |

## Apply / update

**UI:** Settings → Rules → Rulesets → **New ruleset → Import a ruleset** → select the JSON.
To update an existing ruleset, edit it in the UI (the import always creates a new one), or re-create via API.

**API (create):**

```bash
gh api --method POST repos/Globaris-Inc/Azure-Architecture/rulesets \
  --input .github/rulesets/main-branch-protection.json
```

## Notes

- **Required status-check contexts must match the workflow job names byte-for-byte.** `validate.yml`
  renders its matrix job as `validate — <root>` with an **em dash** (`—`) — reproduced exactly here. Rename
  the jobs and this file must change in lock-step.
- **Scope:** this gates code merges into `main`, not the deploy apply run (deploys are `workflow_dispatch`,
  LESSON 17). The apply-run reviewer gate is tracked in `OPEN-QUESTIONS.md` (OQ-015).
- Full rationale: `docs/cicd-deploy-teardown.md` §7 "Branch protection (`main`) — repo ruleset".
