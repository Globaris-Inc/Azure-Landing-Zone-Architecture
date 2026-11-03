# 05-screen-capture.md — recording outline

> Storyboard / cue sheet for the pre-recorded version of `01-walkthrough.md`.
> Target run-time **15:00**, hard cap **18:00** before the §13.7 acceptance
> threshold is at risk.

---

## Pre-recording checklist

- [ ] Run `./03-trigger-incidents.sh red-team` ≥10 min before recording so
      Sentinel has fresh open incidents to point at on screen.
- [ ] Confirm `var.enable_synthetic_workload = true` has been applied ≥24h
      ago (Defender needs the window).
- [ ] Recording tool: **OBS Studio**, scene preset `globaris-poc-1080p`
      (1920×1080, 30 fps, hardware H.264, audio bitrate 192 kbps mono).
- [ ] Browser: dedicated Chrome profile `demo-globaris-poc`, all tabs from
      `01-walkthrough.md` pre-opened in the right order.
- [ ] Terminal: WSL Ubuntu, `cd ~/repos/Azure-Architecture/synthetic`,
      prompt set to a clean `▶ ` via `PS1='▶ '`.
- [ ] Mic test (-12 dB peak), camera off (this is a screen recording).
- [ ] Close Slack / Teams / Outlook notifications.

---

## Scene list

Each scene has a **target IN time**, **target OUT time**, the **window**
(active app), the **OSD overlay** for that scene, and the **operator
action** to drive while narrating.

### Scene 1 — Title card (00:00 → 00:15)

- Static title card: `Azure Landing Zone — Globaris POC`
- Subtitle: `Terraform + Azure Verified Modules · Sections 1–13`
- Overlay (lower-third): muted, name + role only.

### Scene 2 — Intro (00:15 → 00:45)

- Window: title card → fade to Azure Portal home.
- OSD: none.
- Action: hover over the subscription switcher; do not click.

### Scene 3 — Management Groups (00:45 → 02:00)

- Window: Azure Portal → Management Groups.
- OSD: `Section 2 · MG Hierarchy (avm-ptn-alz v0.19.1)`.
- Action: expand `contoso` → `platform` → `connectivity`. Hover over the
  Subscription column. Then collapse and switch to `landingzones` tree.

### Scene 4 — Hub-and-spoke + Private DNS (02:00 → 04:00)

- Window: Resource Visualizer on `vnet-hub-primary-...`.
- OSD: `Section 3 · DR Topology` then `Section 4 · Private DNS`.
- Action: pan the topology; hover over the firewall + the global VNet
  peering edge; right-click the spoke VNet and "Show subnets".

### Scene 5 — Conditional Access (04:00 → 05:30)

- Window: Entra → Conditional Access policies list.
- OSD: `Section 5 · Zero Trust · 8 policies report-only`.
- Action: sort by Created date so CA-001..CA-008 are visible. Click CA-005
  to show the named-location condition; do not edit.

### Scene 6 — Defender + Sentinel (05:30 → 08:00)

- Window: Defender for Cloud → Recommendations.
- OSD: `Section 6 · Defender plans + 10 Sentinel analytics rules`.
- Action: filter to `Resource type = App Service` to show idle/load
  recommendations. Then switch to **Sentinel → Incidents** and filter by
  `Tags has 'SecuritySimulation'`.

### Scene 7 — FinOps (08:00 → 09:30)

- Window: Cost Management → Cost analysis (Landing Zones sub).
- OSD: `Section 7 · Required-Tags + Budget · 200/mo/sub`.
- Action: switch the view to "Resource group" pivot; tag `Optimization=Candidate`
  filter; pause for 1s to let the bar settle.

### Scene 8 — Synthetic tour (09:30 → 12:30)

- Window: terminal pane.
- OSD: `Section 13 · Synthetic Workload (kill-switch on var.enable_synthetic_workload)`.
- Action:
  ```bash
  terraform output enabled
  terraform output k6_job_names
  terraform output red_team_job_names
  ./03-trigger-incidents.sh kv-probing
  ```
  Then alt-tab back to Sentinel Incidents and wait 2s for the count to
  refresh.

### Scene 9 — Kill switch (12:30 → 13:30)

- Window: terminal pane.
- OSD: `Kill switch · PROMPT §13.6 · <5 min teardown`.
- Action:
  ```bash
  terraform plan -var-file=../envs/poc.tfvars \
                 -var='enable_synthetic_workload=false' | tail -20
  ```
  Show the "Plan: 0 to add, 0 to change, N to destroy" summary line. Do not
  apply.

### Scene 10 — DR drill teaser (13:30 → 14:30)

- Window: terminal pane → split to Azure Portal SQL Server blade.
- OSD: `Section 9 + 13.5 · ./02-failover-drill.sh --dry-run`.
- Action: run with `--dry-run`. Cut to the SQL server blade showing
  geo-replication state.

### Scene 11 — Closing (14:30 → 15:00)

- Window: title card.
- OSD: `github.com/.../Azure-Landing-Zone-Architecture · README.md`.
- Action: hold static title for 5s, then fade.

---

## Post-production

- Add chapter markers at every scene boundary (10 chapters total).
- Captions on by default (auto-transcribe, hand-correct technical terms:
  ALZ, AVM, ROPC, UEBA, MDC, MITRE, PIM).
- Export master at `1920×1080 @ 30 fps, 8 Mbps H.264, AAC 192 kbps`.
- Generate three thumbnails (Scene 5 / Scene 6 / Scene 8) for socials.

---

## After-action checklist

- [ ] `./04-reset.sh` to close every incident the demo opened.
- [ ] `terraform output -raw oversized_vm_ssh_private_key_pem` rotated by
      re-applying — the ephemeral key in state ends with the recording.
- [ ] Recording uploaded to portfolio storage; link added to README hero
      section.
