# Group Sync Operator Helm Chart

> **⚠️ IMPORTANT: OPENSHIFT ONLY**
>
> This Helm chart is designed **exclusively for OpenShift clusters**. It will not work on standard Kubernetes clusters as it depends on:
>
> - OpenShift Operator Lifecycle Manager (OLM)
> - OpenShift's catalog sources and OperatorHub
> - OpenShift-specific APIs

This Helm chart deploys the Group Sync Operator and configures LDAP group synchronization in OpenShift environments.

## Quick start

```bash
helm repo add group-sync-operator https://ephico2real2.github.io/group-sync-operator-helm-chart
helm repo update
helm search repo group-sync-operator-helm
```

Then install with a values file for your cluster. `groupSync.url`, `oauthSecretExtraction.bindDN` and
`sourceSecret.name` are **empty** in the chart defaults — supply them, or leave them out and they are
read from the cluster's OAuth LDAP identity provider at install time:

```bash
helm install group-sync group-sync-operator/group-sync-operator-helm \
  -n group-sync-operator --create-namespace \
  -f my-cluster-values.yaml

helm test group-sync -n group-sync-operator --logs
```

A minimal `my-cluster-values.yaml` for a directory the cluster does **not** authenticate against:

```yaml
groupSync:
  url: "ldaps://ldap.example.com:636"
oauthSecretExtraction:
  bindDN: "cn=svc-bind,ou=TrustedApplications,dc=example,dc=com"
  sourceSecret:
    name: ldap-secret          # in openshift-config, key bindPassword
```

Working examples live in the chart: `crc-values.yaml` (LDAPS with the CA copied),
`crc-injected-values.yaml` (LDAPS via OpenShift trusted-CA injection) and
`environments/ldap-plain-values.yaml` (plain LDAP, no cert-manager). See
[CA_CERTIFICATE_FLOW.md](CA_CERTIFICATE_FLOW.md) for how the CA reaches the operator, and
[setup-local-ldap-testing/](setup-local-ldap-testing/) to stand up a test directory.



## Install ordering, and why `helm install` used to fail

A single `helm install` on a cluster without the operator failed like this:

```
Error: INSTALLATION FAILED: unable to build kubernetes objects from release manifest:
  resource mapping not found for name: "ldap-groupsync" ... no matches for kind "GroupSync"
  in version "redhatcop.redhat.io/v1alpha1"  ensure CRDs are installed first
```

**Helm resolves every kind in the release against API discovery to build its object list, and
that happens before it runs any hook, at any weight.** So neither hook weights nor
`argocd.argoproj.io/sync-wave` can fix it — the annotations are read long after the failure.
Measured on a live cluster:

| Attempt | Result |
|---|---|
| CR as a `post-install` hook, weight 99 | fails — `unable to build kubernetes object for deleting hook` |
| CR as a normal resource with `sync-wave: 3` | fails — `unable to build kubernetes objects from release manifest` |
| CRD on a `pre-install` hook, weight −10 | fails, **and the hook never runs** — the build fails first |
| CRD in `crds/` | **works** |

That is why `crds/groupsyncs.redhatcop.redhat.io.yaml` exists. Helm installs everything in
`crds/` before it renders templates, which is early enough. Four properties were verified before
adopting it:

- on a cluster that already has the CRD from OLM, Helm **skips** it and leaves `olm.managed=true` intact
- `helm uninstall` never deletes anything in `crds/`, so removing the release cannot cascade-delete a GroupSync CR
- plain `helm template` does **not** emit `crds/` — measured: 0 CustomResourceDefinition objects

#### ArgoCD does see `crds/` — set `skipCrds: true`

An earlier version of this section claimed ArgoCD never sees the file. That is wrong, and it is worth
correcting rather than deleting, because the conclusion drawn from it was the opposite of the truth.

ArgoCD renders Helm sources with `helm template --include-crds`, which **does** emit `crds/`:

```
$ helm template r charts/group-sync-operator-helm --set groupSync.url=ldaps://x:636
0 CustomResourceDefinition objects
$ helm template r charts/group-sync-operator-helm --set groupSync.url=ldaps://x:636 --include-crds
1 CustomResourceDefinition object
```

So under ArgoCD the vendored CRD **is** part of the Application: Argo applies it, takes management of
it, can prune it if it ever leaves the source, and can contend with OLM — which owns the same CRD
through the Subscription and CSV — over its contents. Exactly the risk the old wording said did not
exist.

