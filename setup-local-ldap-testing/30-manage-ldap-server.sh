#!/bin/bash

# 🔧 LDAP Server Management and Operations
# 
# Comprehensive management script for the local OpenLDAP server used
# in GroupSync operator testing. Provides deployment, monitoring, 
# testing, and troubleshooting capabilities.
#
# Purpose: Complete lifecycle management of the test LDAP server

set -e

# Anchored to this script's directory, not the caller's — the same pattern as
# 15-bootstrap-cert-manager-ca.sh. Every manifest and LDIF below used to be a bare relative path, so a run
# from anywhere but this directory aborted partway with "the path ... does not exist" — after earlier steps
# had already mutated the cluster.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="ldap-testing"
LDAP_SERVICE="openldap-service"
LDAP_POD_LABEL="app=openldap-server"
LDAP_ADMIN_DN="cn=admin,dc=ephico2real,dc=com"
LDAP_ADMIN_PASSWORD="admin123"
LDAP_BIND_DN="cn=ocp-ldap-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com"
LDAP_BIND_PASSWORD="bindpassword123"

function print_usage() {
    echo -e "${BLUE}LDAP Server Management Script${NC}"
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  bootstrap    Run bootstrap job (step 1 - run this first)"
    echo "  deploy       Deploy the LDAP server (step 2 - run after bootstrap)"
    echo "  deploy-all   Run bootstrap + deploy in sequence"
    echo "  delete       Delete LDAP server (preserves namespace)"
    echo "  delete-all   Delete everything including namespace"
    echo "  status       Show LDAP server status"
    echo "  test         Test LDAP connectivity"
    echo "  test-ldaps   Test LDAPS (SSL/TLS) connectivity"
    echo "  ca-cert-extract Extract LDAPS SSL cert to ConfigMap for group sync"
    echo "  query        Query LDAP for groups and users"
    echo "  logs         Show LDAP server logs"
    echo "  shell        Open shell in LDAP container"
    echo "  port-forward Start port forwarding (ldap:1389, ldaps:1636)"
    echo "  web          Deploy phpLDAPadmin web interface"
    echo "  web-url      Get phpLDAPadmin web interface URL"
    echo "  web-delete   Remove phpLDAPadmin web interface"
    echo "  clean-restart Clean restart LDAP (fixes restart issues)"
    echo "  help         Show this help message"
    echo ""
}

function bootstrap_ldap() {
    echo -e "${GREEN}🚀 Running LDAP Bootstrap (Step 1)...${NC}"
    
    echo -e "${BLUE}Deploying bootstrap job and prerequisites...${NC}"
    kubectl apply -f "${SCRIPT_DIR}/03-ldap-bootstrap-job.yaml"
    
    echo -e "${BLUE}Creating ConfigMaps from standalone LDIF files...${NC}"
    kubectl create configmap ldap-structure --from-file="${SCRIPT_DIR}/ldap-structure-combined.ldif" -n $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
    kubectl create configmap ldap-acls --from-file="${SCRIPT_DIR}/configure-acls.ldif" -n $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
    echo -e "${GREEN}✅ ConfigMaps created from standalone files${NC}"
    
    echo -e "${YELLOW}⏳ Waiting for bootstrap job to complete...${NC}"
    kubectl wait --for=condition=complete --timeout=120s job/ldap-bootstrap-job-combined -n $NAMESPACE
    
    echo -e "${GREEN}✅ Bootstrap completed! Checking bootstrap logs...${NC}"
    kubectl logs job/ldap-bootstrap-job-combined -n $NAMESPACE
    echo ""
    
    echo -e "${GREEN}✅ Bootstrap completed successfully!${NC}"
    echo -e "${YELLOW}👉 Next step: Run './30-manage-ldap-server.sh deploy' to deploy the LDAP server${NC}"
}

