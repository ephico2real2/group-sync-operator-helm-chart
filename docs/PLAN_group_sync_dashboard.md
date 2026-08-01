# Plan: multi-cluster GroupSync dashboard

**Status:** planning — no implementation. Decision doc for review.
**Goal:** a containerized web app that shows, across several OpenShift clusters, what
GroupSync is doing: which CRs exist, when each last synced, which groups they produced, and
whether anything is silently broken.

Read-only. It observes; it does not create or edit GroupSync CRs.

---

## 1. Why this is worth building

Everything this dashboard would surface has, in the course of one session on a single
cluster, been the thing that went wrong:

| Failure | How it presents today |
|---|---|
| Group referenced by a RoleBinding but absent | nothing — binding looks healthy, grants nobody |
| Group synced but empty | nothing — `oc get groups` shows a blank USERS column |
| Group in LDAP but filtered out by the CR | nothing — no object is ever created |
| CR not honouring its schedule | nothing until you diff timestamps by hand |

None of these raise an event or a failed reconcile. They are all *absences*, and absences are
exactly what a human scanning `oc get` output does not notice. That is the case for a
dashboard rather than a runbook.

## 2. The constraint that shapes the design

**A GroupSync CR carries only `.status.lastSyncSuccessTime` — a single timestamp. There is
no sync history in the API.**

So a timeline cannot be read from the cluster on demand; it has to be *accumulated*. Two
sources, and the tradeoff drives the storage decision:

| Source | Gives | Costs |
|---|---|---|
| `.status.lastSyncSuccessTime` | last success only | trivial to poll; history must be built by storing successive observations |
| operator log, `manager` container | every sync, with `Groups Created or Updated` counts | lost on pod restart, needs `pods/log` RBAC, timestamps are **epoch floats** not RFC3339, and the pod's *default* container is `kube-rbac-proxy` which logs nothing useful |

**Decision needed:** poll-and-store (simple, durable, loses detail between polls) versus
log-scrape (richer, fragile, more RBAC). Recommend poll-and-store as the primary, with log
scrape as an optional per-cluster enrichment.

## 3. What to read from each cluster

```
GroupSync         .spec.schedule, .spec.providers[].ldap.rfc2307.groupsQuery.filter
                  .status.lastSyncSuccessTime, .metadata.generation
Group             .metadata.name, .users[], .metadata.labels
```

**The join key is a label.** Groups synced by the operator carry:

```
group-sync-operator.redhat-cop.io/sync-provider: <groupsync-name>_<provider>
```

e.g. `bda-rbac-groupsync_ldap`. That is what attributes a Group to the CR that created it —
without it there is no way to answer "which groups did this CR produce?" and the dashboard
would be reduced to two unrelated lists.

Optional, for the RoleBinding view (§7): `RoleBinding` / `ClusterRoleBinding` subjects of
`kind: Group`.

## 4. RBAC — one read-only ServiceAccount per cluster

```yaml
kind: ClusterRole
rules:
  - apiGroups: ["redhatcop.redhat.io"]
    resources: ["groupsyncs"]
    verbs: ["get", "list"]
  - apiGroups: ["user.openshift.io"]
    resources: ["groups"]
    verbs: ["get", "list"]
  # only if the RoleBinding view is enabled
  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: ["rolebindings", "clusterrolebindings"]
    verbs: ["get", "list"]
  # only if log-scrape enrichment is enabled
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list"]
```

No `watch` — see §6. No write verbs anywhere.

> Worth checking per cluster before assuming: on this cluster the Kyverno **admission**
> controller could not read `groups.user.openshift.io` while the **background** controller
> could. Do not assume a ServiceAccount can read Groups just because it can read core
> resources.

## 5. Multi-cluster connection model

One record per cluster, each independently credentialed:

