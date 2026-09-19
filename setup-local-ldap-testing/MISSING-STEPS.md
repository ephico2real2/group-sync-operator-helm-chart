# The steps the setup scripts do not cover

Measured against the running cluster on 2026-09-18 by diffing what is installed against what the seeds,
charts and scripts create. Each item below exists on the cluster and nothing in the repositories recreates
it, so a rebuild from the documented steps alone produces a cluster the tests and screenshots do not match.

## 1. The security-context grants

Two are load-bearing and only one is in a manifest.

| Grant | Where it is | Needed by |
|---|---|---|
| `RoleBinding ldap-testing/ldap-privileged-binding` → `system:openshift:scc:privileged`, subject `ServiceAccount ldap-testing/openldap-server` | in `01-ldap-server.yaml` | the openldap image runs as root and will not start under `restricted-v2` |
| `RoleBinding kyverno/system:openshift:scc:anyuid` → `system:openshift:scc:anyuid`, subjects the four kyverno controllers (`admission`, `background`, `cleanup`, `reports`) | **nowhere** — granted by hand after the chart install | the chart's pods are denied otherwise |

The kyverno one is the missing step:

```bash
oc adm policy add-scc-to-user anyuid -z kyverno-admission-controller  -n kyverno
oc adm policy add-scc-to-user anyuid -z kyverno-background-controller -n kyverno
oc adm policy add-scc-to-user anyuid -z kyverno-cleanup-controller    -n kyverno
oc adm policy add-scc-to-user anyuid -z kyverno-reports-controller    -n kyverno
```

Everything else with an SCC binding on this cluster is an OpenShift default (`restricted-v2` for
`system:authenticated`, `hostnetwork-v2` for the network node identity, `anyuid` for the machine-os
builder) and comes back with the cluster.

### Where Kyverno and its policies come from

The policies live in the `openshift-rbac-automation` repository, under `working-sessions/policies/` —
seven `kyverno-*.yaml` policies plus `vap-protect-kyverno-configuration.yaml`, a ValidatingAdmissionPolicy.
They are applied from that folder by hand; the chart at `charts/openshift-rbac-automation` renders none of
them, and its `templates/` directory contains no Kyverno resource.

Two points that folder records about itself, because they change what a rebuild should apply:

- `Chart.yaml` names `working-sessions/policies/kyverno-namespace-oud-group.yaml` as a follow-up
  "outside this chart". It is audit-only, so nothing blocks while it is missing.
- `values.yaml` records that `replace-operator-image-to-dockerhub` and `inject-dockerhub-secret` were
  **deliberately deleted** and replaced by the chart's image-override Job plus its `reconcile` CronJob.
  They are kept only as backups in `docs/local-testing/kyverno-backup/`. Re-applying either would fight
  the Job, mutating the Deployment back to `docker.io` at admission. Do not restore them.

The SCC grant above is a separate matter and is still in no manifest: searched the whole
`openshift-rbac-automation` repository for `anyuid`, `SecurityContextConstraints` and
`system:openshift:scc` and it holds none of them.

## 2. The six LDAP people and eighteen groups that no seed creates

The directory holds **84** entries; every `*.ldif` in `setup-local-ldap-testing/` together creates **65**.
The 25 unseeded ones were added by hand while the dashboard's features were built — and they are the ones
the tests, the seeds' expectations and every screenshot refer to:

```
uid=bob.wilson      uid=charlie.brown    uid=dana.lee
uid=jeff            uid=lateef.o         uid=sarah.jones
```

plus eighteen groups. `ldap-missing-from-seeds.ldif` in this folder creates all 25. Apply it after
`20-import-ldap-data.sh`:

```bash
oc exec -i -n ldap-testing deploy/openldap-server -- \
  ldapadd -x -D "cn=admin,dc=ephico2real,dc=com" -w "$LDAP_ADMIN_PASSWORD" < ldap-missing-from-seeds.ldif
```

It carries no `userPassword`: these are development accounts and the file is in git. Set the passwords the
way `20-import-ldap-data.sh` sets the seeded ones. `lateef.o` is the persona the self-tier screenshots are
taken as, and its password is not in any seed — that is a known gap recorded in the session memory.

## 3. The 52 manually created OpenShift users

The cluster holds 52 users whose identity provider is **not in the OAuth configuration at all**:
`ceo_rnd_oim` (49), `my-provider` (2), and one with no identity. They cannot be recreated by logging in,
because there is nothing to log in to — they are `User` and `Identity` objects written directly, which is
how a test population is made without standing up a provider for it. None of them holds any RBAC binding;
they exist to give the Users tab and the login-activity views a realistic population.

`manual-test-users.yaml` in this folder recreates 51 of them (the 52nd, `test-python-user`, carries a bare
UUID identity with no provider prefix and cannot be reconstructed from what the cluster reports). After
applying it the identities' back-references need repairing, because `Identity.user.uid` must match the uid
the API server assigns — the loop is in the file's header.

## 4. The two identity providers that ARE configured

`oc get oauth cluster` has exactly two, and both must exist before any of the above means anything:

| Name | Type | Detail |
|---|---|---|
| `developer` | HTPasswd | secret `htpass-secret` — this is how `kubeadmin` and `developer` log in |
| `ldap-local` | LDAP | `ldaps://openldap-service.ldap-testing.svc.cluster.local:636/`, bound as `cn=ocp-ldap-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com` |

`40-setup-oauth-ldap-login.sh` wires the second one; the first is the CRC default.

## 5. Order, with the gaps filled in

```
1  cert-manager operator (subscription openshift-cert-manager-operator, channel stable-v1)
2  setup-local-ldap-testing/ 01 → 02 → 03, then 15-bootstrap-cert-manager-ca.sh   (namespace, SCC, issuers)
3  20-import-ldap-data.sh                                                          (the 65 seeded entries)
4  ldapadd ldap-missing-from-seeds.ldif                                            ← MISSING STEP
5  set the passwords for the six added people                                      ← MISSING STEP
6  40-setup-oauth-ldap-login.sh                                                    (the ldap-local provider)
7  helm upgrade --install for nco, kyverno, group-sync, cert-manager-venafi        (values in ../values/)
8  the four kyverno anyuid grants                                                  ← MISSING STEP
9  oc apply -f manual-test-users.yaml, then the uid repair loop                    ← MISSING STEP
10 group-sync-dashboard via local-development/release-crc.sh (token session first)
11 90-verify-all-resources.sh
```