function deploy_ldap() {
    echo -e "${GREEN}🚀 Deploying LDAP Server (Step 2)...${NC}"
    
    # Check if bootstrap job exists and completed
    if ! kubectl get job ldap-bootstrap-job-combined -n $NAMESPACE >/dev/null 2>&1; then
        echo -e "${RED}⚠️  Bootstrap job not found!${NC}"
        echo -e "${YELLOW}👉 Please run './30-manage-ldap-server.sh bootstrap' first${NC}"
        return 1
    fi
    
    BOOTSTRAP_STATUS=$(kubectl get job ldap-bootstrap-job-combined -n $NAMESPACE -o jsonpath='{.status.conditions[0].type}' 2>/dev/null || echo "Unknown")
    if [[ "$BOOTSTRAP_STATUS" != "Complete" && "$BOOTSTRAP_STATUS" != "SuccessCriteriaMet" ]]; then
        echo -e "${RED}⚠️  Bootstrap job not completed (status: $BOOTSTRAP_STATUS)!${NC}"
        echo -e "${YELLOW}👉 Please run './30-manage-ldap-server.sh bootstrap' first${NC}"
        return 1
    fi
    
    echo -e "${BLUE}Deploying LDAP server...${NC}"
    kubectl apply -f "${SCRIPT_DIR}/01-ldap-server.yaml"
    
    echo -e "${YELLOW}⏳ Waiting for LDAP server to be ready...${NC}"
    kubectl wait --for=condition=available --timeout=300s deployment/openldap-server -n $NAMESPACE
    
    echo -e "${BLUE}Deploying phpLDAPadmin web GUI...${NC}"
    kubectl apply -f "${SCRIPT_DIR}/02-phpldapadmin.yaml"
    
    echo -e "${GREEN}✅ LDAP Server and Web GUI deployed successfully!${NC}"
    echo ""
    show_status
}

function deploy_all() {
    echo -e "${GREEN}🚀 Deploying LDAP Server (Full Process)...${NC}"
    echo -e "${BLUE}Running bootstrap + deploy in sequence...${NC}"
    echo ""
    
    # Step 1: Run bootstrap
    bootstrap_ldap
    
    # Step 2: Validate bootstrap completion before proceeding
    echo -e "${YELLOW}⏳ Validating bootstrap completion...${NC}"
    if ! kubectl get job ldap-bootstrap-job-combined -n $NAMESPACE >/dev/null 2>&1; then
        echo -e "${RED}⚠️  Bootstrap job not found after bootstrap step!${NC}"
        return 1
    fi
    
    # Extra wait to ensure job is fully completed
    kubectl wait --for=condition=complete --timeout=60s job/ldap-bootstrap-job-combined -n $NAMESPACE
    
    BOOTSTRAP_STATUS=$(kubectl get job ldap-bootstrap-job-combined -n $NAMESPACE -o jsonpath='{.status.conditions[0].type}' 2>/dev/null || echo "Unknown")
    if [[ "$BOOTSTRAP_STATUS" != "Complete" && "$BOOTSTRAP_STATUS" != "SuccessCriteriaMet" ]]; then
        echo -e "${RED}⚠️  Bootstrap job failed (status: $BOOTSTRAP_STATUS)!${NC}"
        echo "Bootstrap job logs:"
        kubectl logs job/ldap-bootstrap-job-combined -n $NAMESPACE
        return 1
    fi
    
    echo -e "${GREEN}✅ Bootstrap validated successfully!${NC}"
    echo ""
    
    # Step 3: Deploy LDAP server
    deploy_ldap
}

function delete_ldap() {
    confirm_destructive "This deletes the LDAP server and its PVC — the directory contents are lost."
    echo -e "${RED}🗑️  Deleting LDAP Server (preserving namespace)...${NC}"
    kubectl delete -f "${SCRIPT_DIR}/01-ldap-server.yaml" --ignore-not-found=true
    kubectl delete -f "${SCRIPT_DIR}/02-phpldapadmin.yaml" --ignore-not-found=true
    # Only delete bootstrap job components, not the namespace
    kubectl delete job ldap-bootstrap-job-combined -n $NAMESPACE --ignore-not-found=true
    kubectl delete pvc ldap-data-pvc -n $NAMESPACE --ignore-not-found=true
    kubectl delete configmap ldap-bootstrap-ldif -n $NAMESPACE --ignore-not-found=true
    kubectl delete serviceaccount openldap-server -n $NAMESPACE --ignore-not-found=true
    kubectl delete rolebinding ldap-privileged-binding -n $NAMESPACE --ignore-not-found=true
    echo -e "${GREEN}✅ LDAP Server and Web GUI deleted! (namespace preserved)${NC}"
    echo -e "${YELLOW}💡 To delete everything including namespace, use: ./30-manage-ldap-server.sh delete-all${NC}"
}

