# Setup Local LDAP Testing Environment

This directory (`setup-local-ldap-testing`) contains a complete, production-ready OpenLDAP server setup for testing the Group Sync Operator locally with enterprise-grade RBAC groups.

## Overview

The LDAP server is configured with:
- **Domain**: `ephico2real.com`
- **Base DN**: `dc=ephico2real,dc=com`
- **Storage**: PVC backed by `crc-csi-hostpath-provisioner`
- **Namespace**: `ldap-testing`

### 🔐 ConfigMap Name Separation Strategy

This setup uses **intentional separation** between production and local testing ConfigMaps to prevent collisions:

| Environment | ConfigMap Name | Purpose |
|------------|----------------|---------|
| **Production** | `ca-config-map` | Used by production Helm chart deployments |
| **Local Testing** | `ca-config-map-test` | Used by local testing scripts (this directory) |

**Why this separation?**
- Prevents local testing from interfering with production deployments
- Allows parallel testing without affecting production configurations
- Makes it clear which environment you're working with

**Files using each name:**
- **`ca-config-map-test`** (Local Testing):
  - `values.yaml` (line 21) - Local testing configuration
  - `30-manage-ldap-server.sh` (ca-cert-extract function) - Creates test ConfigMap
  - `10-setup-oauth-secrets.sh` - Creates test ConfigMap
  
- **`ca-config-map`** (Production References):
  - Production Helm chart deployments
  - Production documentation examples

**Note**: If you want to test with the production ConfigMap name locally, you can override in `values.yaml` or use `--set groupSync.ca.name=ca-config-map` during Helm install.

## Directory Structure

### 🏗️ Infrastructure Components (YAML)

| File | Description |
|------|-------------|
| `01-ldap-server.yaml` | Complete OpenLDAP deployment (primary infrastructure) |
| `02-phpldapadmin.yaml` | Optional web GUI for LDAP management |
| `03-ldap-bootstrap-job.yaml` | Alternative K8s Job-based data import |

### 🚀 Execution Scripts (Ordered by Priority)

| File | Description |
|------|-------------|
| `10-setup-oauth-secrets.sh` | **STEP 1**: Creates source OAuth secrets and CA certificates |
| `20-import-ldap-data.sh` | **STEP 2**: Imports comprehensive RBAC groups and test users |
| `30-manage-ldap-server.sh` | **ONGOING**: Complete LDAP server lifecycle management |
| `90-verify-all-resources.sh` | **STEP 3**: Verifies all resources and configuration |
| `99-cleanup-everything.sh` | **FINAL**: Complete test environment cleanup |

### 📊 Data Files

| File | Description |
|------|-------------|
| `ldap-structure-combined.ldif` | 20+ production RBAC groups (`app-ocp-rbac-*`) and test users |
| `ldap-bda-rbac-groups.ldif` | 12 Big-Data Analytics groups (`bda-rbac-*`) — demo for the custom GroupSync CR |
| `ldap-rbac-groups-spar-trno.ldif` | 6 namespace RBAC groups for the `spar` / `trno` mnemonics — pairs with the BDA namespace demo |
| `ldap-normalize-user-dns.ldif` | One-time migration: renames the 5 `cn=` users to `uid=` so all member DNs resolve |
| `configure-acls.ldif` | Service account ACL permissions |
| `kubectl-import-commands.md` | Manual import command documentation |
| `README.md` | This comprehensive documentation |

## 🚀 Quick Start (New Organized Workflow)

### Step 1: Setup Prerequisites

```bash
# Creates source OAuth secrets and CA certificates
./10-setup-oauth-secrets.sh
```

### Step 2: Deploy LDAP Server

```bash
# Deploy the OpenLDAP server
./30-manage-ldap-server.sh deploy
```

### Step 3: Import LDAP Data

```bash
# Import comprehensive RBAC groups and users
./20-import-ldap-data.sh
```

### Step 4: Verify Setup