```yaml
clusters:
  - name: crc-local
    apiUrl: https://api.crc.testing:6443
    tokenSecretRef: gsd-token-crc-local     # Secret in the dashboard's namespace
    caBundleRef: gsd-ca-crc-local           # optional; else system trust
    insecureSkipVerify: false               # dev only
    enrichment:
      operatorLogs: false
```

Tokens live in Secrets mounted into the backend, never in the config object and never
returned by the API. A cluster with a bad or expired token must render as a **degraded card,
not a page-level error** — one unreachable cluster should not blank the dashboard.

Bootstrapping a cluster is then:

```bash
oc create sa group-sync-dashboard -n group-sync-operator
oc adm policy add-cluster-role-to-user group-sync-reader -z group-sync-dashboard -n group-sync-operator
oc create token group-sync-dashboard -n group-sync-operator --duration=8760h
```

**Token lifetime is the main operational question.** Bound tokens expire; the dashboard needs
either long-lived tokens (simpler, worse security posture) or a refresh story. Flag rather
than decide here.

## 6. Polling, not watching

Sync events are at most hourly. A `watch` per cluster means N persistent connections,
reconnect handling, and relist storms on restart — for data that changes on a cron.

**Poll every 60s** per cluster. That is 60× finer than the fastest schedule seen in practice
and cheap: two list calls per cluster per minute.

Store an observation row each time `lastSyncSuccessTime` **changes** — not every poll — so
the timeline is sync events rather than a poll log.

## 7. Views

**Cluster overview** — one card per cluster: reachable?, CR count, group count, oldest
`lastSyncSuccessTime`, count of groups that are empty or unattributed.

**GroupSync detail** — per CR: schedule, filter, last sync, *next expected* sync (computed
from the cron expression — this is what makes "overdue" detectable), sync timeline, and the
groups it owns.

**Group explorer** — every group with member count and owning CR. Filterable to the two
states that are otherwise invisible:

- `EMPTY` — synced, zero members
- `UNATTRIBUTED` — no `sync-provider` label, so not operator-managed

**Binding health** (optional, needs the RBAC above) — RoleBindings and ClusterRoleBindings
whose `kind: Group` subject does not resolve to an existing Group. This is the highest-value
view and the one nothing in OpenShift provides today.

## 8. Alert conditions worth computing

- **Overdue:** `now - lastSyncSuccessTime > 2 × schedule interval` → the schedule stopped firing
- **Empty group:** synced with zero members → LDAP-side problem, e.g. a `member:` DN that
  does not resolve
- **Dangling binding:** a binding references a Group that does not exist
- **Group count cliff:** a sync where the group count drops sharply → filter or LDAP change
- **Newly unattributed:** a Group lost its `sync-provider` label

The first three each correspond to a real failure observed on this cluster.

## 9. Shape

```
frontend (SPA)  ──►  backend API  ──►  cluster A  (token A)
                          │        ──►  cluster B  (token B)
                          ▼
                     store (observations)
```

- **Backend:** one service, fans out per cluster, owns polling and the store. Language open;
  Go gives real client-go typing, Python/FastAPI gives faster iteration.
- **Frontend:** SPA against the backend only. Never holds a cluster token.
- **Store:** SQLite is sufficient for observation rows at this volume; Postgres if the
  dashboard itself needs HA.

## 10. Storage schema

Three tables. `clusters` is config; the other two are the accumulated observations that the
API cannot give us (§2).

```sql
-- configured clusters (token lives in a Secret, never here)
cluster(
  id, name, api_url, token_secret_ref, ca_bundle_ref,
  insecure_skip_verify, enrichment_operator_logs, enabled
)

-- one row per OBSERVED sync, written only when lastSyncSuccessTime CHANGES
sync_event(
  id, cluster_id, groupsync_name, groupsync_namespace,
  synced_at,            -- .status.lastSyncSuccessTime, the operator's own timestamp
  observed_at,          -- when our poll saw it; observed_at - synced_at = our lag, not the operator's
  schedule,             -- snapshot: schedules change, and old rows must stay interpretable
  group_count,          -- groups carrying this CR's sync-provider label at observation time
  UNIQUE(cluster_id, groupsync_name, synced_at)
)

-- current group state, replaced each poll; history not kept
group_state(
  cluster_id, name, member_count, sync_provider, observed_at,
  PRIMARY KEY(cluster_id, name)
)
```