# Prompted, like clean_restart. This deletes the namespace, which takes the directory and every synced
# group with it — the same class of action, so the same confirmation.
function confirm_destructive() {
    echo -e "${RED}⚠️  $1${NC}"
    read -p "Are you sure you want to continue? [y/N] " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || { echo "aborted"; exit 0; }
}

function delete_all() {
    confirm_destructive "This deletes namespace $NAMESPACE — the LDAP directory and all synced groups."
    echo -e "${RED}🗑️  Deleting Everything (including namespace)...${NC}"
    echo -e "${YELLOW}⚠️  This will completely remove the $NAMESPACE namespace and all resources!${NC}"
    echo ""
    
    # Delete all YAML resources first
    echo -e "${BLUE}Deleting LDAP resources...${NC}"
    kubectl delete -f "${SCRIPT_DIR}/01-ldap-server.yaml" --ignore-not-found=true
    kubectl delete -f "${SCRIPT_DIR}/02-phpldapadmin.yaml" --ignore-not-found=true
    kubectl delete -f "${SCRIPT_DIR}/03-ldap-bootstrap-job.yaml" --ignore-not-found=true
    
    # Delete any remaining resources in the namespace
    echo -e "${BLUE}Deleting remaining namespace resources...${NC}"
    kubectl delete job ldap-bootstrap-job-combined -n $NAMESPACE --ignore-not-found=true
    kubectl delete configmap ldap-structure ldap-acls -n $NAMESPACE --ignore-not-found=true
    kubectl delete pvc --all -n $NAMESPACE --ignore-not-found=true
    kubectl delete secret --all -n $NAMESPACE --ignore-not-found=true
    
    # Delete the entire namespace
    echo -e "${BLUE}Deleting namespace: $NAMESPACE${NC}"
    kubectl delete namespace $NAMESPACE --ignore-not-found=true
    
    echo -e "${GREEN}✅ Everything deleted including namespace!${NC}"
    echo -e "${YELLOW}💡 To recreate the environment, run: ./30-manage-ldap-server.sh deploy-all${NC}"
}

function show_status() {
    echo -e "${BLUE}📊 LDAP Server Status:${NC}"
    echo ""
    
    echo "Namespace:"
    kubectl get namespace $NAMESPACE 2>/dev/null || echo "  Namespace not found"
    echo ""
    
    echo "Pods:"
    kubectl get pods -n $NAMESPACE -l $LDAP_POD_LABEL 2>/dev/null || echo "  No pods found"
    echo ""
    
    echo "Service:"
    kubectl get service $LDAP_SERVICE -n $NAMESPACE 2>/dev/null || echo "  Service not found"
    echo ""
    
    echo "PVC:"
    kubectl get pvc -n $NAMESPACE 2>/dev/null || echo "  No PVCs found"
    echo ""
    
    echo "Bootstrap Job:"
    kubectl get job ldap-bootstrap-job-combined -n $NAMESPACE 2>/dev/null || echo "  Bootstrap job not found"
    echo ""
    
    # Check for phpLDAPadmin components
    echo "phpLDAPadmin Components:"
    PHPLDAP_POD=$(kubectl get pods -n $NAMESPACE -l app=phpldapadmin 2>/dev/null)
    if [ -n "$PHPLDAP_POD" ]; then
        kubectl get pods -n $NAMESPACE -l app=phpldapadmin 2>/dev/null
        echo ""
        echo "phpLDAPadmin Service:"
        kubectl get service phpldapadmin-service -n $NAMESPACE 2>/dev/null || echo "  Service not found"
        echo ""
        echo "phpLDAPadmin Route:"
        ROUTE_INFO=$(kubectl get route phpldapadmin-route -n $NAMESPACE 2>/dev/null)
        if [ -n "$ROUTE_INFO" ]; then
            echo "$ROUTE_INFO"
            ROUTE_URL=$(kubectl get route phpldapadmin-route -n $NAMESPACE -o jsonpath='{.spec.host}' 2>/dev/null)
            if [ -n "$ROUTE_URL" ]; then
                echo -e "  ${GREEN}🔗 Access URL: http://$ROUTE_URL${NC}"
            fi
        else
            echo "  Route not found"
        fi
    else
        echo "  phpLDAPadmin not deployed"
    fi
    echo ""
}

