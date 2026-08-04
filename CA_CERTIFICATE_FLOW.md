# CA Certificate Flow

The operator reads **one** CA — whatever `groupSync.ca` names. There are three ways to get one there,
and confusing them is the most common way to end up with an operator that installs cleanly and never
syncs. This document is the reference.

## Three ways in

| | Enable with | Who populates it | Key | Use when |
|---|---|---|---|---|
| **1. Copy** *(default)* | `oauthSecretExtraction.caCopy.enabled: true` | the extraction Job, from `sourceCa` | `ca.crt` | the cluster already has the CA for its OAuth LDAP identity provider |
| **2. Injected** | `trustedCA.injected.enabled: true` | OpenShift's network operator | `ca-bundle.crt` | the LDAP server's CA is already in `proxy/cluster.spec.trustedCA` |
| **3. Existing** | both of the above `false` | you, out of band | yours | a CA the cluster has never been told about |

All three end at the same place, so `groupSync.ca` is the constant:

```
1. openshift-config/ca-config-map ──Job copies──▶ ┐
2. empty ConfigMap ──OpenShift fills──▶           ├──▶ groupSync.ca ──▶ operator
3. a ConfigMap you created ──────────────────────▶ ┘
```

Whichever you pick, the extraction Job preflights it — exists, has the key, key is PEM — so a
misconfiguration surfaces at install time rather than as an endless reconcile loop.

### 2. Injected — and its one hard limit

The chart creates an **empty** ConfigMap labelled `config.openshift.io/inject-trusted-cabundle: "true"`
(a **label**, not an annotation). OpenShift's network operator fills `ca-bundle.crt` with the system
trust store merged with `proxy/cluster.spec.trustedCA`. Measured on a stock cluster: **148 certificates,
226KB**. Nothing to maintain, no copy step, and rotation is the cluster's problem rather than yours.

**It carries only CAs the cluster already trusts.** In most enterprises that is exactly where the
corporate root already lives, which makes this the least-effort mode: nothing to copy, nothing to
rotate, and it covers every namespace at once. Check what your cluster has:

```bash
oc get proxy cluster -o jsonpath='{.spec.trustedCA.name}{"\n"}'
```

- **Non-empty** — the corporate root is in the bundle. An LDAP server signed by it verifies with no
  further setup. Enable injection and you are done.
- **Empty** — the bundle is public roots only, so an internal LDAP server fails with
  `x509: certificate signed by unknown authority`. Either publish the root to the proxy (below) or use
  mode 1 or 3.

### Publishing a root to the cluster trust bundle

Only needed on a cluster that does not already have one — a lab, or CRC. `proxy.spec.trustedCA`
requires the key **`ca-bundle.crt`**, not `ca.crt`:

```bash
oc create configmap ldap-enterprise-ca-bundle -n openshift-config \
  --from-file=ca-bundle.crt=/path/to/root.pem
oc patch proxy cluster --type=merge \
  -p '{"spec":{"trustedCA":{"name":"ldap-enterprise-ca-bundle"}}}'
```

For the local cert-manager PKI, the bootstrap script does both, with a backup and a guard that refuses
to replace a `trustedCA` the cluster already has:

```bash
setup-local-ldap-testing/15-bootstrap-cert-manager-ca.sh trust-cluster
setup-local-ldap-testing/15-bootstrap-cert-manager-ca.sh untrust-cluster   # to undo
```

### What it costs: expect a MachineConfig rollout

Two things happen, on different timescales.

**The merge is immediate and API-level.** `oc explain proxy.spec.trustedCA` describes it: a *proxy
validator* reads `ca-bundle.crt`, merges it with the system trust store, and writes
`openshift-config-managed/trusted-ca-bundle`. On CRC that completed in seconds, and every labelled
ConfigMap had the new bundle right after.

**Then the Machine Config Operator rolls the pool**, because the trust bundle also belongs on the
nodes. Measured on single-node CRC:

| | Observed |
|---|---|
| New MachineConfigs rendered | yes — new `rendered-master-*` and `rendered-worker-*` |
| Pool `Updating` | ~105 seconds |
| Node `Ready` condition | **transitioned** during the roll |
| Pool `Degraded` | no |

So there is a brief disruption. Whether it is a full reboot or a kubelet restart could not be
distinguished without a before-and-after `bootID`, and the node kept reporting `Ready` at 15-second
sampling — but its `Ready` `lastTransitionTime` moved, so something restarted. **Plan for a node roll**,
and on a multi-node cluster expect MCO to work through the pool one node at a time, cordoning and
draining as it goes. This is not a change to make casually on a busy cluster.

