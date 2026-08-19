# Quick kubectl Commands for LDAP Import

## Prerequisites
Ensure the OpenLDAP server is running in the `ldap-testing` namespace.

## Import Comprehensive LDAP Structure

### Option 1: Automated Script (Recommended)

```bash
# Run the comprehensive import script
./20-import-ldap-data.sh
```

### Option 2: Manual kubectl Commands

```bash
# Get the LDAP pod name
export LDAP_POD=$(kubectl get pods -n ldap-testing -l app=openldap-server --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')

# Copy the comprehensive LDIF file to the pod  
kubectl cp ldap-structure-combined.ldif ldap-testing/$LDAP_POD:/tmp/

# Import the LDAP structure
kubectl exec -n ldap-testing $LDAP_POD -- ldapadd -x -H ldap://localhost:389 \
    -D "cn=admin,dc=ephico2real,dc=com" \
    -w "admin123" \
    -f /tmp/ldap-structure-combined.ldif

# Copy and apply ACL configuration
kubectl cp configure-acls.ldif ldap-testing/$LDAP_POD:/tmp/
kubectl exec -n ldap-testing $LDAP_POD -- ldapmodify -x -H ldap://localhost:389 \
    -D "cn=admin,cn=config" \
    -w "config123" \
    -f /tmp/configure-acls.ldif
```

## Import Optional Group Families

These are additive — import them after the base structure above, in any order.

```bash
# Big-Data Analytics groups (bda-rbac-*), synced by the custom bda-rbac-groupsync CR
kubectl cp ldap-bda-rbac-groups.ldif ldap-testing/$LDAP_POD:/tmp/
kubectl exec -n ldap-testing $LDAP_POD -- ldapadd -x -H ldap://localhost:389 \
    -D "cn=admin,dc=ephico2real,dc=com" \
    -w "admin123" \
    -f /tmp/ldap-bda-rbac-groups.ldif

# Namespace RBAC for the spar / trno mnemonics, used by the BDA namespace demo.
# Synced by app-ocp-rbac-group-groupsync (same cn=app-ocp-rbac-* filter as the base structure).
kubectl cp ldap-rbac-groups-spar-trno.ldif ldap-testing/$LDAP_POD:/tmp/
kubectl exec -n ldap-testing $LDAP_POD -- ldapadd -x -H ldap://localhost:389 \
    -D "cn=admin,dc=ephico2real,dc=com" \
    -w "admin123" \
    -f /tmp/ldap-rbac-groups-spar-trno.ldif
```

Confirm the sync picked them up. `app-ocp-rbac-group-groupsync` runs on the schedule in `values.yaml`
(default `*/30 * * * *`), so allow up to that long. There is no supported "sync now"
annotation — tested, and it does not trigger a run. To see results sooner, temporarily
lower `groupSync.schedule` and `helm upgrade`.

```bash
oc get groups | grep -E '^app-ocp-rbac-(spar|trno)-ns-'   # expect 6
oc get groups | grep -c '^bda-rbac-'                      # expect 12 from the LDIF
```

> If a group syncs with an empty USERS column, the `member:` DN did not match a real user.
> See the DN-convention gotcha in `README.md` — this directory mixes `cn=` and `uid=` DNs,
> and a mismatched `member:` is accepted by `ldapadd` but silently dropped at sync.

## Verification Commands

```bash
# Test service account access to Groups OU
kubectl exec -n ldap-testing $LDAP_POD -- ldapsearch -x -H ldap://localhost:389 \
    -D "cn=ocp-ldap-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com" \
    -w "bindpassword123" \
    -b "ou=Groups,dc=ephico2real,dc=com" \
    -s base "(objectClass=*)" dn

# Count RBAC groups
kubectl exec -n ldap-testing $LDAP_POD -- ldapsearch -x -H ldap://localhost:389 \
    -D "cn=ocp-ldap-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com" \
    -w "bindpassword123" \
    -b "ou=Groups,dc=ephico2real,dc=com" \
    "(&(objectClass=groupOfNames)(cn=app-ocp-rbac-*))" cn | grep -c "^cn:"

# List RBAC groups with descriptions
kubectl exec -n ldap-testing $LDAP_POD -- ldapsearch -x -H ldap://localhost:389 \
    -D "cn=ocp-ldap-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com" \
    -w "bindpassword123" \
    -b "ou=Groups,dc=ephico2real,dc=com" \
    "(&(objectClass=groupOfNames)(cn=app-ocp-rbac-*))" cn description

# Test access to People OU
kubectl exec -n ldap-testing $LDAP_POD -- ldapsearch -x -H ldap://localhost:389 \
    -D "cn=ocp-ldap-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com" \
    -w "bindpassword123" \
    -b "ou=People,dc=ephico2real,dc=com" \
    "(objectClass=inetOrgPerson)" cn uid mail
```

## GroupSync Secret Creation

**Note**: The target GroupSync secret (`ldap-group-sync`) will be created automatically by the Helm chart's OAuth secret extraction job. You only need to ensure the source OAuth secret exists in the `openshift-config` namespace.

```bash
# Verify the source OAuth secret exists (created by 10-setup-oauth-secrets.sh)
kubectl get secret ldap-secret -n openshift-config

# The Helm chart will automatically create ldap-group-sync secret in group-sync-operator namespace
# from the source secret during deployment
```

## Expected Results

After running the import, you should have:
- **16 RBAC groups** following the `app-ocp-rbac-*` pattern
- **5 test users** (john.doe, jane.smith, bob.wilson, alice.cooper, charlie.brown)
- **1 service account** for GroupSync authentication
- **1 non-RBAC group** (general-users) for filter testing
- **Proper ACLs** allowing the service account to read users and groups

This provides comprehensive test data matching production RBAC patterns for thorough GroupSync operator testing.