```bash
# Verify all resources are configured correctly
./90-verify-all-resources.sh
```

### Step 5: Test Connectivity

```bash
# Test LDAP connectivity and queries
./30-manage-ldap-server.sh test
```

## Manual LDAP Structure Import (If Bootstrap Fails)

If the bootstrap job doesn't properly import the LDAP structure, you can manually import it:

### 1. Create the LDAP structure file

```bash
cat > import-ldap-structure.ldif << 'EOF'
# LDAP Structure Import - Creates OUs, service account, users, and groups

# Create organizational units
dn: ou=People,dc=ephico2real,dc=com
objectClass: organizationalUnit
ou: People
description: Container for user accounts

dn: ou=Groups,dc=ephico2real,dc=com
objectClass: organizationalUnit
ou: Groups
description: Container for group accounts

dn: ou=TrustedApplications,dc=ephico2real,dc=com
objectClass: organizationalUnit
ou: TrustedApplications
description: Container for service accounts

# Create service account for LDAP binding directly under TrustedApplications
dn: cn=ocp-ldap-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: ocp-ldap-bind-serviceid
description: OpenShift LDAP binding service account
userPassword: bindpassword123

# Create test users
dn: cn=john.doe,ou=People,dc=ephico2real,dc=com
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
cn: john.doe
sn: Doe
givenName: John
displayName: John Doe
uid: john.doe
mail: john.doe@ephico2real.com
uidNumber: 10001
gidNumber: 10001
homeDirectory: /home/john.doe
loginShell: /bin/bash
userPassword: {SSHA}password123

dn: cn=jane.smith,ou=People,dc=ephico2real,dc=com
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
cn: jane.smith
sn: Smith
givenName: Jane
displayName: Jane Smith
uid: jane.smith
mail: jane.smith@ephico2real.com
uidNumber: 10002
gidNumber: 10002
homeDirectory: /home/jane.smith
loginShell: /bin/bash
userPassword: {SSHA}password123

dn: cn=bob.wilson,ou=People,dc=ephico2real,dc=com
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
cn: bob.wilson
sn: Wilson
givenName: Bob
displayName: Bob Wilson
uid: bob.wilson
mail: bob.wilson@ephico2real.com
uidNumber: 10003
gidNumber: 10003
homeDirectory: /home/bob.wilson
loginShell: /bin/bash
userPassword: {SSHA}password123

# Create RBAC groups for testing
dn: cn=app-ocp-rbac-platform-cluster-admin,ou=Groups,dc=ephico2real,dc=com
objectClass: groupOfNames
cn: app-ocp-rbac-platform-cluster-admin
description: Platform team cluster administrators
member: cn=john.doe,ou=People,dc=ephico2real,dc=com

dn: cn=app-ocp-rbac-alpha-ns-admin,ou=Groups,dc=ephico2real,dc=com
objectClass: groupOfNames
cn: app-ocp-rbac-alpha-ns-admin
description: Alpha team namespace administrators
member: cn=jane.smith,ou=People,dc=ephico2real,dc=com

dn: cn=app-ocp-rbac-demo-ns-developer,ou=Groups,dc=ephico2real,dc=com
objectClass: groupOfNames
cn: app-ocp-rbac-demo-ns-developer
description: Demo team namespace developers
member: cn=bob.wilson,ou=People,dc=ephico2real,dc=com
EOF
```

### 2. Import the LDAP structure

```bash
# Copy LDIF to LDAP container
kubectl cp import-ldap-structure.ldif ldap-testing/$(kubectl get pods -n ldap-testing -l app=openldap-server -o jsonpath='{.items[0].metadata.name}'):/tmp/

# Import using ldapadd
kubectl exec -n ldap-testing deployment/openldap-server -- ldapadd -x -H ldap://localhost:389 -D "cn=admin,dc=ephico2real,dc=com" -w "admin123" -f /tmp/import-ldap-structure.ldif
```