function test_connectivity() {
    echo -e "${BLUE}🔍 Testing LDAP Connectivity...${NC}"
    
    # Check if pod is running
    if ! kubectl get pods -n $NAMESPACE -l $LDAP_POD_LABEL | grep -q Running; then
        echo -e "${RED}❌ LDAP pod is not running${NC}"
        return 1
    fi
    
    # Test basic LDAP connection
    echo "Testing basic LDAP connection..."
            # set +e around the probe: with errexit on, a failing kubectl exec killed the script at the command
        # and the test below never ran — so every error branch in this function was dead code.
        set +e
    kubectl exec -n $NAMESPACE deployment/openldap-server -- \
        ldapsearch -x -H ldap://localhost:389 \
        -D "$LDAP_ADMIN_DN" \
        -w "$LDAP_ADMIN_PASSWORD" \
        -b "dc=ephico2real,dc=com" \
        -s base "(objectclass=*)" dn
    rc=$?
    set -e
    
    if [ "$rc" -eq 0 ]; then
        echo -e "${GREEN}✅ LDAP connection successful!${NC}"
    else
        echo -e "${RED}❌ LDAP connection failed${NC}"
        return 1
    fi
    
    # Test service account binding
    echo ""
    echo "Testing service account binding..."
    # Test with a simple bind operation followed by a who am I request
    set +e
    kubectl exec -n $NAMESPACE deployment/openldap-server -- \
        ldapwhoami -x -H ldap://localhost:389 \
        -D "$LDAP_BIND_DN" \
        -w "$LDAP_BIND_PASSWORD"
    rc=$?
    set -e
    
    if [ "$rc" -eq 0 ]; then
        echo -e "${GREEN}✅ Service account binding successful!${NC}"
        
        # Test service account can read organizational units
        echo "Testing service account read permissions..."
        set +e
        kubectl exec -n $NAMESPACE deployment/openldap-server -- \
            ldapsearch -x -H ldap://localhost:389 \
            -D "$LDAP_BIND_DN" \
            -w "$LDAP_BIND_PASSWORD" \
            -b "ou=Groups,dc=ephico2real,dc=com" \
            -s base "(objectclass=*)" dn 2>/dev/null
        rc=$?
        set -e
        
        if [ "$rc" -eq 0 ]; then
            echo -e "${GREEN}✅ Service account has read permissions!${NC}"
        else
            echo -e "${YELLOW}⚠️  Service account binding works but limited read permissions${NC}"
        fi
    else
        echo -e "${RED}❌ Service account binding failed${NC}"
        return 1
    fi
}