Set `skipCrds` on the Application so `crds/` stays a `helm install` mechanism only, and let OLM
remain the single owner under GitOps. `argocd-application.yaml` in this repo now sets it:

```yaml
spec:
  source:
    helm:
      skipCrds: true
```

⚠️ **Adding `skipCrds` to an Application that is already running without it needs care.** The CRD
leaves the rendered source, and this Application has `prune: true` — a resource that leaves the
source gets pruned. Deleting the GroupSync CRD **cascades to every GroupSync CR on the cluster**.

Before changing an existing Application, check whether Argo is managing the CRD:

```bash
oc get crd groupsyncs.redhatcop.redhat.io \
  -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}{"\n"}'
```

Empty means Argo never took it (OLM installed it first) and setting `skipCrds` changes nothing about
its lifecycle. Non-empty means Argo owns it — annotate it `argocd.argoproj.io/sync-options: Prune=false`
first, or sync with pruning disabled, and confirm the CRD survives before re-enabling automated prune.

Not verified on a live cluster: this cluster runs no ArgoCD (`openshift-gitops` is not installed), so
the prune behaviour above is from ArgoCD's documented semantics, not measured here. What *was* measured
is the part that matters for the fix — `--include-crds` emits the file, plain `helm template` does not.

The trade-off, stated plainly: it is a vendored copy of an OLM-owned CRD, and Helm never updates
`crds/` on upgrade. If the operator ships a new CRD version, refresh the file. OLM remains
authoritative at runtime — it adopts and patches this copy on operator install.

### The namespace

Pass `--create-namespace`. ArgoCD does not need it — the Application sets `CreateNamespace=true`.

`templates/00-namespace.yaml` is **off by default** and is not a helm hook. As a `pre-install` hook
it deleted a pre-existing namespace and everything in it, because Helm's default hook-delete-policy
is `before-hook-creation` and no policy value means "never delete". Measured behaviour of the
alternatives:

| Namespace template | Namespace state | Result |
|---|---|---|
| `pre-install` hook | already exists | **deleted, with its contents** |
| `pre-install` hook | absent, no `--create-namespace` | fails: `namespaces "X" not found` |
| plain resource | already exists | fails safely: Helm refuses to adopt it |
| plain resource | absent + `--create-namespace` | fails: `namespaces "X" already exists` |

So it is enabled only for a GitOps tool that applies the rendered manifest where the namespace is
absent. Everything else uses `--create-namespace` or `CreateNamespace=true`.

If a namespace is mid-deletion every create against it is rejected, and the install fails until it
finishes. What is holding it:

```bash
oc get ns group-sync-operator -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'
```

Usually a non-Available APIService or a resource with a finalizer.

### The wait Jobs

Fixing the build error leaves a second failure: an install that reports success while nothing is
reconciling. Helm orders unknown kinds last, sorted by kind name, and `GroupSync` sorts before
`Subscription` — so the CR can be created before the operator is even subscribed, then sit
unprocessed while `helm install` exits 0. Under Argo, a Subscription reports Healthy before its
operator pod is running. Either way the symptom is an absence: no Groups appear and nothing errors.

| Job | When | What it blocks on |
|---|---|---|
| `installplan-approver` | wave 1, only when `subscription.installPlanApproval: Manual` | the Subscription's InstallPlan is approved and reaches `Complete` |
| `operator-wait` | wave 2 | the CSV is `Succeeded`, the operator Deployment has a ready replica, and the CRD is `Established` |

Both carry `argocd.argoproj.io/hook: Sync` so Argo runs them inside the sync at their wave — early
enough to gate the CRs in wave 3 — and `helm.sh/hook` so plain `helm install` waits for them at
all: a Job in the main manifest is created and not waited on unless `--wait` is passed. Both
fast-path to `exit 0` when the cluster is already ready, so a re-sync costs one round of API calls.

The approver is scoped to this chart's subscription and **refuses** an InstallPlan that does not
name it, so a chart install can never push through an upgrade an admin deliberately staged for
some other operator.


## Overview