### 3. Configure service account ACLs

```bash
# Create ACL configuration file
cat > configure-acls.ldif << 'EOF'
# Configure OpenLDAP ACLs to grant service account read access
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcAccess
olcAccess: {0}to attrs=userPassword by self write by dn="cn=admin,dc=ephico2real,dc=com" write by dn="cn=ocp-ldap-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com" read by anonymous auth by * none
olcAccess: {1}to dn.subtree="ou=People,dc=ephico2real,dc=com" by dn="cn=admin,dc=ephico2real,dc=com" write by dn="cn=ocp-ldap-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com" read by * none  
olcAccess: {2}to dn.subtree="ou=Groups,dc=ephico2real,dc=com" by dn="cn=admin,dc=ephico2real,dc=com" write by dn="cn=ocp-ldap-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com" read by * none
olcAccess: {3}to dn.subtree="ou=TrustedApplications,dc=ephico2real,dc=com" by dn="cn=admin,dc=ephico2real,dc=com" write by dn="cn=ocp-ldap-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com" read by * none
olcAccess: {4}to * by dn="cn=admin,dc=ephico2real,dc=com" write by * read
EOF

# Copy ACL config to container
kubectl cp configure-acls.ldif ldap-testing/$(kubectl get pods -n ldap-testing -l app=openldap-server -o jsonpath='{.items[0].metadata.name}'):/tmp/

# Apply ACL configuration
kubectl exec -n ldap-testing deployment/openldap-server -- ldapmodify -x -H ldap://localhost:389 -D "cn=admin,cn=config" -w "config123" -f /tmp/configure-acls.ldif
```

### 4. Test service account access

```bash
# Test service account can read Groups OU
kubectl exec -n ldap-testing deployment/openldap-server -- ldapsearch -x -H ldap://localhost:389 -D "cn=ocp-ldap-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com" -w "bindpassword123" -b "ou=Groups,dc=ephico2real,dc=com" -s base "(objectclass=*)" dn

# Test service account can search for groups
kubectl exec -n ldap-testing deployment/openldap-server -- ldapsearch -x -H ldap://localhost:389 -D "cn=ocp-ldap-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com" -w "bindpassword123" -b "ou=Groups,dc=ephico2real,dc=com" "(&(objectClass=groupOfNames)(cn=app-ocp-rbac-*))" cn description member

# Test service account can access People OU for user queries
kubectl exec -n ldap-testing deployment/openldap-server -- ldapsearch -x -H ldap://localhost:389 -D "cn=ocp-ldap-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com" -w "bindpassword123" -b "ou=People,dc=ephico2real,dc=com" "(objectClass=inetOrgPerson)" cn uid mail
```

## Management Script Usage

```bash
./30-manage-ldap-server.sh [COMMAND]
```

### Available Commands:
- `deploy` - Deploy the LDAP server
- `delete` - Delete the LDAP server
- `status` - Show LDAP server status
- `test` - Test LDAP connectivity
- `query` - Query LDAP for groups and users
- `logs` - Show LDAP server logs
- `shell` - Open shell in LDAP container
- `port-forward` - Start port forwarding (ldap:1389, ldaps:1636)
- `help` - Show help message

## LDAP Configuration

### Domain Structure

```text
dc=ephico2real,dc=com
├── ou=People                    # User accounts
│   ├── cn=john.doe
│   ├── cn=jane.smith
│   └── cn=bob.wilson
├── ou=Groups                    # Group accounts
│   ├── cn=app-ocp-rbac-platform-cluster-admin
│   ├── cn=app-ocp-rbac-alpha-ns-admin
│   └── cn=app-ocp-rbac-demo-ns-developer
└── ou=TrustedApplications       # Service accounts
    └── cn=ocp-ldap-bind-serviceid
```

### Credentials

#### Admin Account
- **DN**: `cn=admin,dc=ephico2real,dc=com`
- **Password**: `admin123`

