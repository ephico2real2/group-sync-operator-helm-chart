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
| `app-ocp-rbac-group-groupsync` | `ldap` | `app-ocp-rbac-group-groupsync_ldap` |

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
| `items[].objectClass` | Which objectClass(es) the groups are. A **list** becomes an OR clause | `"groupOfNames"` (default) |
| `items[].groupMembershipAttributes` | Which attribute(s) hold the members | inherits `["member"]` |

`objectClass` and `groupMembershipAttributes` exist because **one directory routinely has both group
spellings**: `groupOfNames` with `member`, and `groupOfUniqueNames` with `uniqueMember`. On the
reference lab the `app-ocp-rbac-*` groups are the first and the OAuth login-gate group is the second.

**`groupMembershipAttributes` is the one that fails silently, and that is why it is a key rather than
something you are trusted to get right via `filter`.** A filter decides which groups are *found*; this
decides which members are *read*. Point a `groupOfUniqueNames` group at the inherited `["member"]` and
it syncs with **zero members** while reporting success — the CR is healthy, the Group object exists,
and it is empty.

Naming both attributes is safe **when at most one of them is populated** — the normal case, and the only
schema-valid one without a custom auxiliary class. Verified on the reference directory, whose gate group
is `groupOfUniqueNames`: `["member","uniqueMember"]` syncs all 8 members. Where both are genuinely
populated the operator concatenates and deduplicates nothing, so a member listed under both appears
twice. Full measurements in [LDAP_GROUP_FILTER_AND_MEMBERSHIP.md](LDAP_GROUP_FILTER_AND_MEMBERSHIP.md).

A single-item list renders without the `(|...)` wrapper, because `(|(objectClass=x))` is legal LDAP but
reads as a mistake to anyone auditing the CR.

### The OAuth login-gate group

`values.yaml` ships an item named `ldap-clusteraccess-groupsync`, **disabled**, for the group whose
membership an identity provider requires before anybody can authenticate:

```
ldaps://.../dc=example,dc=com?uid?sub?(&(uid=*)(memberOf=cn=<this group>,ou=Groups,...))
```

Nothing on the cluster can otherwise see who is allowed to log in — that group lives only in the
directory. Syncing it makes the membership a first-class OpenShift Group, which is what lets
group-sync-dashboard answer two questions it cannot otherwise: **who holds access they cannot use** (a
role granted to somebody the gate refuses), and **whether a refused login was a real person outside the
group or a username that does not exist** — the oauth log cannot separate those, because the filter
carries the group and both produce the same `no entries matching` line.

Shipped **disabled** deliberately, for the same reason `items` used to ship empty: `groupCn` names a
group that exists on the reference lab and nowhere else, so an enabled default would create a CR that
matches nothing, reports success, and looks configured. Enable it in your own values file — the lab does,
in `crc-values.yaml`.

It gets its **own CR** rather than a widened tenant pattern because the ownership label is
`<cr-name>_<provider-name>`: a separate CR keeps the gate group distinguishable from the RBAC groups
everywhere, and lets `prune` apply to it independently.

**The directory side is not free to change.** On the reference directory the `memberof` overlay is
configured for `uniqueMember` only — measured: a user who is a `member` of **17** `groupOfNames` groups
carries exactly **one** `memberOf` value, the gate group. So rewriting that group as `groupOfNames` "for
consistency" would produce no `memberOf`, match nobody, and **refuse every LDAP login**. Check yours
before changing it:

```bash
ldapsearch -x -H ldap://<host> -D "<bind>" -w "<pw>" -b "<gate group DN>" objectClass
```

### What you do NOT set (and why)

To keep it mistake-proof, everything else is filled in for you:

- **The LDAP filter.** You give a simple pattern `bda-rbac-*`; the chart builds the correct
  LDAP filter `(&(objectClass=groupOfNames)(cn=bda-rbac-*))`. You cannot break the filter
  syntax (unbalanced brackets are the #1 LDAP mistake). `objectClass` shapes what it builds;
  `filter` still overrides it wholesale for the rare case neither covers.
- **The provider name.** Always `ldap` internally — you never type it, so it is never wrong.
- **The connection** (LDAP URL, credentials, CA, user query). These are the **same for the
  whole company**, so they are taken from the existing `groupSync` block. One place to set,
  one place to check when troubleshooting.

## 5. What actually gets created

With the example above and `customGroupSyncs.enabled: true`, Helm renders **two extra**
`GroupSync` resources next to the primary one:

```text
GroupSync/app-ocp-rbac-group-groupsync           (primary — unchanged)
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

The `customGroupSyncs` block from §4 is added to `values.yaml`. Safety comes from an empty
`items` list rather than from the master switch: `enabled` ships `true` and `items` ships `[]`, so a
default install renders exactly one GroupSync CR — the primary — and every example item is commented out.

The switch is deliberately NOT `false` by default. It reads safer, but it creates a silent trap: anyone
who adds only `customGroupSyncs.items` to their own values file gets zero CRs and no error, because
`templates/custom-groupsync.yaml` wraps the whole range in `{{- if .Values.customGroupSyncs.enabled }}`.
An empty list cannot fail that way. Files that genuinely want the feature off — `sample-values.yaml` —
set `enabled: false` explicitly, which is the right place for an opt-out.

## 7. How we prove it works (validation)

Run in order; each step must pass before the next.

| # | Check | Command | Pass = |
|---|---|---|---|
| 1 | Primary CR unchanged | render with helper vs backup, diff the `app-ocp-rbac-group-groupsync` object | zero differences |
| 2 | Chart is valid | `helm lint ../charts/group-sync-operator-helm` | 0 failed |
| 3 | Renders cleanly | `helm template ../charts/group-sync-operator-helm -f ../charts/group-sync-operator-helm/crc-values.yaml -n group-sync-operator` | 2 GroupSync objects (`app-ocp-rbac-group-groupsync`, `bda-rbac-groupsync`), valid YAML. A values file is required: with `groupSync.url` empty the render fails closed by design. Under chart defaults the count is 1, since `items` ships empty |
| 4 | Filter is correct | inspect `bda-rbac-groupsync` in the row-3 render (it comes from `crc-values.yaml`, not the defaults) | `filter: "(&(objectClass=groupOfNames)(cn=bda-rbac-*))"` |
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
- **Revert the code entirely:** `git revert` the refactor commit; history has it.

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