Two deliberate choices:

**`synced_at` and `observed_at` are separate.** The first is the operator's; the second is
ours. Conflating them would attribute our polling lag to the operator. With a 60s poll,
`observed_at - synced_at` should stay under a minute — if it grows, the *dashboard* is
behind, which is a different problem from a sync being late.

**`schedule` is snapshotted per event.** Schedules change — this session moved one from
`*/2` to `*/30` mid-flight. Without the snapshot, historical rows get re-interpreted against
today's cron and every pre-change event looks overdue.

The `UNIQUE` constraint makes the poll loop idempotent: re-observing the same
`lastSyncSuccessTime` is a no-op, so polling faster than the schedule costs nothing.

## 11. API surface

All read-only. No endpoint returns a token or accepts one from the browser.

```
GET  /api/clusters                        id, name, reachable, last_poll, error
GET  /api/clusters/{id}/groupsyncs        schedule, filter, last_sync, next_expected, state
GET  /api/clusters/{id}/groupsyncs/{n}/events?since=   the accumulated timeline
GET  /api/clusters/{id}/groups?state=empty|unattributed|all
GET  /api/clusters/{id}/bindings/dangling  optional, needs the extra RBAC in §4
GET  /api/alerts                          computed, across all clusters
GET  /healthz  /readyz
```

`state` on a groupsync is computed, not stored:

```
ok        now - last_sync  <=  1 interval
late      now - last_sync   >  1 interval
overdue   now - last_sync   >  2 intervals      -> alert
unknown   cluster unreachable, or no sync observed yet
```

**`next_expected` needs a real cron parser**, not arithmetic on the interval. `0 * * * *`
and `*/30 * * * *` both "fire hourly" if you only measure gaps from the last event — the
difference only shows at `:30`, which is exactly the ambiguity that made the first pass of
the schedule test inconclusive. Use a library (`croniter`, `robfig/cron`); do not hand-roll.

## 12. Poll loop

Per cluster, every 60s, independently — one slow or unreachable cluster must not stall the
others:

```
1. list GroupSync            -> spec.schedule, spec.providers[].ldap...filter,
                                status.lastSyncSuccessTime
2. list Group                -> name, users[], sync-provider label
3. attribute groups to CRs via the label   (verified: 58/58 attributed, 0 orphans)
4. for each CR: if lastSyncSuccessTime differs from the newest stored sync_event,
   insert one row (schedule + group_count snapshotted)
5. replace group_state for this cluster
6. record poll outcome: ok | auth_failed | unreachable | forbidden
```

Step 6 matters more than it looks. **`forbidden` must be distinguishable from `unreachable`**
— a ServiceAccount that can list GroupSync but not Group produces a half-populated view that
otherwise looks like a cluster with no groups. Surface it as a degraded card naming the
missing permission, not as an empty result.

## 13. Open questions

1. **Token lifetime and rotation** — long-lived tokens, or a refresh mechanism?
2. **Retention** — how long to keep observations? Sync events are small; a year is probably
   fine.
3. **Where does it run** — on one of the observed clusters, or standalone? Standalone avoids
   a cluster being unable to report its own outage.
4. **Auth on the dashboard itself** — it aggregates group membership across clusters, which
   is sensitive. OIDC in front, or is it internal-only?
5. **Log-scrape enrichment** — worth the extra RBAC and fragility for per-sync group counts,
   or is poll-and-store enough?

## 14. Suggested first slice

Cluster overview + GroupSync detail against **one** cluster, poll-and-store, no log scrape,
no binding view. That proves the connection model and the timeline-accumulation design — the
two things most likely to be wrong — before any multi-cluster or enrichment work.