#### Service Account (for GroupSync)
- **DN**: `cn=ocp-ldap-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com`
- **Password**: `bindpassword123`

#### Test Users

| Username | DN | Password | Groups |
|----------|----|---------|---------|
| john.doe | `cn=john.doe,ou=People,dc=ephico2real,dc=com` | `password123` | admins, general-users |
| jane.smith | `cn=jane.smith,ou=People,dc=ephico2real,dc=com` | `password123` | admins, developers, general-users |
| bob.wilson | `cn=bob.wilson,ou=People,dc=ephico2real,dc=com` | `password123` | developers, viewers, general-users |

### OpenShift RBAC Groups

Two group families are seeded, each synced by its own GroupSync CR:

**Primary — `app-ocp-rbac-*`** (synced by `ldap-groupsync`, filter `cn=app-ocp-rbac-*`).
Format `app-ocp-rbac-{team}-{ns|cluster}-{admin|developer|audit}`, e.g.
`app-ocp-rbac-platform-cluster-admin`. Seeded from `ldap-structure-combined.ldif`.

**Big-Data Analytics — `bda-rbac-*`** (synced by the custom `bda-rbac-groupsync`, filter
`cn=bda-rbac-*`). Format `bda-rbac-{service}-{env}-{apps|users}` across
`{spark,trino} × {alpha,delta,theta} × {apps,users}` = 12 groups. Seeded from
`ldap-bda-rbac-groups.ldif`. Demonstrates the multi-tenant `customGroupSyncs` feature —
see the **Update Guide** section below.

> The LDIF seeds **12**; a live cluster typically shows **15**, because
> `50-simulate-ldap-operations.sh` adds `flink-alpha-{apps,users}` and `spark-gamma-apps`.
> Note `spark-gamma-apps` has no matching `-users` partner — a deliberate asymmetry that is
> useful for testing the "group referenced but does not exist" path.

**Namespace RBAC for the BDA demo — `app-ocp-rbac-{spar,trno}-ns-*`** (synced by
`ldap-groupsync`, same `cn=app-ocp-rbac-*` filter). Seeded from
`ldap-rbac-groups-spar-trno.ldif`: 6 groups covering
`{spar,trno} × {admin,developer,audit}`.

These exist so the BDA demo namespaces (`spar-rnd`, `spar-qa`, `trno-uat` in
`openshift-rbac-automation/working-sessions/`) have real groups behind their standard
RoleBindings. Both mnemonics are exactly 4 lowercase letters, as the Kyverno rule
`validate-group-naming-standards` requires (`^app-ocp-rbac-[a-z]{4}-(ns|cluster)-(admin|developer|audit)$`).

> **Why this file exists:** without it, the `NamespaceConfig` still creates
> `spar-admin-rb` / `-developer-rb` / `-audit-rb` in every matching namespace — Kubernetes
> does not validate that a RoleBinding's subject Group exists. The bindings look healthy,
> the operator reports `ReconcileSuccess`, and nobody has access. Seeding these groups is
> what makes the demo actually grant anything. Full write-up:
> `openshift-rbac-automation/working-sessions/README.md`.

> **DN convention — RESOLVED, all users are now `uid=`.** This directory previously mixed
> two forms: seed users from the LDIF files were `cn=<user>`, while users created live by
> `50-simulate-ldap-operations.sh` were `uid=<user>`. The operator matches group members to
> users **by DN**, so a mismatched `member:` value is accepted by `ldapadd` without error and
> then silently dropped at sync — the group syncs with zero users.
>
> That bit for real. Three groups were broken before the fix:
>
> | Group | Bad member ref | User actually was |
> |---|---|---|
> | `app-ocp-rbac-devops-cluster-admin` | `uid=john.doe` | `cn=john.doe` |
> | `app-ocp-rbac-devops-ns-developer` | `uid=alice.cooper` | `cn=alice.cooper` |
> | `app-ocp-rbac-test-cluster-admin` | `uid=john.doe` | `cn=john.doe` |
>
> All three synced empty while their ClusterRoleBindings sat there looking healthy.
>
> **Fixed by `ldap-normalize-user-dns.ldif`**, which renames the five `cn=` users to `uid=`.
> Run it once against an existing directory; new deployments get the correct form from
> `ldap-structure-combined.ldif` directly. Verify with:
>
> ```bash
> ldapsearch -x -b "ou=People,dc=ephico2real,dc=com" "(objectClass=inetOrgPerson)" dn
> # every DN should start with uid=
> ```
>
> When hand-writing an LDIF, still check the target DN before writing a `member:` line —
> nothing validates it.