None of this applies on a cluster that already has a `trustedCA` — that root is already in the bundle
and no proxy change is needed, which is the normal enterprise case.

Observed end to end on CRC once the roll finished: the merged bundle went from 148 to **149**
certificates with the local root present, the chart's empty ConfigMap was filled with all 149, and the
operator completed a sync over `ldaps://`.

Set the key to `ca-bundle.crt`, not `ca.crt`:

```yaml
trustedCA:
  injected:
    enabled: true
    name: ldap-trusted-ca
oauthSecretExtraction:
  caCopy:
    enabled: false        # nothing to copy
groupSync:
  ca:
    kind: ConfigMap
    name: ldap-trusted-ca
    namespace: group-sync-operator
    key: ca-bundle.crt    # fixed by the injector
```

Under ArgoCD the ConfigMap carries `ServerSideApply=true` so the network operator keeps ownership of
what it wrote. That is **not sufficient alone** — the Application also needs an `ignoreDifferences`
entry for this ConfigMap's `data`, which the chart cannot set. Without both, Argo reverts it to empty on
every sync and verification breaks until the operator refills it.

### 3. Existing — no flag, and nothing is templated

Turn both off and point `groupSync.ca` at a ConfigMap you created:

```bash
oc create configmap enterprise-ldap-ca \
  --from-file=ca.crt=/path/to/root.pem -n group-sync-operator
```

The certificate is deliberately **not** templated from values: anything in `values.yaml` ends up in
git, in `helm get values`, and in every CI log that echoes it. RBAC follows the name you set, and the
preflight validates it like any other.

---

The rest of this document covers **mode 1**, the default, where the two-ConfigMap distinction matters.

## The two ConfigMaps

```
   openshift-config/ca-config-map                group-sync-operator/ca-config-map-copy
   ───────────────────────────────               ──────────────────────────────────────
   THE SOURCE                                    THE COPY
   you create it, or the cluster                 the chart's extraction Job creates it
   already has it for its OAuth
   LDAP identity provider                        THIS is what the operator loads
                                    ─copy──▶     groupSync.ca points HERE
```

| | Source | Copy |
|---|---|---|
| Default name | `ca-config-map` | `ca-config-map-copy` |
| Namespace | `openshift-config` | `group-sync-operator` |
| Created by | you, or already present for the OAuth IdP | the extraction Job, on every install and upgrade |
| Configured as | `oauthSecretExtraction.caCopy.sourceCa` | `oauthSecretExtraction.caCopy.destinationCa` |
| Read by | the extraction Job | **the operator** |
| Safe to hand-edit | yes | **no** — overwritten on the next upgrade, which is why it is named `-copy` |

`groupSync.ca` must name the **copy**. If it names the source, the Job logs a warning and the operator
goes back to needing cross-namespace access.

## Why a copy at all

Reading `openshift-config` from the operator's namespace needs cross-namespace ConfigMap read. Some
clusters grant the operator's ServiceAccount that; others do not. Where it is denied, the only symptom
is the operator reconciling forever on:

```
ConfigMap ... not found, caSecret must be specified when insecure=false
```

which names neither the namespace nor the missing permission. The copy removes the dependency
entirely, so the same values work on both kinds of cluster.

Verify which kind you have:

```bash
SA=system:serviceaccount:group-sync-operator:controller-manager
oc auth can-i get configmaps/ca-config-map -n openshift-config --as=$SA
```

`yes` means either arrangement would work. `no` means the copy is the only one that does.

## When a CA is needed at all

The chart emits the CA block — and runs the copy — only when one is actually required:

| `url` | `insecure` | CA required | Why |
|---|---|---|---|
| `ldaps://` | `false` | **yes** | verified TLS |
| `ldaps://` | `true` | **yes** | implicit TLS completes the handshake before any LDAP traffic, so the client must already trust the CA. `insecure` only relaxes checks the operator makes itself — it cannot make a handshake trust an unknown root |
| `ldap://` | `false` | **yes** | verification is on |
| `ldap://` | `true` | no | nothing is encrypted; no CA path renders at all |

That last row is the only one where none of this applies. It is also the row where the bind password
crosses the network in the clear.

## Creating the source

Skip this if the cluster already has an OAuth LDAP identity provider — it already has the ConfigMap,
and the chart discovers its name from the OAuth CR.

