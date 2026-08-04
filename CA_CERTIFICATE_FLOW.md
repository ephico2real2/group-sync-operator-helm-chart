# CA Certificate Flow

There are **two** CA ConfigMaps, and confusing them is the single most common way to end up with an
operator that installs cleanly and never syncs. This document is the reference for which is which.

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