## 🔄 Update Guide — Onboarding a New Tenant / Group Family

End-to-end path to add a NEW group family (e.g. your own `xyz-ocp-rbac-*`) so it syncs
into OpenShift under its own GroupSync CR. Two sides: put the groups in LDAP, then tell
the chart to sync them.

### Step 1 — Create the groups in LDAP

**Option A — static LDIF (reproducible, recommended).** Copy `ldap-bda-rbac-groups.ldif`
as a template, rename to your family, then import:

```bash
POD=$(kubectl get pods -n ldap-testing -l app=openldap-server -o jsonpath='{.items[0].metadata.name}')
kubectl cp ldap-<your-family>-groups.ldif ldap-testing/$POD:/tmp/
kubectl exec -n ldap-testing $POD -- ldapadd -x -H ldap://localhost:389 \
  -D "cn=admin,dc=ephico2real,dc=com" -w admin123 -f /tmp/ldap-<your-family>-groups.ldif
```

**Option B — live, via the simulation script.** Menu option `2` (add group) / `3` (add
user to group), or the built-in demo scenario (menu shortcut `s5`):

```bash
./50-simulate-ldap-operations.sh bda-onboarding
```

### Step 2 — Add a custom GroupSync CR in the chart

In the chart's `values.yaml`, add one item under `customGroupSyncs.items` — a unique
`name` and the group pattern (`groupCn`). Nothing else is required (the LDAP filter,
provider name, and connection are supplied for you):

```yaml
customGroupSyncs:
  enabled: true
  items:
    - name: bda-rbac-groupsync
      enabled: true
      groupCn: "bda-rbac-*"
```

One naming pattern = one CR; patterns must not overlap. Full reference:
[../docs/DESIGN_custom_groupsync.md](../docs/DESIGN_custom_groupsync.md).

### Step 3 — Apply and verify

```bash
# From the chart root:
helm upgrade group-sync . -n default

# The new CR exists alongside the primary one:
oc get groupsync -n group-sync-operator

# Force an immediate sync (or wait for the schedule):
oc annotate groupsync bda-rbac-groupsync -n group-sync-operator \
  sync.redhatcop.redhat.io/sync-now="$(date)" --overwrite

# Confirm the groups landed, owned by the new CR (label <cr-name>_ldap):
oc get groups -l group-sync-operator.redhat-cop.io/sync-provider=bda-rbac-groupsync_ldap
```

### Removing a tenant

Set that item's `enabled: false` (or remove it) and `helm upgrade` — only that CR is
removed; the other tenants are untouched.

## Testing GroupSync Integration

### 1. Update GroupSync Configuration

Update your `values.yaml` to point to the local LDAP server:

```yaml
groupSync:
  # Change the URL to point to local LDAP
  url: "ldap://openldap-service.ldap-testing.svc.cluster.local:389"
  
  rfc2307:
    usersQuery:
      baseDN: "dc=ephico2real,dc=com"
    groupsQuery:
      baseDN: "ou=Groups,dc=ephico2real,dc=com"
      filter: "(&(objectClass=groupOfNames)(cn=app-ocp-rbac-*))"

oauthSecretExtraction:
  # Disable OAuth extraction for local testing
  enabled: false
```