```bash
# Get the CA that signed your LDAP server's certificate
openssl s_client -connect ldap.example.com:636 -showcerts </dev/null 2>/dev/null | \
  openssl x509 -outform PEM > ldap-ca.crt

# Create the SOURCE. The key must be ca.crt.
oc create configmap ca-config-map --from-file=ca.crt=./ldap-ca.crt -n openshift-config
```

For a local test directory, `setup-local-ldap-testing/15-bootstrap-cert-manager-ca.sh apply` builds a
cert-manager PKI and writes the source for you.

## How the copy is made

The extraction Job (`templates/01.5-oauth-secret-extraction-job.yaml`) runs as a
`post-install,post-upgrade` hook and:

1. **Discovers the source name** from the cluster OAuth CR's first LDAP identity provider, rather than
   trusting `sourceCa.name`. Only the name — the OpenShift API fixes the namespace to
   `openshift-config` and the key to `ca.crt`. Falls back to the configured name when there is no LDAP
   identity provider, and logs which providers it did find.
2. **Preflights it**: exists, has the expected key, and the key is PEM. A missing CA is not an install
   failure otherwise — the operator would just loop.
3. **Copies it** to the destination, stamped with provenance:

```bash
oc get configmap ca-config-map-copy -n group-sync-operator -o jsonpath='{.metadata.annotations}' | jq
```

```
group-sync.redhat-cop.io/source      = openshift-config/ca-config-map
group-sync.redhat-cop.io/source-key  = ca.crt
group-sync.redhat-cop.io/source-hash = 726db17a651d238b
```

### Rotation

The same hash is stamped on the Job's pod template as `checksum/ca-source`. A changed source produces
a different hash, which changes the pod spec, so the next `helm upgrade` re-runs the Job and rebuilds
the copy. Nothing rotates it without an upgrade.

The hash is computed with Helm's `lookup`, which reads the live cluster — so `helm template` and
offline GitOps renders show `unavailable`. The annotation on the copy is the reliable record of what
was actually read.

## Verifying

Three different questions, three different checks.

**Is the source right?**

```bash
oc extract configmap/ca-config-map -n openshift-config --keys=ca.crt --to=- | \
  openssl x509 -noout -subject -issuer -dates
```

**Does the copy match the source?**

```bash
diff <(oc extract configmap/ca-config-map -n openshift-config --keys=ca.crt --to=-) \
     <(oc extract configmap/ca-config-map-copy -n group-sync-operator --keys=ca.crt --to=-) \
  && echo "in sync"
```

If they differ, the source changed and no upgrade has run since.

**Does the CA the operator loads actually verify the LDAP endpoint?** This is the one that matters, and
it is what `helm test` checks — from inside the cluster, against the Service DNS name, because a SAN
mismatch only shows up there:

```bash
helm test group-sync -n group-sync-operator --logs
```

```
✅ CA read: 1 certificate(s)
✅ chain verifies against group-sync-operator/ca-config-map-copy, hostname matches ldap.example.com
```

`oc extract` is used rather than `jsonpath` throughout: the key contains a dot, and jsonpath treats it
as a path separator — both `{.data.ca.crt}` and `{.data['ca.crt']}` return **empty** on a ConfigMap
that has the key. Only `{.data['ca\.crt']}` works, so `oc extract` is safer.

## Troubleshooting

**`ConfigMap ... not found, caSecret must be specified when insecure=false`**

The operator cannot read what `groupSync.ca` names. Either it points at `openshift-config` on a cluster
that denies the read, or the copy was never created. Check the Job:

```bash
oc logs -n group-sync-operator job/group-sync-operator-oauth-secret-extraction | grep -E '🔎|CA'
```

**`caSecret must be specified` even though the resource exists**

`groupSync.ca.field` is set to `ca` rather than `caSecret`. The CRD carries both and marks `caSecret`
deprecated, but operator validation checks `caSecret`.

**`x509: certificate signed by unknown authority`**

The CA is readable but did not sign the server's certificate. Compare issuers:

```bash
oc extract configmap/ca-config-map-copy -n group-sync-operator --keys=ca.crt --to=- | \
  openssl x509 -noout -subject
echo | openssl s_client -connect ldap.example.com:636 2>/dev/null | openssl x509 -noout -issuer
```

**`certificate is valid for X, not Y`**

A SAN mismatch. The certificate was issued for a different name than the one in `groupSync.url`.
Either reissue for that name or use the name it was issued for.

**The copy is stale**

Only an upgrade rebuilds it. `helm upgrade group-sync . -n group-sync-operator` — and if the values
also need resetting, see the `--reset-values` note in the README's Upgrade Notes.
