# Design: Custom GroupSync CRs (`customGroupSyncs`)

**Status:** Proposed — awaiting review before any template edit
**Audience:** Support engineers (junior-friendly) and chart maintainers
**Scope:** One new template + one values block + demo LDAP seed data. No change to how the
primary GroupSync works.

---

## 1. What we are building, in one sentence

Today the chart creates **one** `GroupSync` resource. This change lets you create **extra**
`GroupSync` resources — **one per team/tenant** — just by adding a short entry to
`values.yaml`. Nothing else changes.

## 2. Why we need it

We are a large organisation. Different teams own different LDAP group families, for example:

| Team / tenant | LDAP group names look like… |
|---|---|
| Apps platform (existing) | `app-ocp-rbac-*` |
| Big-Data Analytics | `bda-rbac-spark-alpha-apps`, `bda-rbac-trino-delta-users`, … (all start `bda-rbac-`) |
| Some future team | `xyz-ocp-rbac-*` |

Each family should sync **independently**: its own resource, its own schedule, its own
on/off switch. If one team's sync breaks, the others keep working, and a support engineer
can look at exactly one resource to troubleshoot it.

## 3. The one rule you must remember

> **One naming pattern = one GroupSync CR.**

Every `GroupSync` resource "claims" the groups it creates by stamping them with an
ownership label. The label value is built like this:

```text
<CR name>_<provider name>
```

Real example already running on the cluster:

| CR name | provider name | ownership label value |
|---|---|---|
| `ldap-groupsync` | `ldap` | `ldap-groupsync_ldap` |

**Why this matters:** a GroupSync will **not touch** a group that another GroupSync already
owns (it logs *"Group Provider Label Did Not Match"* and skips it). So two resources must
never match the **same** group.

We keep them apart the simple way: **each team uses a distinct name prefix**
(`app-ocp-rbac-*`, `bda-rbac-*`, `xyz-ocp-rbac-*`). These never overlap. The naming
standard is the guarantee — and it will be enforced automatically by **Kyverno** later.
The chart itself stays simple and does **not** try to police overlaps.

## 4. How you use it (the whole thing)

Add an `items` list under `customGroupSyncs`. Each item needs just **two** things: a unique
`name` and the group pattern (`groupCn`).

```yaml
customGroupSyncs:
  enabled: true          # master switch for all custom CRs
  items:
    - name: bda-rbac-groupsync    # becomes a GroupSync resource with this exact name
      enabled: true               # turn just this one on/off
      groupCn: "bda-rbac-*"       # which LDAP groups it syncs
    - name: xyz-ocp-rbac-groupsync
      enabled: true
      groupCn: "xyz-ocp-rbac-*"
```

That is the entire interface a support engineer needs to learn:

| Field | Meaning | Example |
|---|---|---|
| `customGroupSyncs.enabled` | Master on/off for **all** custom CRs | `true` |
| `items[].name` | The resource's name (must be unique) | `bda-rbac-groupsync` |
| `items[].enabled` | On/off for **this one** CR | `true` |
| `items[].groupCn` | The LDAP group name pattern to sync | `"bda-rbac-*"` |

### What you do NOT set (and why)

To keep it mistake-proof, everything else is filled in for you:

- **The LDAP filter.** You give a simple pattern `bda-rbac-*`; the chart builds the correct
  LDAP filter `(&(objectClass=groupOfNames)(cn=bda-rbac-*))`. You cannot break the filter
  syntax (unbalanced brackets are the #1 LDAP mistake).
- **The provider name.** Always `ldap` internally — you never type it, so it is never wrong.
- **The connection** (LDAP URL, credentials, CA, user query). These are the **same for the
  whole company**, so they are taken from the existing `groupSync` block. One place to set,
  one place to check when troubleshooting.

## 5. What actually gets created

With the example above and `customGroupSyncs.enabled: true`, Helm renders **two extra**
`GroupSync` resources next to the primary one:

```text
GroupSync/ldap-groupsync           (primary — unchanged)
GroupSync/bda-rbac-groupsync       (new — syncs cn=bda-rbac-*)
GroupSync/xyz-ocp-rbac-groupsync   (new — syncs cn=xyz-ocp-rbac-*)
```

Each new resource is a **complete, normal** GroupSync — if you run
`oc get groupsync bda-rbac-groupsync -o yaml` you see every field spelled out, nothing
hidden. The DRY-ness is only in the values file, not in the running resource.

## 6. How it is built (for maintainers)

Three small pieces. Nothing clever.

### 6.1 Shared template helper

The GroupSync "spec" body (providers, ldap, rfc2307 …) is identical for the primary and the
custom CRs. To avoid two copies drifting apart, it moves into **one** named template in
`templates/_helpers.tpl`:

```text
{{- define "group-sync-operator-helm.groupsyncSpec" -}}   # the shared spec body
```

- `templates/02-groupsync.yaml` (primary) calls this helper with the base `groupSync` values.
- `templates/custom-groupsync.yaml` (new) calls the **same** helper for each item, passing
  the item's `name` and its built filter, and inheriting the connection from `groupSync`.

**Safety check:** after the refactor we prove the primary resource is **byte-for-byte
identical** to before (see §7). If it changed at all, we stop.

### 6.2 The new template

`templates/custom-groupsync.yaml` — a plain loop, easy to read:

```text
{{- if .Values.customGroupSyncs.enabled }}
{{- range .Values.customGroupSyncs.items }}
{{- if .enabled }}
---
# render one GroupSync named {{ .name }}, filter cn={{ .groupCn }}
{{- end }}
{{- end }}
{{- end }}
```

### 6.3 The values block

The `customGroupSyncs` block from §4 is added to `values.yaml`, with comments and a default
of `enabled: false` for the master switch (safe default — off until a team opts in). The demo
values turn it on with the two example items.

## 7. How we prove it works (validation)

Run in order; each step must pass before the next.

| # | Check | Command | Pass = |
|---|---|---|---|
| 1 | Primary CR unchanged | render with helper vs backup, diff the `ldap-groupsync` object | zero differences |
| 2 | Chart is valid | `helm lint .` | 0 failed |
| 3 | Renders cleanly | `helm template . -n group-sync-operator` | 3 GroupSync objects, valid YAML |
| 4 | Filter is correct | inspect rendered `bda-rbac-groupsync` | `filter: "(&(objectClass=groupOfNames)(cn=bda-rbac-*))"` |
| 5 | Live sync works | `helm upgrade` on CRC, then `oc get groups -l ...` | `bda-rbac-*` groups appear, labelled `bda-rbac-groupsync_ldap` |
| 6 | No cross-claim | check operator logs | no *"Did Not Match"* warnings for `bda-rbac-*` |

## 8. Demo data (test LDAP)

So the new CR has something to sync, we seed the Big-Data groups into the test LDAP:

- **`setup-local-ldap-testing/ldap-bda-rbac-groups.ldif`** — 12 groups, covering the full
  family so the single `cn=bda-rbac-*` filter visibly catches all of them:

  ```text
  bda-rbac-{spark,trino}-{alpha,delta,theta}-{apps,users}
  ```

  (2 services × 3 environments × 2 kinds = 12 groups.) Imported at bootstrap by the existing
  `20-import-ldap-data.sh`.

- **`50-simulate-ldap-operations.sh`** — add a menu scenario `scenario_bda_onboarding` that
  creates these groups live, for demonstrating a real onboarding. It reuses the existing
  generic `add_rbac_group` function — no new group-creation logic.

## 9. Turning it off / rolling back

- **Disable one tenant:** set that item's `enabled: false` → its GroupSync is removed on the
  next `helm upgrade`; the other tenants are untouched.
- **Disable everything custom:** set `customGroupSyncs.enabled: false` → only the primary CR
  remains.
- **Revert the code entirely:** the pre-edit `templates/` snapshot lived in
  `templates-backup/`, which has since been removed — git history and the **`v0.2.0`** tag
  preserve it, so a working-tree copy was redundant. Recover a pre-refactor file with:

  ```bash
  git show v0.2.0:templates-backup/02-groupsync.yaml
  git checkout v0.2.0 -- templates-backup/        # or restore the whole folder
  ```

  Only three files actually differed from `templates/` at the time of removal —
  `02-groupsync.yaml`, `NOTES.txt` and `_helpers.tpl`; the other eleven were identical.

## 10. Glossary

| Term | Plain meaning |
|---|---|
| **GroupSync (CR)** | A resource that tells the operator "go to LDAP, find these groups, copy them into OpenShift". |
| **Provider** | One source inside a GroupSync. Here it is always LDAP. |
| **Ownership label** | A label the operator puts on each group it creates, so it knows which groups are "its own" to update or delete. Value = `<CR name>_<provider name>`. |
| **`groupCn`** | The group name pattern you want, e.g. `bda-rbac-*`. |
| **Filter** | The full LDAP query the chart builds from `groupCn`. You never write it by hand. |
| **Prune** | The operator deletes an OpenShift group it owns once that group disappears from LDAP. On per CR, and safe because each CR only owns its own pattern. |
| **Kyverno** | Policy engine (added later) that will enforce the naming standard so patterns never overlap. |

---

## Appendix A — Decisions locked during design review

| Decision | Choice | Reason |
|---|---|---|
| One filter with OR'd patterns, or one CR per pattern? | **One CR per pattern** | Simpler to read and troubleshoot; each tenant isolated. |
| Provider name field? | **Removed** — fixed to `ldap` internally | One less field to get wrong. |
| Input as raw LDAP filter or a glob? | **Glob `groupCn`** | Chart builds the filter; no bracket-syntax mistakes. |
| Connection config per item or inherited? | **Inherited** from base `groupSync` | Same LDAP for the whole org; one place to set and troubleshoot. |
| Guard against overlapping patterns in the chart? | **No** | Enforced by naming standard + Kyverno; keeps the chart simple. |
| Shared spec helper or duplicate template? | **Shared helper** | Avoids drift; proven byte-identical for the primary CR. |