function test_ldaps_connectivity() {
    echo -e "${BLUE}🔐 Testing LDAPS (SSL/TLS) Connectivity...${NC}"
    
    # Check if pod is running
    if ! kubectl get pods -n $NAMESPACE -l $LDAP_POD_LABEL | grep -q Running; then
        echo -e "${RED}❌ LDAP pod is not running${NC}"
        return 1
    fi
    
    # Test LDAPS connection (with TLS)
    echo "Testing LDAPS connection (port 636)..."
    set +e
    kubectl exec -n $NAMESPACE deployment/openldap-server -- \
        ldapsearch -x -H ldaps://localhost:636 \
        -D "$LDAP_ADMIN_DN" \
        -w "$LDAP_ADMIN_PASSWORD" \
        -b "dc=ephico2real,dc=com" \
        -s base "(objectclass=*)" dn
    rc=$?
    set -e
    
    if [ "$rc" -eq 0 ]; then
        echo -e "${GREEN}✅ LDAPS connection successful!${NC}"
    else
        echo -e "${RED}❌ LDAPS connection failed${NC}"
        echo "Trying with certificate verification disabled..."
        
        # Try with certificate verification disabled
        set +e
        kubectl exec -n $NAMESPACE deployment/openldap-server -- \
            ldapsearch -x -H ldaps://localhost:636 \
            -D "$LDAP_ADMIN_DN" \
            -w "$LDAP_ADMIN_PASSWORD" \
            -b "dc=ephico2real,dc=com" \
            -s base "(objectclass=*)" dn \
            -o ldif-wrap=no \
            -o tls_reqcert=never
        rc=$?
        set -e
        
        if [ "$rc" -eq 0 ]; then
            echo -e "${YELLOW}⚠️  LDAPS works but with self-signed certificates${NC}"
        else
            echo -e "${RED}❌ LDAPS connection failed completely${NC}"
            return 1
        fi
    fi
    
    # Test service account binding over LDAPS
    echo ""
    echo "Testing service account binding over LDAPS..."
    set +e
    kubectl exec -n $NAMESPACE deployment/openldap-server -- \
        ldapwhoami -x -H ldaps://localhost:636 \
        -D "$LDAP_BIND_DN" \
        -w "$LDAP_BIND_PASSWORD"
    rc=$?
    set -e
    
    if [ "$rc" -eq 0 ]; then
        echo -e "${GREEN}✅ Service account LDAPS binding successful!${NC}"
        
        # Test reading data over LDAPS
        echo "Testing service account read permissions over LDAPS..."
        set +e
        kubectl exec -n $NAMESPACE deployment/openldap-server -- \
            ldapsearch -x -H ldaps://localhost:636 \
            -D "$LDAP_BIND_DN" \
            -w "$LDAP_BIND_PASSWORD" \
            -b "ou=People,dc=ephico2real,dc=com" \
            "(cn=john.doe)" cn mail 2>/dev/null
        rc=$?
        set -e
        
        if [ "$rc" -eq 0 ]; then
            echo -e "${GREEN}✅ Service account can read data over LDAPS!${NC}"
        else
            echo -e "${YELLOW}⚠️  Service account LDAPS binding works but limited read permissions${NC}"
        fi
    else
        echo -e "${RED}❌ Service account LDAPS binding failed${NC}"
        return 1
    fi
    
    # Show TLS certificate information
    echo ""
    echo "TLS Certificate Information:"
    kubectl exec -n $NAMESPACE deployment/openldap-server -- \
        openssl s_client -connect localhost:636 -showcerts < /dev/null 2>/dev/null | \
        openssl x509 -noout -text 2>/dev/null | \
        grep -E "(Subject:|Issuer:|Not Before|Not After)"
    
    echo ""
    echo -e "${BLUE}LDAPS URLs for external access:${NC}"
    echo "  Internal: ldaps://openldap-service.ldap-testing.svc.cluster.local:636"
    echo "  External: ldaps://ldap-route-ldap-testing.apps-crc.testing (via route)"
    echo ""
    echo -e "${YELLOW}Note: For production use, consider configuring proper SSL certificates${NC}"
}

