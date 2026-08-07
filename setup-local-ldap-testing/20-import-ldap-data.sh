#!/bin/bash

# 📊 STEP 2: Import Comprehensive LDAP Data
# 
# This script imports 20+ production-pattern RBAC groups and test users
# into the OpenLDAP server, providing comprehensive test data for
# GroupSync operator validation.
#
# Purpose: Populates LDAP with realistic enterprise RBAC structure

set -e

# Anchored to this script's directory, not the caller's — the same pattern as
# 15-bootstrap-cert-manager-ca.sh. Every manifest and LDIF below used to be a bare relative path, so a run
# from anywhere but this directory aborted partway with "the path ... does not exist" — after earlier steps
# had already mutated the cluster.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Configuration variables
TMP_DIR="/tmp"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}🔧 Importing Comprehensive LDAP Structure${NC}"
echo "================================================="

# Check if LDAP pod is running
if ! kubectl get pods -n ldap-testing -l app=openldap-server --field-selector=status.phase=Running | grep -q openldap; then
    echo -e "${RED}❌ Error: OpenLDAP server pod is not running in ldap-testing namespace${NC}"
    echo "Please deploy the LDAP server first using:"
    echo "  ./30-manage-ldap-server.sh deploy-all"
    exit 1
fi

# Check if bootstrap job completed (if it exists)
if kubectl get job ldap-bootstrap-job-combined -n ldap-testing &> /dev/null; then
    BOOTSTRAP_STATUS=$(kubectl get job ldap-bootstrap-job-combined -n ldap-testing -o jsonpath='{.status.conditions[0].type}' 2>/dev/null || echo "Unknown")
    if [[ "$BOOTSTRAP_STATUS" != "Complete" && "$BOOTSTRAP_STATUS" != "SuccessCriteriaMet" ]]; then
        echo -e "${YELLOW}⚠️  Warning: Bootstrap job exists but may not be completed (status: $BOOTSTRAP_STATUS)${NC}"
        echo "This script will proceed, but ensure bootstrap completed successfully"
    else
        echo -e "${GREEN}✅ Bootstrap job completed successfully${NC}"
    fi
else
    echo -e "${YELLOW}ℹ️  Bootstrap job not found - this is okay if using manual import${NC}"
fi
echo