### 2. OAuth Secret Extraction (Automated)

**✅ Automatic Secret Creation**: The Helm chart includes an **OAuth secret extraction job** that automatically creates the target GroupSync secret from the source OAuth secret.

**How it works:**
1. `10-setup-oauth-secrets.sh` creates the source OAuth secret (`ldap-secret`) in `openshift-config` namespace
2. When you deploy the Helm chart with `oauthSecretExtraction.enabled=true`, a Job runs automatically
3. The Job extracts the `bindPassword` from the source secret
4. It creates the target secret (`ldap-group-sync`) in `group-sync-operator` namespace with:
   - `username`: The bindDN (from `values.yaml`)
   - `password`: The extracted bindPassword

**Manual Secret Creation (Alternative):**
If you prefer to create the secret manually (or if OAuth extraction is disabled):

```bash
kubectl create secret generic ldap-group-sync \
  --from-literal=username="cn=ocp-ldap-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com" \
  --from-literal=password="bindpassword123" \
  -n group-sync-operator
```

**Note**: The secret keys are `username` and `password` (not `bindDN` and `bindPassword`) to match the OAuth extraction job format.

### 3. Deploy GroupSync

**With OAuth Secret Extraction (Recommended):**

```bash
helm upgrade group-sync . -n group-sync-operator \
  --set groupSync.url="ldap://openldap-service.ldap-testing.svc.cluster.local:389" \
  --set groupSync.insecure=true \
  --set oauthSecretExtraction.enabled=true \
  --set oauthSecretExtraction.sourceSecret.name=ldap-secret \
  --set oauthSecretExtraction.sourceSecret.namespace=openshift-config
```

**Without OAuth Secret Extraction (Manual Secret):**

```bash
# First create the secret manually (see Step 2 above)
helm upgrade group-sync . -n group-sync-operator \
  --set groupSync.url="ldap://openldap-service.ldap-testing.svc.cluster.local:389" \
  --set groupSync.insecure=true \
  --set oauthSecretExtraction.enabled=false
```

**Verify OAuth Extraction Job:**

```bash
# Check if the extraction job ran successfully
oc get jobs -n group-sync-operator | grep oauth-secret-extraction

# View job logs
oc logs job/group-sync-operator-helm-oauth-secret-extraction -n group-sync-operator

# Verify target secret was created
oc get secret ldap-group-sync -n group-sync-operator
```

## Storage

The LDAP server uses a PersistentVolumeClaim with:
- **Size**: 2Gi
- **Storage Class**: `crc-csi-hostpath-provisioner`
- **Access Mode**: ReadWriteOnce

Data persists across pod restarts.

## Networking

### Internal Access
- **Service**: `openldap-service.ldap-testing.svc.cluster.local`
- **LDAP Port**: 389
- **LDAPS Port**: 636

### External Access (via Port Forward)

```bash
./30-manage-ldap-server.sh port-forward
```

- **LDAP**: `ldap://localhost:1389`
- **LDAPS**: `ldaps://localhost:1636`

### Route (OpenShift)
An optional Route is created for external access through the OpenShift router.

## Troubleshooting

### Check Pod Status

```bash
./30-manage-ldap-server.sh status
```

### View Logs

```bash
./30-manage-ldap-server.sh logs
```

### Test Connectivity

```bash
./30-manage-ldap-server.sh test
```

### Open Shell for Debugging

```bash
./30-manage-ldap-server.sh shell
```

### Manual LDAP Queries
From within the pod:

```bash
ldapsearch -x -H ldap://localhost:389 \
  -D "cn=admin,dc=ephico2real,dc=com" \
  -w "admin123" \
  -b "dc=ephico2real,dc=com" \
  "(objectClass=*)" dn
```

## Cleanup

To remove the LDAP server:

```bash
./30-manage-ldap-server.sh delete
```

This will delete all resources including the PVC and stored data.