function extract_ca_cert() {
    echo -e "${BLUE}🔐 Extracting LDAPS SSL Certificate...${NC}"
    
    # Check if pod is running
    if ! kubectl get pods -n $NAMESPACE -l $LDAP_POD_LABEL | grep -q Running; then
        echo -e "${RED}❌ LDAP pod is not running${NC}"
        return 1
    fi
    
    # Test LDAPS connectivity first
    echo "Testing LDAPS connectivity..."
    set +e
    kubectl exec -n $NAMESPACE deployment/openldap-server -- \
        openssl s_client -connect localhost:636 -showcerts < /dev/null > /dev/null 2>&1
    rc=$?
    set -e
    
    if [ "$rc" -ne 0 ]; then
        echo -e "${RED}❌ Cannot connect to LDAPS server${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ LDAPS connection verified${NC}"
    
    # Extract the certificate
    echo "Extracting SSL certificate..."
    CERT_DATA=$(kubectl exec -n $NAMESPACE deployment/openldap-server -- \
        openssl s_client -connect localhost:636 -showcerts < /dev/null 2>/dev/null | \
        openssl x509 -outform PEM 2>/dev/null)
    
    if [ -z "$CERT_DATA" ]; then
        echo -e "${RED}❌ Failed to extract certificate${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ Certificate extracted successfully${NC}"
    
    # Show certificate information
    echo ""
    echo "Certificate Information:"
    echo "$CERT_DATA" | openssl x509 -noout -text 2>/dev/null | \
        grep -E "(Subject:|Issuer:|Not Before|Not After)" | sed 's/^/  /'
    
    # Create ConfigMap in openshift-config namespace
    echo ""
    echo "Creating ConfigMap 'ca-config-map-test' in 'openshift-config' namespace..."
    
    # One atomic apply, the same idiom this script already uses for the LDIF ConfigMaps. The old form
    # deleted the ConfigMap and then created it, leaving a window in which openshift-config had no CA at
    # all — during which anything reconciling against it fails with "ConfigMap ... not found". It also
    # created the openshift-config namespace if absent, which on a real cluster means the script is
    # running somewhere it should not be; that is now a hard stop instead.
    if ! kubectl get namespace openshift-config > /dev/null 2>&1; then
        echo -e "${RED}❌ namespace openshift-config not found — is this an OpenShift cluster?${NC}"
        return 1
    fi

    if kubectl create configmap ca-config-map-test \
        --from-literal=ca.crt="$CERT_DATA" \
        -n openshift-config --dry-run=client -o yaml | kubectl apply -f -; then
        echo -e "${GREEN}✅ ConfigMap 'ca-config-map-test' created successfully!${NC}"
        
        # Show ConfigMap details
        echo ""
        echo "ConfigMap Details:"
        kubectl get configmap ca-config-map-test -n openshift-config -o yaml | \
            grep -E "(name:|namespace:|ca.crt:)" | sed 's/^/  /'
        
        echo ""
        echo -e "${BLUE}📋 Usage for Group Sync:${NC}"
        echo "  ConfigMap Name: ca-config-map-test"
        echo "  Namespace: openshift-config"
        echo "  Key: ca.crt"
        echo "  LDAPS URL: ldaps://openldap-service.ldap-testing.svc.cluster.local:636"
        echo ""
        echo -e "${YELLOW}💡 Example LDAP sync configuration:${NC}"
        cat << 'EOF'
  ldapClientConfig:
    url: ldaps://openldap-service.ldap-testing.svc.cluster.local:636
    bindDN: cn=ocp-ldap-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com
    bindPassword:
      name: ldap-bind-password-secret
      key: bindPassword
    ca:
      name: ca-config-map-test
      key: ca.crt
EOF
    else
        echo -e "${RED}❌ Failed to create ConfigMap${NC}"
        return 1
    fi
}