# Get the LDAP pod name
LDAP_POD=$(kubectl get pods -n ldap-testing -l app=openldap-server --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')

echo -e "${GREEN}✅ Found LDAP pod: $LDAP_POD${NC}"
echo

# Check if LDIF file exists
# BOTH files checked before anything is imported. The ACL preflight used to sit after the structure
# import, so a missing configure-acls.ldif left a half-imported directory: every group and user present,
# no ACLs, so the service account could not read them — which then looks like a GroupSync permissions bug.
if [[ ! -f "${SCRIPT_DIR}/configure-acls.ldif" ]]; then
    echo -e "${RED}❌ Error: configure-acls.ldif not found next to this script${NC}"
    exit 1
fi
if [[ ! -f "${SCRIPT_DIR}/ldap-structure-combined.ldif" ]]; then
    echo -e "${RED}❌ Error: ldap-structure-combined.ldif not found in current directory${NC}"
    echo "Please ensure the file exists before running this script"
    exit 1
fi
echo -e "${GREEN}✅ Found LDIF file: ldap-structure-combined.ldif${NC}"
echo

# Copy the comprehensive LDIF file to the pod
echo -e "${BLUE}📁 Copying comprehensive LDAP structure file to pod...${NC}"
kubectl cp "${SCRIPT_DIR}/ldap-structure-combined.ldif" ldap-testing/$LDAP_POD:$TMP_DIR/

# Verify file was copied
echo -e "${BLUE}🔍 Verifying file contents...${NC}"
kubectl exec -n ldap-testing $LDAP_POD -- wc -l $TMP_DIR/ldap-structure-combined.ldif
# ^dn: cn=, not a bare substring: the old pattern also matched cn:, member: and description: lines, so
# the reported count was several times the real number of groups. || true because grep -c exits 1 on zero
# matches, which is fatal in a bare assignment under set -e.
RBAC_GROUPS=$(kubectl exec -n ldap-testing $LDAP_POD -- grep -c '^dn: cn=app-ocp-rbac-' $TMP_DIR/ldap-structure-combined.ldif || true)
echo -e "${GREEN}📊 File contains $RBAC_GROUPS RBAC groups${NC}"
echo

# Import the LDAP structure
echo -e "${BLUE}🔄 Importing comprehensive LDAP structure...${NC}"
if kubectl exec -n ldap-testing $LDAP_POD -- ldapadd -x -H ldap://localhost:389 \
    -D "cn=admin,dc=ephico2real,dc=com" \
    -w "admin123" \
    -f $TMP_DIR/ldap-structure-combined.ldif 2>&1; then
    # Inside the then-branch $? is the `if` test itself, i.e. always 0 — so the warning branch that used to
    # live here could never run. ldapadd's real status is captured in the else-branch below, where a
    # non-zero exit lands. 68 (Already exists) is the one we tolerate.
    echo -e "${GREEN}✅ LDAP structure imported successfully!${NC}"
else
    LDAPADD_EXIT=$?
    if [ "$LDAPADD_EXIT" -eq 68 ]; then
        echo -e "${YELLOW}⚠️  Some entries already exist (ldapadd exit 68) — continuing${NC}"
    else
        echo -e "${RED}❌ Error: LDAP import failed with exit code $LDAPADD_EXIT${NC}"
        echo "Please check the LDAP server logs and try again"
        exit 1
    fi
fi
echo

# Configure ACLs for service account access
echo -e "${BLUE}🔐 Configuring ACLs for service account access...${NC}"

# Copy ACL configuration to pod
kubectl cp "${SCRIPT_DIR}/configure-acls.ldif" ldap-testing/$LDAP_POD:$TMP_DIR/

# Apply ACL configuration
if kubectl exec -n ldap-testing $LDAP_POD -- ldapmodify -x -H ldap://localhost:389 \
    -D "cn=admin,cn=config" \
    -w "config123" \
    -f $TMP_DIR/configure-acls.ldif 2>&1; then
    # Same as the import above: $? here is the `if` test, always 0. The real status is in the else-branch.
    echo -e "${GREEN}✅ ACLs configured successfully!${NC}"
else
    LDAPMODIFY_EXIT=$?
    echo -e "${RED}❌ Error: ACL configuration failed with exit code $LDAPMODIFY_EXIT${NC}"
    echo "Please check the LDAP server logs"
    exit 1
fi
echo

# Verification tests
echo -e "${BLUE}🧪 Running verification tests...${NC}"
echo

# Test 1: Verify service account can access Groups OU
echo -e "${YELLOW}Test 1: Service account can access Groups OU${NC}"
if kubectl exec -n ldap-testing $LDAP_POD -- ldapsearch -x -H ldap://localhost:389 \
    -D "cn=ocp-ldap-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com" \
    -w "bindpassword123" \
    -b "ou=Groups,dc=ephico2real,dc=com" \
    -s base "(objectClass=*)" dn > /dev/null 2>&1; then
    echo -e "${GREEN}✅ Service account can access Groups OU${NC}"
else
    echo -e "${RED}❌ Service account cannot access Groups OU${NC}"
fi

# Test 2: Count RBAC groups
echo -e "${YELLOW}Test 2: RBAC groups imported${NC}"
RBAC_COUNT=$(kubectl exec -n ldap-testing $LDAP_POD -- ldapsearch -x -H ldap://localhost:389 \
    -D "cn=ocp-ldap-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com" \
    -w "bindpassword123" \
    -b "ou=Groups,dc=ephico2real,dc=com" \
    "(&(objectClass=groupOfNames)(cn=app-ocp-rbac-*))" cn 2>/dev/null | grep -c "^cn:" || true)

echo -e "${GREEN}✅ Found ${RBAC_COUNT:-0} RBAC groups (app-ocp-rbac-*)${NC}"

# Test 3: List some example groups
echo -e "${YELLOW}Test 3: Example RBAC groups${NC}"
kubectl exec -n ldap-testing $LDAP_POD -- ldapsearch -x -H ldap://localhost:389 \
    -D "cn=ocp-ldap-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com" \
    -w "bindpassword123" \
    -b "ou=Groups,dc=ephico2real,dc=com" \
    "(&(objectClass=groupOfNames)(cn=app-ocp-rbac-*))" cn description 2>/dev/null | \
    grep -E "^(cn|description):" | head -10

# Test 4: Verify user access
echo
echo -e "${YELLOW}Test 4: Service account can access People OU${NC}"
USER_COUNT=$(kubectl exec -n ldap-testing $LDAP_POD -- ldapsearch -x -H ldap://localhost:389 \
    -D "cn=ocp-ldap-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com" \
    -w "bindpassword123" \
    -b "ou=People,dc=ephico2real,dc=com" \
    "(objectClass=inetOrgPerson)" cn 2>/dev/null | grep -c "^cn:" || true)

echo -e "${GREEN}✅ Found ${USER_COUNT:-0} users in People OU${NC}"

echo
echo -e "${GREEN}🎉 Import completed successfully!${NC}"
echo
echo -e "${BLUE}📋 Summary:${NC}"
echo "  ✓ Imported comprehensive LDAP structure"
echo "  ✓ Created ${RBAC_COUNT:-0} RBAC groups (app-ocp-rbac-*)"  
echo "  ✓ Created ${USER_COUNT:-0} test users"
echo "  ✓ Configured service account ACLs"
echo "  ✓ Verified GroupSync service account access"
echo
echo -e "${BLUE}🚀 Ready for GroupSync testing!${NC}"
echo "The LDAP server now contains the same comprehensive structure"
echo "that the bootstrap job would create, including all production-pattern"
echo "RBAC groups for complete GroupSync operator testing."