The chart deploys these main components:
1. Group Sync Operator (via OLM subscription)
2. Operator Group configuration
3. A primary GroupSync Custom Resource for LDAP synchronization
4. Optional **additional GroupSync CRs — one per team/tenant** — driven from
   `customGroupSyncs` in `values.yaml` (see
   [Multi-Tenant GroupSync](#multi-tenant-groupsync-customgroupsyncs) and
   [docs/DESIGN_custom_groupsync.md](docs/DESIGN_custom_groupsync.md))

## Prerequisites

- **OpenShift 4.x cluster** (Required - this chart does not work on standard Kubernetes)
- Helm 3.x
- Access to OpenShift's catalog sources (specifically community-operators in openshift-marketplace)
- OLM must be installed and functioning
- LDAP server details and credentials
- CA certificate for LDAPS connection

## Detailed CA Certificate Setup

> **📄 Full reference: [CA_CERTIFICATE_FLOW.md](CA_CERTIFICATE_FLOW.md)** — which ConfigMap is which,
> when a CA is required, rotation, verification and troubleshooting.

**There are two CA ConfigMaps and this section describes only the first.** The one you create below is
the **source**, in `openshift-config`. The operator does **not** read it. The chart's extraction Job
copies it to `ca-config-map-copy` in the operator's own namespace, and that copy is what `groupSync.ca`
names and what the operator loads.

```
openshift-config/ca-config-map  ──copy──▶  group-sync-operator/ca-config-map-copy  ──▶  operator
   (you create this)                            (the Job creates this)
```

The copy exists because reading `openshift-config` from the operator's namespace needs cross-namespace
ConfigMap read, which some clusters grant and others deny — and where it is denied the only symptom is
the operator reconciling forever on `ConfigMap ... not found`. Skip creating the source entirely if the
cluster already has an OAuth LDAP identity provider: it already has the ConfigMap, and the chart
discovers its name from the OAuth CR.

### Obtaining the CA Certificate

You need to obtain the CA certificate that signed your LDAP server's certificate. This can be:

1. Exported from your organization's Certificate Authority
2. Extracted from your LDAP server configuration
3. Obtained from your security team

```bash
# Example: Extract CA certificate from an LDAP server (if accessible)
openssl s_client -connect ldap.example.com:636 -showcerts </dev/null 2>/dev/null | \
  openssl x509 -outform PEM > ldap-ca.crt
```

### Creating the ConfigMap (the source)

```bash
# The SOURCE, in openshift-config. The key must be ca.crt.
oc create configmap ca-config-map \
  --from-file=ca.crt=./ldap-ca.crt \
  -n openshift-config
```

Nothing further is needed: the extraction Job discovers this ConfigMap, preflights it, and copies it
into the operator's namespace on every install and upgrade. To confirm the copy landed:

```bash
oc get configmap ca-config-map-copy -n group-sync-operator \
  -o jsonpath='{.metadata.annotations.group-sync\.redhat-cop\.io/source-hash}{"\n"}'
```

### Verifying the CA Certificate

Two different questions. This checks the **source** file, from wherever you are:

```bash
openssl s_client -connect ldap.example.com:636 -CAfile ldap-ca.crt
```

`Verify return code: 0 (ok)` means the CA signed the server's certificate.

But the question that matters is whether **the CA the operator loads** verifies the endpoint **from
inside the cluster** — a SAN mismatch only surfaces there, because it depends on the name the operator
connects to. That is what `helm test` checks:

```bash
helm test group-sync -n group-sync-operator --logs
```

```
✅ CA read: 1 certificate(s)
✅ chain verifies against group-sync-operator/ca-config-map-copy, hostname matches ldap.example.com
```

See [CA_CERTIFICATE_FLOW.md](CA_CERTIFICATE_FLOW.md#verifying) for checking the source and copy are in
sync, and for the common failures.

## LDAP Configuration Guide

This section provides detailed guidance on configuring the GroupSync Operator for different LDAP environments.

### LDAP Server Requirements

- LDAP server must be accessible from the OpenShift cluster
- LDAP server should support LDAPS (LDAP over SSL/TLS) on port 636
- The server must allow search operations on the configured BaseDN
- The bind account must have sufficient read permissions

### LDAP Authentication

The operator requires a bind account to authenticate with the LDAP server:

```bash
# Create the LDAP credentials secret
oc create secret generic ldap-group-sync \
  --from-literal=bindDN='cn=serviceaccount,ou=serviceaccounts,dc=example,dc=com' \
  --from-literal=bindPassword='YOUR_SECURE_PASSWORD' \
  -n group-sync-operator
```

### LDAP Schema Configuration

The chart supports RFC2307 schema. Here are examples for common LDAP servers:

#### Active Directory Example

```yaml
groupSync:
  rfc2307:
    usersQuery:
      baseDN: "dc=example,dc=com"
      filter: "(objectClass=user)"
    groupsQuery:
      baseDN: "ou=Groups,dc=example,dc=com"
      filter: "(&(objectClass=group)(cn=app-ocp-rbac-*))"
    groupNameAttributes:
      - cn
    groupUIDAttribute: objectGUID
    groupMembershipAttributes:
      - member
    userNameAttributes:
      - sAMAccountName
    userUIDAttribute: objectGUID
```

#### OpenLDAP Example

```yaml
groupSync:
  rfc2307:
    usersQuery:
      baseDN: "ou=People,dc=example,dc=com"
    groupsQuery:
      baseDN: "ou=Groups,dc=example,dc=com"
      filter: "(&(objectClass=groupOfNames)(cn=app-ocp-rbac-*))"
    groupNameAttributes:
      - cn
    groupUIDAttribute: entryUUID
    groupMembershipAttributes:
      - member
    userNameAttributes:
      - uid
    userUIDAttribute: entryUUID
```

### Testing LDAP Queries

Before deploying, test your LDAP queries to ensure they return the expected results:

```bash
# Install ldapsearch if needed
# For RHEL/Fedora: dnf install openldap-clients
# For Ubuntu/Debian: apt-get install ldap-utils

# Test LDAP search
ldapsearch -H ldaps://ldap.example.com:636 \
  -D "cn=serviceaccount,ou=serviceaccounts,dc=example,dc=com" \
  -w "YOUR_SECURE_PASSWORD" \
  -b "ou=Groups,dc=example,dc=com" \
  -s sub \
  "(&(objectClass=groupOfNames)(cn=app-ocp-rbac-*))" \
  -Z -LLL
```

## Security Best Practices

Follow these security best practices to ensure secure deployment and operation of the GroupSync Operator.

### Credentials Management

- **Regularly rotate LDAP bind credentials**:

  ```bash
  # Update the LDAP credentials secret
  oc create secret generic ldap-group-sync \
    --from-literal=bindDN='cn=serviceaccount,ou=serviceaccounts,dc=example,dc=com' \
    --from-literal=bindPassword='NEW_SECURE_PASSWORD' \
    -n group-sync-operator \
    --dry-run=client -o yaml | oc replace -f -
  ```

- **Use a dedicated service account** with minimal permissions in your LDAP directory
- **Store secrets securely** and limit access to the namespace containing credentials

### Network Security

- Ensure LDAPS (port 636) is used rather than unencrypted LDAP
- Consider using a Service Mesh for enhanced traffic security

### Operational Security

- Review sync logs regularly for unauthorized access attempts
- Implement role-based access control (RBAC) for the group-sync-operator namespace
- Monitor GroupSync Custom Resource for unauthorized changes

## Maintenance and Operations

This section covers the ongoing maintenance and operational tasks for the GroupSync Operator.

### Monitoring Sync Operations

Monitor the GroupSync operation using the following commands:

```bash
# Check GroupSync status
oc get groupsync -n group-sync-operator -o yaml

# View recent sync activity
oc logs -n group-sync-operator deployment/group-sync-operator-controller-manager -c manager --tail=100

# Monitor real-time sync activity (watch for automatic syncs)
kubectl logs -n group-sync-operator deployment/group-sync-operator-controller-manager -c manager --tail=5 -f

# Alternative using oc command
oc logs -n group-sync-operator deployment/group-sync-operator-controller-manager -c manager --tail=5 -f
```

**What to look for in the logs:**
- `"Beginning Sync"` - Indicates sync operation has started
- `"Groups Created or Updated"` - Shows number of groups synchronized
- `"Groups Pruned"` - Shows number of groups removed
- `"Sync Completed Successfully"` - Confirms successful synchronization
- Any error messages indicating authentication or connection issues

### Manual Sync Triggering

To trigger an immediate sync without waiting for the scheduled time:

```bash
# Trigger immediate sync
kubectl annotate groupsync ldap-groupsync -n group-sync-operator sync.redhatcop.redhat.io/sync-now="$(date)" --overwrite

# Using oc command
oc annotate groupsync ldap-groupsync -n group-sync-operator sync.redhatcop.redhat.io/sync-now="$(date)" --overwrite

# Check if sync happened (verify completion)
kubectl get groupsync ldap-groupsync -n group-sync-operator -o yaml | grep lastSyncSuccessTime

# Count synced RBAC groups
kubectl get groups | grep -c app-ocp-rbac

# Check recent operator logs
kubectl logs -n group-sync-operator deployment/group-sync-operator-controller-manager -c manager --tail=5

# List sample synced groups
kubectl get groups | grep app-ocp-rbac | head -10

# Alternative commands using oc
oc get groupsync ldap-groupsync -n group-sync-operator -o yaml | grep lastSyncSuccessTime
oc get groups | grep -c app-ocp-rbac
oc logs -n group-sync-operator deployment/group-sync-operator-controller-manager -c manager --tail=5
oc get groups | grep app-ocp-rbac | head -10
```

**Verification Command Explanations:**
- **Check sync completion**: Displays the timestamp of the last successful sync
- **Count groups**: Returns the total number of synced RBAC groups (should match your LDAP groups)
- **Check logs**: Shows recent sync activity and any error messages
- **List groups**: Displays sample synced groups with their user memberships

### Testing with Test Pods

The chart includes optional test pods that can validate your installation and LDAP connectivity:

```yaml
# In your values.yaml file
test:
  enabled: true
  # ose-cli, pinned. The tests need oc to read the CA and the sync status, and curl to verify the
  # LDAPS chain. NOT openssl — it is absent from current ose-cli builds and present in some older
  # ones, so a floating tag made the same chart pass on one cluster and fail on another.
  ldapClientImage:
    repository: "registry.redhat.io/openshift4/ose-cli"
    tag: "v4.14"
    pullPolicy: IfNotPresent
  # Seconds the sync check waits for a first successful sync before failing.
  syncWaitSeconds: 180
```

The tests are **Pods**, not Jobs, so `helm test --logs` works — it looks up a pod named after the
hook itself, and a Job's pods are `<job>-<suffix>`.

To run the tests after enabling them:

```bash
# Run the helm tests
helm test <release-name> -n group-sync-operator
```

The tests will verify:
1. The GroupSync operator and custom resource are properly installed
2. LDAP connectivity is working correctly with the specified filter

### Adjusting Sync Schedule

The schedule uses standard cron format and is set in `values.yaml`.

> **Note:** the shipped default is `*/30 * * * *` (**every 30 minutes**), which is a
> reasonable production cadence — group membership rarely changes faster than that.
> For demo work you may want it quicker so changes appear while you watch; see the
> examples below.

```yaml
# In your values.yaml file
groupSync:
  # Shipped default:
  schedule: "*/30 * * * *"   # every 30 minutes

  # Faster, for demo/testing only:
  # schedule: "*/2 * * * *"   # every 2 minutes — aggressive on the LDAP server

  # Other production examples (pick one):
  # schedule: "*/15 * * * *"  # every 15 minutes
  # schedule: "0 * * * *"     # hourly
  # schedule: "0 */4 * * *"   # every 4 hours
```

Custom (per-tenant) CRs inherit this schedule; override any single tenant with a
`schedule:` field on its item under `customGroupSyncs.items` (see
[Multi-Tenant GroupSync](#multi-tenant-groupsync-customgroupsyncs)).

```bash
# Apply the updated schedule
helm upgrade group-sync group-sync-operator/group-sync-operator-helm \
  -n group-sync-operator -f values.yaml
```

You do not have to wait for the schedule — patching any annotation triggers an
immediate reconcile (see [Manual Sync Triggering](#manual-sync-triggering)).

## Multi-Tenant GroupSync (`customGroupSyncs`)

Large organisations often have several LDAP group families owned by different teams
(for example `app-ocp-rbac-*`, `bda-rbac-*`, `xyz-ocp-rbac-*`). This chart can generate
**one GroupSync CR per team/tenant** so each family syncs independently — its own
resource, schedule, and on/off switch. If one tenant's sync breaks, the others keep
working, and a support engineer troubleshoots exactly one resource.

**The one rule:** one naming pattern = one CR, and patterns must not overlap. Overlap is
prevented by your organisation's naming standard (enforced by Kyverno later), **not** by
the chart.

### Usage

Add an `items` list under `customGroupSyncs`. Each item needs only a unique `name` and
the group pattern (`groupCn`):

```yaml
customGroupSyncs:
  enabled: true          # master switch for ALL custom CRs
  items:
    - name: bda-rbac-groupsync    # becomes a GroupSync resource with this name
      enabled: true               # on/off for just this one
      groupCn: "bda-rbac-*"       # LDAP group pattern to sync
    - name: xyz-ocp-rbac-groupsync
      enabled: true
      groupCn: "xyz-ocp-rbac-*"
```

Everything else is filled in for you to keep it mistake-proof:

- **The LDAP filter** is built from `groupCn` → `(&(objectClass=groupOfNames)(cn=<groupCn>))`,
  so you cannot break the filter syntax.
- **The provider name** is always `ldap` (you never type it).
- **The connection** (URL, credentials, CA, user query) is inherited from the `groupSync`
  block — one place to set, one place to troubleshoot.

Optional per-item overrides (rarely needed): `schedule`, `namespace`, or a raw `filter`
for advanced LDAP queries.

Full design, validation steps, and glossary:
[docs/DESIGN_custom_groupsync.md](docs/DESIGN_custom_groupsync.md).

### Verifying a custom CR

```bash
# The custom CR exists alongside the primary one
oc get groupsync -n group-sync-operator

# Its groups are synced and owned by that CR (label <cr-name>_ldap)
oc get groups -l group-sync-operator.redhat-cop.io/sync-provider=bda-rbac-groupsync_ldap
```

### Upgrading the Operator

When upgrading to a new version of the Group Sync Operator:

1. Check the [operator changelog](https://github.com/redhat-cop/group-sync-operator) for breaking changes
2. Update the chart version in your deployment
3. Perform a dry-run upgrade before applying changes

```bash
# Perform a dry-run upgrade
helm upgrade group-sync group-sync-operator/group-sync-operator-helm \
  -n group-sync-operator --dry-run
```

### Backup and Recovery

Back up your GroupSync configuration regularly:

```bash
# Backup GroupSync configuration
oc get groupsync -n group-sync-operator -o yaml > groupsync-backup.yaml

# Backup LDAP credentials (encrypted)
oc get secret ldap-group-sync -n group-sync-operator -o yaml > ldap-credentials-backup.yaml
```

## Installation

```bash
# Create namespace
oc create namespace group-sync-operator

# Create LDAP credentials secret
oc create secret generic ldap-group-sync \
  --from-literal=bindDN='YOUR_BIND_DN' \
  --from-literal=bindPassword='YOUR_BIND_PASSWORD' \
  -n group-sync-operator

# Install the chart
helm install group-sync group-sync-operator/group-sync-operator-helm \
  -n group-sync-operator --create-namespace
```

## Configuration

The following tables list the configurable parameters and their default values.

### GroupSync Configuration

> **Note:** the shipped `values.yaml` is a **fast-track demo/testing** configuration —
> an in-cluster test LDAP over plain `ldap://`, a `*/2` schedule, and `insecure: true`.
> Re-point these at your real LDAP (and use `ldaps://` + a CA) for production.

| Parameter | Description | Default (demo) |
|-----------|-------------|---------|
| groupSync.name | Name of the primary GroupSync resource | ldap-groupsync |
| groupSync.namespace | Target namespace | group-sync-operator |
| groupSync.schedule | Sync schedule (cron format) | "*/30 * * * *" |
| groupSync.providerName | LDAP provider name | ldap |
| groupSync.insecure | `false` verifies the chain. A CA is required for `ldaps://` either way | false |
| groupSync.url | LDAP server URL. **Empty by default** — supply it per cluster, or leave it out and it is derived from the OAuth CR at install time (not available to `helm template`) | `""` |

### Multi-Tenant GroupSync Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| customGroupSyncs.enabled | Master switch for all custom (per-tenant) CRs | true |
| customGroupSyncs.items[].name | Unique name of the custom GroupSync resource | — |
| customGroupSyncs.items[].enabled | On/off for this single custom CR | — |
| customGroupSyncs.items[].groupCn | LDAP group pattern to sync (filter built for you) | — |
| customGroupSyncs.items[].schedule | Optional per-item schedule override | inherits groupSync.schedule |
| customGroupSyncs.items[].namespace | Optional per-item namespace override | inherits groupSync.namespace |
| customGroupSyncs.items[].filter | Optional raw LDAP filter (advanced) | built from groupCn |

See [Multi-Tenant GroupSync](#multi-tenant-groupsync-customgroupsyncs) for usage.

### CA Certificate Configuration

A CA is required whenever the url is `ldaps://` — **even with `insecure: true`**. Implicit TLS
completes the handshake before any LDAP traffic, so the client must already trust the CA; `insecure`
only relaxes checks the operator makes itself. It is also required with `insecure: false` over plain
`ldap://`.

`groupSync.ca` names a **copy in the operator's own namespace**, not the source in `openshift-config`.
Reading it in place needs cross-namespace ConfigMap read that the operator has on some clusters and
not others, and where it is denied the only symptom is the operator reconciling forever on
`ConfigMap ... not found, caSecret must be specified when insecure=false` — naming neither the
namespace nor the permission. The extraction job makes the copy.

| Parameter | Description | Default |
|-----------|-------------|---------|
| groupSync.ca.field | `caSecret` or `ca`. Validation checks `caSecret` even though the CRD calls it deprecated | caSecret |
| groupSync.ca.kind | ConfigMap or Secret | ConfigMap |
| groupSync.ca.name | Must match `caCopy.destinationCa.name` | ca-config-map-copy |
| groupSync.ca.key | Key holding the PEM | ca.crt |
| groupSync.ca.namespace | The operator's namespace, not openshift-config | group-sync-operator |

### CA Copy Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| oauthSecretExtraction.caCopy.enabled | Copy the CA into the operator's namespace. Only runs when a CA is needed | true |
| oauthSecretExtraction.caCopy.discoverFromOAuth | Read the source ConfigMap **name** from the cluster OAuth CR rather than trusting the value below | true |
| oauthSecretExtraction.caCopy.sourceCa.name | Source ConfigMap — the one the OAuth LDAP identity provider uses | ca-config-map |
| oauthSecretExtraction.caCopy.sourceCa.namespace | Fixed by the OpenShift API | openshift-config |
| oauthSecretExtraction.caCopy.sourceCa.key | Fixed by the OpenShift API | ca.crt |
| oauthSecretExtraction.caCopy.destinationCa.kind | ConfigMap or Secret | ConfigMap |
| oauthSecretExtraction.caCopy.destinationCa.name | Named `-copy` because the job overwrites it on every install and upgrade | ca-config-map-copy |
| oauthSecretExtraction.caCopy.destinationCa.namespace | Defaults to `groupSync.namespace` | group-sync-operator |

The copy carries `group-sync.redhat-cop.io/source-hash`, and that hash is also stamped on the
extraction job's pod template — so a changed source CA changes the pod spec and the copy is remade on
the next upgrade. It is computed with `lookup`, which reads the live cluster, so `helm template` and
offline GitOps renders show `unavailable` and the runtime stamp is the reliable record.

### Values discovered from the OAuth CR when left empty

The cluster's OAuth LDAP identity provider already describes a directory that works, so these need
not be repeated. An explicit value always wins.

| Left empty | Taken from | Notes |
|---|---|---|
| `groupSync.url` | `identityProviders[LDAP].ldap.url` | Only `scheme://host:port`; the basedn and query describe authentication, not group sync. Resolved at template time, so `helm install`/`upgrade` only |
| `oauthSecretExtraction.bindDN` | `.ldap.bindDN` | Resolved by the job at runtime, so it works under an offline GitOps render |
| `oauthSecretExtraction.sourceSecret.name` | `.ldap.bindPassword.name` | Same, and taken from the **same** provider as the bindDN so the pair always belongs together |

The **first** LDAP provider wins, and the job logs which one it used. Note that a bare
`identityProviders[0]` would be the first provider of any type — commonly HTPasswd — so the type
filter matters.

### Subscription Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| subscription.channel | OLM channel | alpha |
| subscription.watchNamespaces | Namespaces to watch | group-sync-operator,openshift-config |
| subscription.installPlanApproval | Install plan approval | Automatic |
| subscription.source | Operator source | community-operators |
| subscription.sourceNamespace | Source namespace | openshift-marketplace |

### Test Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| test.enabled | Enable test pods | true |
| test.ldapClientImage.repository | Image for the connection test — needs `oc` and `curl` | registry.redhat.io/openshift4/ose-cli |
| test.ldapClientImage.tag | Pinned, not `latest`: builds differ in what they ship | v4.14 |
| test.ldapClientImage.pullPolicy | Image pull policy | IfNotPresent |
| test.operatorHealthImage.repository | Image for the operator health test | registry.redhat.io/openshift4/ose-cli |
| test.operatorHealthImage.tag | Pinned for the same reason | v4.14 |
| test.syncWaitSeconds | Seconds to wait for a first successful sync before failing | 180 |

## Custom Values

To override the default values, create a `values.yaml` file and pass it to the helm install command:

```bash
helm install group-sync group-sync-operator/group-sync-operator-helm \
  -n group-sync-operator --create-namespace -f values.yaml
```

## Notes

- The chart focuses on deploying only the essential components: GroupSync CR, OperatorGroup, and Subscription
- Deployment order is managed via ArgoCD sync waves
- Labels follow Kubernetes recommended standards
- LDAP queries use RFC2307 schema
- The primary CR filters for `app-ocp-rbac-*`; additional per-tenant patterns (e.g.
  `bda-rbac-*`) are added via `customGroupSyncs` — see
  [Multi-Tenant GroupSync](#multi-tenant-groupsync-customgroupsyncs)
- Optional test pods can be enabled to validate installation and LDAP connectivity

## Upgrade Notes

When upgrading the chart, note that:
1. The operator upgrade is managed by OLM
2. Existing LDAP sync configurations will be preserved
3. ArgoCD sync waves ensure proper deployment order
4. Test pods configuration can be separately enabled or disabled

```bash
helm upgrade group-sync group-sync-operator/group-sync-operator-helm -n group-sync-operator
```

### `helm upgrade` keeps your old values — new chart defaults will NOT apply

This catches people out, so it is worth being explicit. `helm upgrade` reuses the **user-supplied
values from the previous revision**. Anything you once passed with `-f` or `--set` keeps applying on
every later upgrade, even when the chart's own default for that key has changed.

Two ways this bites in practice:

- **A stale `groupSync.ca`.** If an earlier install pointed it at `openshift-config`, that persists
  after the chart default moves to the local `ca-config-map-copy`. The operator carries on attempting
  a cross-namespace read and, where that is denied, reconciles forever on `ConfigMap ... not found`.
- **A stale empty `groupSync.url`.** Setting it empty enables discovery from the OAuth CR. That empty
  value persists, so if the cluster's LDAP identity provider is later removed there is nothing left to
  derive from and the upgrade fails with `groupSync.url is empty and no LDAP url could be derived`.

Check what the release is actually carrying, then clear it if needed:

```bash
# What you supplied (chart defaults are NOT shown here)
helm get values group-sync -n group-sync-operator

# Everything after the merge — what the templates really saw
helm get values group-sync -n group-sync-operator --all

# Discard the remembered values and take the chart defaults
helm upgrade group-sync ./charts/group-sync-operator-helm -n group-sync-operator --reset-values
```

`--reset-values` discards **all** previously supplied values, so pass any you still want in the same
command. Use `--reuse-values` for the opposite behaviour, and note that mixing `--reuse-values` with
`--set` only merges the keys you name.

### Upgrading over a release installed before the test resources were un-hooked

The test ServiceAccount, RBAC and scripts ConfigMap used to be Helm **hooks**, and are now ordinary
release resources. Hook-created objects carry no `meta.helm.sh/release-*` annotations, so Helm cannot
adopt them and the first upgrade fails:

```
Error: UPGRADE FAILED: Unable to continue with update: ServiceAccount "group-sync-test-sa" in
namespace "group-sync-operator" exists and cannot be imported into the current release:
invalid ownership metadata; annotation validation error: missing key "meta.helm.sh/release-name"
```

Delete the leftovers once — they hold no state, and the upgrade recreates them as managed resources:

```bash
oc delete sa group-sync-test-sa -n group-sync-operator
oc delete configmap group-sync-test-scripts -n group-sync-operator
oc delete role group-sync-test-ca-role -n group-sync-operator
oc delete rolebinding group-sync-test-ca-binding -n group-sync-operator
oc delete clusterrole group-sync-test-role
oc delete clusterrolebinding group-sync-test-binding
```

Then upgrade as normal. This is a one-time step; later upgrades are unaffected.

## Troubleshooting

1. Verify the operator deployment:

```bash
oc get csv -n group-sync-operator
```

1. Check GroupSync status:

```bash
oc get groupsync -n group-sync-operator
```

1. View sync logs:

```bash
oc logs -l app.kubernetes.io/name=group-sync-operator-helm -n group-sync-operator
```

1. Monitor real-time sync activity:

```bash
# Watch live sync operations (useful for debugging sync issues)
kubectl logs -n group-sync-operator deployment/group-sync-operator-controller-manager -c manager --tail=5 -f

# Using oc command
oc logs -n group-sync-operator deployment/group-sync-operator-controller-manager -c manager --tail=5 -f
```

## Related Learning Materials

For learning about Helm hooks and advanced deployment patterns:
- **Helm Hooks Demo**: Check `/Users/olasumbo/gitRepos/hooks-demo/` for complete working examples and comprehensive documentation
- **Why This Chart Doesn't Use Hooks**: We chose proper resource ordering and ArgoCD sync waves for better maintainability and production use

## Source Code

The source code for this Helm chart is available at:
<https://github.com/ephico2real2/group-sync-operator-helm-chart>

The Group Sync Operator source code is available at:
<https://github.com/redhat-cop/group-sync-operator>