function query_ldap() {
    echo -e "${BLUE}🔍 Querying LDAP Directory...${NC}"
    
    # Check if pod is running
    if ! kubectl get pods -n $NAMESPACE -l $LDAP_POD_LABEL | grep -q Running; then
        echo -e "${RED}❌ LDAP pod is not running${NC}"
        return 1
    fi
    
    echo "All Organizational Units:"
    kubectl exec -n $NAMESPACE deployment/openldap-server -- \
        ldapsearch -x -H ldap://localhost:389 \
        -D "$LDAP_ADMIN_DN" \
        -w "$LDAP_ADMIN_PASSWORD" \
        -b "dc=ephico2real,dc=com" \
        -s one "(objectClass=organizationalUnit)" dn
    
    echo ""
    echo "All Users:"
    kubectl exec -n $NAMESPACE deployment/openldap-server -- \
        ldapsearch -x -H ldap://localhost:389 \
        -D "$LDAP_ADMIN_DN" \
        -w "$LDAP_ADMIN_PASSWORD" \
        -b "ou=People,dc=ephico2real,dc=com" \
        "(objectClass=inetOrgPerson)" cn mail
    
    echo ""
    echo "All Groups:"
    kubectl exec -n $NAMESPACE deployment/openldap-server -- \
        ldapsearch -x -H ldap://localhost:389 \
        -D "$LDAP_ADMIN_DN" \
        -w "$LDAP_ADMIN_PASSWORD" \
        -b "ou=Groups,dc=ephico2real,dc=com" \
        "(objectClass=groupOfNames)" cn description member
    
    echo ""
    echo "OpenShift RBAC Groups (filtered):"
    kubectl exec -n $NAMESPACE deployment/openldap-server -- \
        ldapsearch -x -H ldap://localhost:389 \
        -D "$LDAP_BIND_DN" \
        -w "$LDAP_BIND_PASSWORD" \
        -b "ou=Groups,dc=ephico2real,dc=com" \
        "(&(objectClass=groupOfNames)(cn=app-ocp-rbac-*))" cn description member
}

function show_logs() {
    echo -e "${BLUE}📋 LDAP Server Logs:${NC}"
    kubectl logs -n $NAMESPACE deployment/openldap-server --tail=50 -f
}

function open_shell() {
    echo -e "${BLUE}🐚 Opening shell in LDAP container...${NC}"
    kubectl exec -it -n $NAMESPACE deployment/openldap-server -- /bin/bash
}

function port_forward() {
    echo -e "${BLUE}🔀 Starting port forwarding...${NC}"
    echo "LDAP will be available at:"
    echo "  ldap://localhost:1389"
    echo "  ldaps://localhost:1636"
    echo ""
    echo "Press Ctrl+C to stop port forwarding"
    kubectl port-forward -n $NAMESPACE service/$LDAP_SERVICE 1389:389 1636:636
}

function deploy_web() {
    echo -e "${GREEN}🌐 Deploying phpLDAPadmin Web Interface...${NC}"
    # 02-phpldapadmin.yaml, and no separate RBAC manifest: `ldap-rbac.yaml` and `phpldapadmin.yaml` have
    # never existed in this directory, so both of these aborted under set -e before printing anything.
    kubectl apply -f "${SCRIPT_DIR}/02-phpldapadmin.yaml"
    
    echo -e "${YELLOW}⏳ Waiting for phpLDAPadmin to be ready...${NC}"
    kubectl wait --for=condition=available --timeout=300s deployment/phpldapadmin -n $NAMESPACE
    
    echo -e "${GREEN}✅ phpLDAPadmin deployed successfully!${NC}"
    echo ""
    get_web_url
}