## Notes

- The LDAP server is configured for testing only - do not use in production
- TLS is enabled but uses self-signed certificates
- The service account password is hardcoded for simplicity
- Bootstrap data is loaded automatically on first startup
- Data persists in the PVC even if the pod is restarted

## Local Testing Setup for GroupSync Operator

This directory contains the necessary files and commands for setting up a local test environment for the GroupSync Operator.

## 📁 Directory Contents

- `ca-cert.pem` - Demo CA certificate for LDAPS testing
- `ca-key.pem` - Private key for the demo CA certificate
- `README.md` - This file with setup instructions

## 🚀 Complete Setup Commands

### Prerequisites

Ensure you have:
- OpenShift cluster access
- `oc` CLI configured
- `helm` CLI installed
- `openssl` available

### Step 1: Deploy the GroupSync Chart (Two-Step Process)

```bash
# Navigate to the chart directory
cd /Users/olasumbo/gitRepos/group-sync-chart

# Step 1: Install operator only (without GroupSync CR)
helm install group-sync . --set groupSync.enabled=false

# Verify operator installation
oc get csv -n group-sync-operator
oc get pods -n group-sync-operator

# Wait for operator to be ready (CSV should show "Succeeded")
# Then proceed to Step 2

# Step 2: Enable GroupSync CR
helm upgrade group-sync . --set groupSync.enabled=true

# Verify GroupSync CR creation
oc get groupsync -n group-sync-operator
```

### Step 2: Create Demo CA Certificate

```bash
# Navigate to setup-local-ldap-testing directory
cd setup-local-ldap-testing

# Generate demo CA certificate and private key
openssl req -x509 -newkey rsa:4096 \
  -keyout ca-key.pem \
  -out ca-cert.pem \
  -days 365 \
  -nodes \
  -subj "/CN=Demo LDAP CA/O=Demo Organization/C=US"

# Verify certificate creation
ls -la ca-*.pem

# View certificate details (optional)
openssl x509 -in ca-cert.pem -text -noout
```

### Step 3: Create ConfigMap for CA Certificate

```bash
# Create ConfigMap in openshift-config namespace
oc create configmap ca-config-map \
  --from-file=ca.crt=./ca-cert.pem \
  -n openshift-config

# Verify ConfigMap creation
oc get configmap ca-config-map -n openshift-config
oc describe configmap ca-config-map -n openshift-config
```

### Step 4: Create OAuth LDAP Secret (Simulates Production Environment)

```bash
# In production, this secret already exists (used by OpenShift OAuth)
# For demo, we create it to simulate the production scenario
oc create secret generic ldap-secret \
  --from-literal=bindPassword='demo-password-123' \
  -n openshift-config

# Verify secret creation
oc get secret ldap-secret -n openshift-config
oc describe secret ldap-secret -n openshift-config
```

### Step 5: Deploy GroupSync Chart (Automatic Secret Creation)

**ℹ️ Important**: The Helm chart now automatically creates the target GroupSync secret from the source OAuth secret via an extraction job. No manual secret creation is needed!

```bash
# Deploy/upgrade the GroupSync chart with OAuth extraction enabled
helm upgrade group-sync . \
  --set oauthSecretExtraction.enabled=true \
  --set oauthSecretExtraction.sourceSecret.name=ldap-secret \
  --set oauthSecretExtraction.sourceSecret.namespace=openshift-config

# Verify the OAuth extraction job runs successfully
oc get jobs -n group-sync-operator
oc describe job oauth-secret-extraction-job -n group-sync-operator

# Verify the target secret was created automatically
oc get secret ldap-group-sync -n group-sync-operator
oc describe secret ldap-group-sync -n group-sync-operator
```

### Step 6: Verify GroupSync Configuration

