# Group Sync Operator Helm Chart

> **⚠️ IMPORTANT: OPENSHIFT ONLY** 
> 
> This Helm chart is designed **exclusively for OpenShift clusters**. It will not work on standard Kubernetes clusters as it depends on:
> 
> - OpenShift Operator Lifecycle Manager (OLM)
> - OpenShift's catalog sources and OperatorHub
> - OpenShift-specific APIs

This Helm chart deploys the Group Sync Operator and configures LDAP group synchronization in OpenShift environments.

## Adding the Helm Repository

```bash
# Add the Helm repository
helm repo add group-sync-operator https://ephico2real2.github.io/group-sync-operator-helm-chart

# Update your local Helm chart repository cache
helm repo update

# Search for the chart
helm search repo group-sync-operator-helm
```

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

The GroupSync Operator requires a CA certificate to establish secure LDAPS connections. This section guides you through the process of setting up and configuring your CA certificate.

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

### Creating the ConfigMap

Once you have the CA certificate, create a ConfigMap in the appropriate namespace:

```bash
# Create the ConfigMap in the openshift-config namespace
oc create configmap ca-config-map \
  --from-file=ca.crt=./ldap-ca.crt \
  -n openshift-config
```

### Verifying the CA Certificate

Verify that your CA certificate works correctly by testing the LDAPS connection:

```bash
# Test LDAPS connection using the CA certificate
openssl s_client -connect ldap.example.com:636 -CAfile ldap-ca.crt
```

If the connection is successful, you'll see "Verify return code: 0 (ok)" in the output.

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
  openldapClientImage:
    repository: "your-registry/openldap-client"
    tag: "1.0"
    pullPolicy: IfNotPresent
```

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

> **Note:** the shipped default is `*/2 * * * *` (**every 2 minutes**). This is a
> **fast-track testing** cadence so demo changes appear quickly — it is intentionally
> aggressive. **For production, slow it down** so you are not hitting the LDAP server
> every couple of minutes; group membership rarely changes that fast.

```yaml
# In your values.yaml file
groupSync:
  # Fast-track testing (shipped default):
  schedule: "*/2 * * * *"    # every 2 minutes

  # Production examples (pick one):
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
helm install group-sync group-sync-operator/group-sync-operator-helm -n group-sync-operator
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
| groupSync.schedule | Sync schedule (cron format) — fast-track testing default | "*/2 * * * *" |
| groupSync.providerName | LDAP provider name | ldap |
| groupSync.insecure | Use plain LDAP (true) or LDAPS with CA (false) | true |
| groupSync.url | LDAP server URL | ldap://openldap-service.ldap-testing.svc.cluster.local:389 |

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

| Parameter | Description | Default |
|-----------|-------------|---------|
| groupSync.ca.name | ConfigMap name containing CA cert | ca-config-map |
| groupSync.ca.key | Key in ConfigMap for CA cert | ca.crt |
| groupSync.ca.namespace | Namespace of CA ConfigMap | openshift-config |

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
| test.enabled | Enable test pods | false |
| test.openldapClientImage.repository | OpenLDAP client image repository | your-registry/openldap-client |
| test.openldapClientImage.tag | OpenLDAP client image tag | 1.0 |
| test.openldapClientImage.pullPolicy | Image pull policy | IfNotPresent |

## Custom Values

To override the default values, create a `values.yaml` file and pass it to the helm install command:

```bash
helm install group-sync group-sync-operator/group-sync-operator-helm -n group-sync-operator -f values.yaml
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

## Troubleshooting

1. Verify the operator deployment:
```bash
oc get csv -n group-sync-operator
```

2. Check GroupSync status:
```bash
oc get groupsync -n group-sync-operator
```

3. View sync logs:
```bash
oc logs -l app.kubernetes.io/name=group-sync-operator-helm -n group-sync-operator
```

4. Monitor real-time sync activity:
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
https://github.com/ephico2real2/group-sync-operator-helm-chart

The Group Sync Operator source code is available at:
https://github.com/redhat-cop/group-sync-operator