function get_web_url() {
    echo -e "${BLUE}🌐 phpLDAPadmin Web Interface:${NC}"
    
    # Get the route URL
    ROUTE_URL=$(kubectl get route phpldapadmin-route -n $NAMESPACE -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    
    if [ -n "$ROUTE_URL" ]; then
        echo "🔗 URL: http://$ROUTE_URL"
        echo ""
        echo "Login Credentials:"
        echo "  Login DN: cn=admin,dc=ephico2real,dc=com"
        echo "  Password: admin123"
        echo ""
        echo "💡 You can also use port-forwarding:"
        echo "  kubectl port-forward -n $NAMESPACE service/phpldapadmin-service 8080:80"
        echo "  Then access: http://localhost:8080"
    else
        echo "❌ Route not found. Use port-forwarding instead:"
        echo "  kubectl port-forward -n $NAMESPACE service/phpldapadmin-service 8080:80"
        echo "  Then access: http://localhost:8080"
    fi
}

function delete_web() {
    echo -e "${RED}🗑️  Deleting phpLDAPadmin Web Interface...${NC}"
    kubectl delete -f "${SCRIPT_DIR}/02-phpldapadmin.yaml" --ignore-not-found=true
    echo -e "${GREEN}✅ phpLDAPadmin deleted!${NC}"
}

function clean_restart() {
    echo -e "${YELLOW}🔄 Performing clean restart of LDAP server...${NC}"
    echo "This will:"
    echo "  1. Stop the current LDAP deployment"
    echo "  2. Clear the persistent volume data"
    echo "  3. Restart with fresh configuration"
    echo ""
    read -p "Are you sure you want to continue? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Clean restart cancelled."
        return 0
    fi
    
    echo -e "${BLUE}Step 1: Stopping LDAP deployment...${NC}"
    kubectl scale deployment openldap-server -n $NAMESPACE --replicas=0
    kubectl wait --for=delete pod -l app=openldap-server -n $NAMESPACE --timeout=60s
    
    echo -e "${BLUE}Step 2: Clearing persistent volume data...${NC}"
    # Create a temporary pod to clean PVC
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pvc-cleaner
  namespace: $NAMESPACE
spec:
  restartPolicy: Never
  containers:
  - name: cleaner
    image: registry.redhat.io/ubi8/ubi-minimal:latest
    command: ['sh', '-c', 'rm -rf /data/* && echo "PVC cleaned successfully"']
    volumeMounts:
    - name: ldap-data
      mountPath: /data
  volumes:
  - name: ldap-data
    persistentVolumeClaim:
      claimName: ldap-data-pvc
EOF
    
    # Succeeded, NOT Ready. pvc-cleaner is restartPolicy: Never running a single `rm -rf`, so it goes
    # straight to Succeeded and Ready never becomes true — the old --for=condition=ready burned the full
    # 60s, exited 1, and set -e killed the script here, leaving the deployment scaled to 0 with a wiped
    # PVC. The trap guarantees the scale-back happens even if the cleaner fails.
    trap 'kubectl scale deployment openldap-server -n $NAMESPACE --replicas=1 >/dev/null 2>&1 || true' RETURN
    kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod pvc-cleaner -n $NAMESPACE --timeout=60s
    kubectl logs pvc-cleaner -n $NAMESPACE
    kubectl delete pod pvc-cleaner -n $NAMESPACE
    
    echo -e "${BLUE}Step 3: Restarting LDAP deployment...${NC}"
    kubectl scale deployment openldap-server -n $NAMESPACE --replicas=1
    
    echo -e "${YELLOW}⏳ Waiting for LDAP server to be ready...${NC}"
    kubectl wait --for=condition=available --timeout=300s deployment/openldap-server -n $NAMESPACE
    
    echo -e "${GREEN}✅ Clean restart completed successfully!${NC}"
    echo -e "${YELLOW}⚠️  The directory is now EMPTY — this wiped the PVC and did not re-import.${NC}"
    echo -e "${YELLOW}    Run ./20-import-ldap-data.sh to repopulate, or every synced group stays gone.${NC}"
    echo ""
    show_status
}

# Main script logic
case "${1:-help}" in
    bootstrap)
        bootstrap_ldap
        ;;
    deploy)
        deploy_ldap
        ;;
    deploy-all)
        deploy_all
        ;;
    delete)
        delete_ldap
        ;;
    delete-all)
        delete_all
        ;;
    status)
        show_status
        ;;
    test)
        test_connectivity
        ;;
    test-ldaps)
        test_ldaps_connectivity
        ;;
    ca-cert-extract)
        extract_ca_cert
        ;;
    query)
        query_ldap
        ;;
    logs)
        show_logs
        ;;
    shell)
        open_shell
        ;;
    port-forward)
        port_forward
        ;;
    web)
        deploy_web
        ;;
    web-url)
        get_web_url
        ;;
    web-delete)
        delete_web
        ;;
    clean-restart)
        clean_restart
        ;;
    help|--help|-h)
        print_usage
        ;;
    *)
        echo -e "${RED}❌ Unknown command: $1${NC}"
        echo ""
        print_usage
        exit 1
        ;;
esac