```bash
# Check GroupSync status (should show LDAP connection error instead of config errors)
oc describe groupsync ldap-group-sync -n group-sync-operator

# View operator logs
oc logs deployment/group-sync-operator-controller-manager -c manager -n group-sync-operator --tail=20

# Check if configuration errors are resolved
oc get groupsync ldap-group-sync -n group-sync-operator -o yaml
```

## 🔍 Expected Results

### Before Helm Chart Deployment

```text
Status:
  Conditions:
    Message: [secrets "ldap-group-sync" not found, ConfigMap "ca-config-map" not found, ...]
    Reason: LastReconcileCycleFailed
    Status: True
    Type: ReconcileError
```

### After Helm Chart Creates Target Secret Automatically

```text
Status:
  Conditions:
    Message: could not connect to the LDAP server: LDAP Result Code 200 "Network Error": dial tcp: lookup ldap.ephicoreal2.net on 10.217.4.10:53: no such host
    Reason: LastReconcileCycleFailed
    Status: True
    Type: ReconcileError
```

**✅ Success!** The configuration errors are resolved. The new error shows the operator is trying to connect to the LDAP server (which doesn't exist in this demo), proving the configuration is correct and the target secret was created automatically.

## 🧹 Cleanup Commands

### Remove Test Resources

```bash
# Remove the Helm release
helm uninstall group-sync

# Remove the demo ConfigMap
oc delete configmap ca-config-map -n openshift-config

# Remove the demo OAuth secret (target secret is managed by Helm)
oc delete secret ldap-secret -n openshift-config

# Remove the namespace (optional)
oc delete namespace group-sync-operator
```

### Clean Local Files

```bash
# Remove certificate files (optional)
rm -f ca-cert.pem ca-key.pem
```

## 🔧 Production Setup Notes

### For Real LDAP Server

Replace the demo values with your actual LDAP configuration:

1. **CA Certificate**: Obtain from your LDAP server or Certificate Authority

   ```bash
   # Example: Extract from LDAP server
   openssl s_client -connect your-ldap-server:636 -showcerts < /dev/null 2>/dev/null | \
     openssl x509 -outform PEM > real-ldap-ca.crt
   ```

2. **LDAP Credentials**: Create the source OAuth secret (Helm chart will create target secret)

   ```bash
   oc create secret generic ldap-secret \
     --from-literal=bindPassword='your-actual-password' \
     -n openshift-config
   
   # The Helm chart will automatically create the target secret:
   # ldap-group-sync in group-sync-operator namespace
   ```

3. **Update values.yaml**: Modify the LDAP URL and base DNs to match your environment

   ```yaml
   groupSync:
     url: "ldaps://your-ldap-server.company.com:636"
     rfc2307:
       usersQuery:
         baseDN: "ou=People,dc=company,dc=com"
       groupsQuery:
         baseDN: "ou=Groups,dc=company,dc=com"
         filter: "(cn=your-group-pattern-*)"
   ```

## 📚 Troubleshooting

### Common Issues

1. **ConfigMap not found**: Ensure it's created in `openshift-config` namespace
2. **Secret not found**: Ensure it's created in `group-sync-operator` namespace
3. **LDAP connection errors**: Expected with demo setup (no real LDAP server)
4. **Certificate errors**: Verify the CA certificate matches your LDAP server

### Debug Commands

```bash
# Check all resources
oc get operatorgroup,subscription,csv,pods,groupsync,configmaps,secrets -n group-sync-operator

# View detailed events
oc get events -n group-sync-operator --sort-by='.lastTimestamp'

# Check operator manager logs
oc logs deployment/group-sync-operator-controller-manager -c manager -n group-sync-operator -f
```

## 🎯 Summary

This local testing setup demonstrates:
- ✅ Proper two-step Helm installation
- ✅ Correct resource ordering (OperatorGroup → Subscription → GroupSync)
- ✅ Configuration validation (from config errors to connection errors)
- ✅ Complete end-to-end deployment process

The demo proves the chart works correctly and is ready for production use with real LDAP credentials and certificates.
