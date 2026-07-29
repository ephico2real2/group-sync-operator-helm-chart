#!/bin/bash

set -e

# 🎯 LDAP Operations Simulation and GroupSync Testing
# 
# This script simulates real-world LDAP operations to test GroupSync
# operator behavior with dynamic changes like new hires, role changes,
# departures, and organizational restructuring.
#
# Purpose: Validate GroupSync handles LDAP changes correctly

# Configuration variables
NAMESPACE="ldap-testing"
TMP_DIR="/tmp"
LDAP_ADMIN_DN="cn=admin,dc=ephico2real,dc=com"
LDAP_ADMIN_PASSWORD="admin123"
LDAP_SERVICE_DN="cn=ocp-ldap-bind-serviceid,ou=TrustedApplications,dc=ephico2real,dc=com"
LDAP_SERVICE_PASSWORD="bindpassword123"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Get LDAP pod
get_ldap_pod() {
    kubectl get pods -n $NAMESPACE -l app=openldap-server --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}

# Validate user exists in LDAP
# Count LDAP entries matching a base + filter, printed on stdout.
# CRITICAL GOTCHA: ldapsearch exits 0 for a SUCCESSFUL search even when it returns
# ZERO entries. So "if ldapsearch ...; then exists" is always true — callers must
# count returned entries (^dn: lines), never trust $?. This helper is the single
# correct primitive for every "does X match" check below.
ldap_count() {
    local base="$1" filter="$2"
    local LDAP_POD=$(get_ldap_pod)
    kubectl exec -n $NAMESPACE $LDAP_POD -- ldapsearch -x -H ldap://localhost:389 \
        -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" -LLL \
        -b "$base" "$filter" dn 2>/dev/null | grep -c "^dn:"
}

# Resolve a user's REAL DN by uid. Handles both conventions in this demo directory:
# seed users are cn=-based (cn=john.doe,...), script-created users are uid=-based
# (uid=sarah.jones,...). The operator matches group members to users by DN, so the
# member value must be the user's ACTUAL DN — never an assumed uid=/cn= shape.
# Prints the DN on stdout, or nothing if the user is not found.
resolve_user_dn() {
    local username="$1"
    local LDAP_POD=$(get_ldap_pod)
    kubectl exec -n $NAMESPACE $LDAP_POD -- ldapsearch -x -H ldap://localhost:389 \
        -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" -LLL \
        -b "ou=People,dc=ephico2real,dc=com" "(uid=$username)" dn 2>/dev/null \
        | awk '/^dn: /{print substr($0,5); exit}'
}

validate_user_exists() {
    local username="$1"
    # Match by the uid attribute across the People subtree — handles both cn=- and
    # uid=-based user DNs.
    [ "$(ldap_count "ou=People,dc=ephico2real,dc=com" "(uid=$username)")" -gt 0 ]
}

# Validate group exists in LDAP
validate_group_exists() {
    local groupname="$1"
    [ "$(ldap_count "ou=Groups,dc=ephico2real,dc=com" "(cn=$groupname)")" -gt 0 ]
}

# Validate user is member of group
validate_user_in_group() {
    local username="$1"
    local groupname="$2"
    local user_dn=$(resolve_user_dn "$username")
    [ -z "$user_dn" ] && return 1
    [ "$(ldap_count "cn=$groupname,ou=Groups,dc=ephico2real,dc=com" "(member=$user_dn)")" -gt 0 ]
}

# Show group membership details
show_group_members() {
    local groupname="$1"
    local LDAP_POD=$(get_ldap_pod)
    
    echo -e "${BLUE}👥 Current members of $groupname:${NC}"
    local members=$(kubectl exec -n $NAMESPACE $LDAP_POD -- ldapsearch -x -H ldap://localhost:389 \
        -D "$LDAP_SERVICE_DN" -w "$LDAP_SERVICE_PASSWORD" \
        -b "cn=$groupname,ou=Groups,dc=ephico2real,dc=com" \
        member 2>/dev/null | grep "^member:" | sed -E 's/member: (uid|cn)=//g' | sed 's/,ou=People,dc=ephico2real,dc=com//g' | tr '\n' ', ' | sed 's/,$//')
    
    if [ -n "$members" ]; then
        echo -e "   $members"
    else
        echo -e "   ${YELLOW}No members found${NC}"
    fi
    echo
}

# Force GroupSync to sync immediately
force_groupsync() {
    # Optional $1 = GroupSync CR name (defaults to the primary CR). Patching any
    # annotation triggers the operator to reconcile that CR immediately.
    local cr_name="${1:-ldap-groupsync}"
    echo -e "${CYAN}🔄 Forcing GroupSync '${cr_name}' to sync...${NC}"
    TIMESTAMP="manual-sync-$(date +%s)"
    kubectl patch groupsync "$cr_name" -n group-sync-operator --type='merge' -p="{\"metadata\":{\"annotations\":{\"sync.redhatcop.redhat.io/sync-now\":\"$TIMESTAMP\"}}}" >/dev/null 2>&1

    echo "⏳ Waiting for sync to complete (10 seconds)..."
    sleep 10
    echo -e "${GREEN}✅ GroupSync '${cr_name}' triggered${NC}"
}

# Check OpenShift groups before/after. Optional $2 = grep pattern (default app-ocp-rbac).
check_openshift_groups() {
    local operation="$1"
    local pattern="${2:-app-ocp-rbac}"
    echo -e "${BLUE}📊 OpenShift RBAC Groups $operation (matching '${pattern}'):${NC}"
    oc get groups 2>/dev/null | grep -E "${pattern}|NAME" | head -20 || echo "   No RBAC groups found"
    echo
}

# Add new user to LDAP
add_user() {
    local username="$1"
    local fullname="$2" 
    local email="$3"
    local LDAP_POD=$(get_ldap_pod)
    
    if [ -z "$LDAP_POD" ]; then
        echo -e "${RED}❌ LDAP pod not found${NC}"
        return 1
    fi
    
    echo -e "${GREEN}👤 Adding new user: $username${NC}"
    
    # Create LDIF for new user
    cat > /tmp/new_user.ldif << EOF
dn: uid=$username,ou=People,dc=ephico2real,dc=com
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: $username
cn: $fullname
sn: $(echo $fullname | awk '{print $NF}')
givenName: $(echo $fullname | awk '{print $1}')
mail: $email
userPassword: newuser123
uidNumber: $((1000 + RANDOM % 9000))
gidNumber: 1000
homeDirectory: /home/$username
loginShell: /bin/bash
EOF
    
    kubectl cp /tmp/new_user.ldif $NAMESPACE/$LDAP_POD:$TMP_DIR/
    
    if kubectl exec -n $NAMESPACE $LDAP_POD -- ldapadd -x -H ldap://localhost:389 \
        -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" \
        -f $TMP_DIR/new_user.ldif >/dev/null 2>&1; then
        echo -e "${GREEN}✅ User $username added successfully${NC}"
        
        # Validate the user was actually created
        echo -e "${CYAN}🔍 Validating user creation...${NC}"
        if validate_user_exists "$username"; then
            echo -e "${GREEN}✔️ Confirmed: User $username exists in LDAP${NC}"
            # Show user details
            kubectl exec -n $NAMESPACE $LDAP_POD -- ldapsearch -x -H ldap://localhost:389 \
                -D "$LDAP_SERVICE_DN" -w "$LDAP_SERVICE_PASSWORD" \
                -b "uid=$username,ou=People,dc=ephico2real,dc=com" \
                uid cn mail 2>/dev/null | grep -E "^(uid|cn|mail):" | sed 's/^/   /'
        else
            echo -e "${RED}❌ Validation failed: User $username not found${NC}"
        fi
    else
        echo -e "${YELLOW}⚠️  User $username may already exist${NC}"
        # Check if user already exists
        if validate_user_exists "$username"; then
            echo -e "${BLUE}🔍 User $username already exists in LDAP${NC}"
        fi
    fi
    
    rm -f /tmp/new_user.ldif
}

# Add new RBAC group
add_rbac_group() {
    local groupname="$1"
    local description="$2"
    local LDAP_POD=$(get_ldap_pod)
    
    if [ -z "$LDAP_POD" ]; then
        echo -e "${RED}❌ LDAP pod not found${NC}"
        return 1
    fi
    
    echo -e "${GREEN}👥 Adding new RBAC group: $groupname${NC}"
    
    # Create LDIF for new group
    cat > /tmp/new_group.ldif << EOF
dn: cn=$groupname,ou=Groups,dc=ephico2real,dc=com
objectClass: groupOfNames
cn: $groupname
description: $description
member: uid=placeholder,ou=People,dc=ephico2real,dc=com
EOF
    
    kubectl cp /tmp/new_group.ldif $NAMESPACE/$LDAP_POD:$TMP_DIR/
    
    if kubectl exec -n $NAMESPACE $LDAP_POD -- ldapadd -x -H ldap://localhost:389 \
        -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" \
        -f $TMP_DIR/new_group.ldif >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Group $groupname added successfully${NC}"
        
        # Validate the group was actually created
        echo -e "${CYAN}🔍 Validating group creation...${NC}"
        if validate_group_exists "$groupname"; then
            echo -e "${GREEN}✔️ Confirmed: Group $groupname exists in LDAP${NC}"
            show_group_members "$groupname"
        else
            echo -e "${RED}❌ Validation failed: Group $groupname not found${NC}"
        fi
    else
        echo -e "${YELLOW}⚠️  Group $groupname may already exist${NC}"
        # Check if group already exists
        if validate_group_exists "$groupname"; then
            echo -e "${BLUE}🔍 Group $groupname already exists in LDAP${NC}"
            show_group_members "$groupname"
        fi
    fi
    
    rm -f /tmp/new_group.ldif
}

# Add user to group
add_user_to_group() {
    local username="$1"
    local groupname="$2"
    local LDAP_POD=$(get_ldap_pod)
    
    if [ -z "$LDAP_POD" ]; then
        echo -e "${RED}❌ LDAP pod not found${NC}"
        return 1
    fi
    
    echo -e "${CYAN}🔗 Adding $username to group $groupname${NC}"

    # Resolve the user's REAL DN so the member value matches the user's actual entry.
    local user_dn=$(resolve_user_dn "$username")
    if [ -z "$user_dn" ]; then
        echo -e "${RED}❌ User $username not found in LDAP — cannot add to group${NC}"
        return 1
    fi

    # Check if placeholder exists and remove it while adding real user.
    # Count entries — ldapsearch exits 0 even when the placeholder is absent.
    if [ "$(ldap_count "cn=$groupname,ou=Groups,dc=ephico2real,dc=com" "(member=uid=placeholder,ou=People,dc=ephico2real,dc=com)")" -gt 0 ]; then

        # Create LDIF to replace placeholder with real user
        cat > /tmp/replace_placeholder.ldif << EOF
dn: cn=$groupname,ou=Groups,dc=ephico2real,dc=com
changetype: modify
delete: member
member: uid=placeholder,ou=People,dc=ephico2real,dc=com
-
add: member
member: $user_dn
EOF
        kubectl cp /tmp/replace_placeholder.ldif $NAMESPACE/$LDAP_POD:$TMP_DIR/
        
        if kubectl exec -n $NAMESPACE $LDAP_POD -- ldapmodify -x -H ldap://localhost:389 \
            -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" \
            -f $TMP_DIR/replace_placeholder.ldif >/dev/null 2>&1; then
            echo -e "${GREEN}✅ User $username added to group $groupname (placeholder removed)${NC}"
        else
            echo -e "${YELLOW}⚠️  Error replacing placeholder${NC}"
        fi
        
        # Validate the operation
        echo -e "${CYAN}🔍 Validating group membership...${NC}"
        if validate_user_in_group "$username" "$groupname"; then
            echo -e "${GREEN}✔️ Confirmed: $username is member of $groupname${NC}"
            show_group_members "$groupname"
        else
            echo -e "${RED}❌ Validation failed: $username not found in $groupname${NC}"
        fi
        rm -f /tmp/replace_placeholder.ldif
    else
        # No placeholder, just add the user normally
        cat > /tmp/add_member.ldif << EOF
dn: cn=$groupname,ou=Groups,dc=ephico2real,dc=com
changetype: modify
add: member
member: $user_dn
EOF
        kubectl cp /tmp/add_member.ldif $NAMESPACE/$LDAP_POD:$TMP_DIR/
        
        if kubectl exec -n $NAMESPACE $LDAP_POD -- ldapmodify -x -H ldap://localhost:389 \
            -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" \
            -f $TMP_DIR/add_member.ldif >/dev/null 2>&1; then
            echo -e "${GREEN}✅ User $username added to group $groupname${NC}"
        else
            echo -e "${YELLOW}⚠️  User may already be in group or error occurred${NC}"
        fi
        rm -f /tmp/add_member.ldif
        
        # Validate the operation
        echo -e "${CYAN}🔍 Validating group membership...${NC}"
        if validate_user_in_group "$username" "$groupname"; then
            echo -e "${GREEN}✔️ Confirmed: $username is member of $groupname${NC}"
            show_group_members "$groupname"
        else
            echo -e "${RED}❌ Validation failed: $username not found in $groupname${NC}"
        fi
    fi
}

# Remove user from group
remove_user_from_group() {
    local username="$1"
    local groupname="$2"
    local LDAP_POD=$(get_ldap_pod)
    
    if [ -z "$LDAP_POD" ]; then
        echo -e "${RED}❌ LDAP pod not found${NC}"
        return 1
    fi
    
    echo -e "${YELLOW}🔗 Removing $username from group $groupname${NC}"

    # Resolve the user's REAL DN so we delete the member entry that actually exists.
    local user_dn=$(resolve_user_dn "$username")
    if [ -z "$user_dn" ]; then
        echo -e "${RED}❌ User $username not found in LDAP — cannot remove from group${NC}"
        return 1
    fi

    # Create LDIF for removing user from group
    cat > /tmp/remove_member.ldif << EOF
dn: cn=$groupname,ou=Groups,dc=ephico2real,dc=com
changetype: modify
delete: member
member: $user_dn
EOF
    
    kubectl cp /tmp/remove_member.ldif $NAMESPACE/$LDAP_POD:$TMP_DIR/
    
    if kubectl exec -n $NAMESPACE $LDAP_POD -- ldapmodify -x -H ldap://localhost:389 \
        -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" \
        -f $TMP_DIR/remove_member.ldif >/dev/null 2>&1; then
        echo -e "${GREEN}✅ User $username removed from group $groupname${NC}"
    else
        echo -e "${YELLOW}⚠️  User may not be in group or error occurred${NC}"
    fi
    
    rm -f /tmp/remove_member.ldif
    
    # Validate the removal
    echo -e "${CYAN}🔍 Validating user removal...${NC}"
    if validate_user_in_group "$username" "$groupname"; then
        echo -e "${RED}❌ Validation failed: $username still in $groupname${NC}"
    else
        echo -e "${GREEN}✔️ Confirmed: $username removed from $groupname${NC}"
    fi
    show_group_members "$groupname"
}

# Delete user
delete_user() {
    local username="$1"
    local LDAP_POD=$(get_ldap_pod)
    
    if [ -z "$LDAP_POD" ]; then
        echo -e "${RED}❌ LDAP pod not found${NC}"
        return 1
    fi
    
    echo -e "${RED}🗑️  Deleting user: $username${NC}"

    # Resolve the user's REAL DN — deleting an assumed uid=$username misses cn=-based
    # seed users entirely.
    local user_dn=$(resolve_user_dn "$username")
    if [ -z "$user_dn" ]; then
        echo -e "${YELLOW}⚠️  User $username not found in LDAP (nothing to delete)${NC}"
        return 0
    fi

    if kubectl exec -n $NAMESPACE $LDAP_POD -- ldapdelete -x -H ldap://localhost:389 \
        -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" \
        "$user_dn" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ User $username deleted successfully${NC}"
        
        # Validate the deletion
        echo -e "${CYAN}🔍 Validating user deletion...${NC}"
        if validate_user_exists "$username"; then
            echo -e "${RED}❌ Validation failed: User $username still exists${NC}"
        else
            echo -e "${GREEN}✔️ Confirmed: User $username has been deleted${NC}"
        fi
    else
        echo -e "${YELLOW}⚠️  User $username may not exist${NC}"
        # Check if user exists
        if validate_user_exists "$username"; then
            echo -e "${BLUE}🔍 User $username still exists in LDAP${NC}"
        else
            echo -e "${GREEN}✔️ User $username was not found (already deleted)${NC}"
        fi
    fi
}

# Delete group
delete_group() {
    local groupname="$1"
    local LDAP_POD=$(get_ldap_pod)
    
    if [ -z "$LDAP_POD" ]; then
        echo -e "${RED}❌ LDAP pod not found${NC}"
        return 1
    fi
    
    echo -e "${RED}🗑️  Deleting group: $groupname${NC}"
    
    if kubectl exec -n $NAMESPACE $LDAP_POD -- ldapdelete -x -H ldap://localhost:389 \
        -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" \
        "cn=$groupname,ou=Groups,dc=ephico2real,dc=com" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Group $groupname deleted successfully${NC}"
        
        # Validate the deletion
        echo -e "${CYAN}🔍 Validating group deletion...${NC}"
        if validate_group_exists "$groupname"; then
            echo -e "${RED}❌ Validation failed: Group $groupname still exists${NC}"
        else
            echo -e "${GREEN}✔️ Confirmed: Group $groupname has been deleted${NC}"
        fi
    else
        echo -e "${YELLOW}⚠️  Group $groupname may not exist${NC}"
        # Check if group exists
        if validate_group_exists "$groupname"; then
            echo -e "${BLUE}🔍 Group $groupname still exists in LDAP${NC}"
        else
            echo -e "${GREEN}✔️ Group $groupname was not found (already deleted)${NC}"
        fi
    fi
}

# Predefined scenarios
scenario_new_hire() {
    echo -e "${PURPLE}🎭 SCENARIO: New Hire Onboarding${NC}"
    echo "=================================="
    
    check_openshift_groups "BEFORE"
    
    # Add new user
    add_user "sarah.jones" "Sarah Jones" "sarah.jones@ephico2real.com"
    
    # Add to groups
    add_user_to_group "sarah.jones" "app-ocp-rbac-demo-ns-developer"
    add_user_to_group "sarah.jones" "general-users"
    
    force_groupsync
    check_openshift_groups "AFTER"
}

scenario_role_change() {
    echo -e "${PURPLE}🎭 SCENARIO: Role Change (Promotion)${NC}"
    echo "===================================="
    
    check_openshift_groups "BEFORE"
    
    # Promote existing user
    add_user_to_group "bob.wilson" "app-ocp-rbac-platform-cluster-admin"
    remove_user_from_group "bob.wilson" "app-ocp-rbac-platform-ns-audit"
    
    force_groupsync
    check_openshift_groups "AFTER"
}

scenario_team_restructure() {
    echo -e "${PURPLE}🎭 SCENARIO: Team Restructuring${NC}"
    echo "==============================="
    
    check_openshift_groups "BEFORE"
    
    # Add new team
    add_rbac_group "app-ocp-rbac-devops-cluster-admin" "DevOps Team Cluster Administrators"
    add_rbac_group "app-ocp-rbac-devops-ns-developer" "DevOps Team Namespace Developers"
    
    # Move users to new team
    add_user_to_group "john.doe" "app-ocp-rbac-devops-cluster-admin"
    add_user_to_group "alice.cooper" "app-ocp-rbac-devops-ns-developer"
    
    force_groupsync
    check_openshift_groups "AFTER"
}

scenario_departure() {
    echo -e "${PURPLE}🎭 SCENARIO: Employee Departure${NC}"
    echo "==============================="
    
    check_openshift_groups "BEFORE"
    
    # Remove user from all groups first, then delete
    remove_user_from_group "charlie.brown" "app-ocp-rbac-finance-cluster-developer"
    remove_user_from_group "charlie.brown" "app-ocp-rbac-newteam-cluster-admin"
    
    force_groupsync
    echo "⏳ Waiting to observe group changes..."
    sleep 5
    
    # Delete the user
    delete_user "charlie.brown"
    
    force_groupsync
    check_openshift_groups "AFTER"
}

scenario_bda_onboarding() {
    echo -e "${PURPLE}🎭 SCENARIO: BDA Multi-Tenant Onboarding${NC}"
    echo "========================================"
    echo "Onboards a new Big-Data engineer + new BDA groups, then shows the custom"
    echo "'bda-rbac-groupsync' CR (filter cn=bda-rbac-*) sync them into OpenShift —"
    echo "brand-new groups and members, with NO chart change."

    check_openshift_groups "BEFORE" "bda-rbac"

    # 1. A new engineer joins the BDA team (created with a uid= DN, the script convention).
    add_user "dana.lee" "Dana Lee" "dana.lee@ephico2real.com"

    # 2. Onboard a new BDA service (flink) and a new environment (gamma).
    add_rbac_group "bda-rbac-flink-alpha-apps"  "BDA Flink alpha application service accounts"
    add_rbac_group "bda-rbac-flink-alpha-users" "BDA Flink alpha human users"
    add_rbac_group "bda-rbac-spark-gamma-apps"  "BDA Spark gamma application service accounts"

    # 3. Put the new engineer in the new groups (uid= member matches the uid= user DN).
    add_user_to_group "dana.lee" "bda-rbac-flink-alpha-apps"
    add_user_to_group "dana.lee" "bda-rbac-flink-alpha-users"
    add_user_to_group "dana.lee" "bda-rbac-spark-gamma-apps"

    # 4. Trigger the BDA CR specifically (not the primary app-ocp-rbac CR).
    force_groupsync "bda-rbac-groupsync"
    check_openshift_groups "AFTER" "bda-rbac"
    echo -e "${CYAN}Tip: the new groups + member sync under the SAME custom CR — cn=bda-rbac-* covers them.${NC}"
}

# Interactive menu
show_menu() {
    echo
    echo -e "${CYAN}🎮 LDAP Operations Simulation Menu${NC}"
    echo "=================================="
    echo "1. Add new user"
    echo "2. Add new RBAC group" 
    echo "3. Add user to existing group"
    echo "4. Remove user from group"
    echo "5. Delete user"
    echo "6. Delete group"
    echo "7. Force GroupSync now"
    echo "8. Check current OpenShift groups"
    echo ""
    echo "📋 Predefined Scenarios:"
    echo "s1. New hire onboarding"
    echo "s2. Role change (promotion)"
    echo "s3. Team restructuring"
    echo "s4. Employee departure"
    echo "s5. BDA multi-tenant onboarding (custom GroupSync CR)"
    echo ""
    echo "0. Exit"
    echo
    read -p "Select option: " choice
}

# Main execution
main() {
    echo -e "${BLUE}🎯 LDAP Operations Simulation Script${NC}"
    echo "===================================="
    
    # Check prerequisites
    if [ -z "$(get_ldap_pod)" ]; then
        echo -e "${RED}❌ LDAP server not running in namespace $NAMESPACE${NC}"
        echo "Please run: ./30-manage-ldap-server.sh deploy-all"
        exit 1
    fi
    
    if ! oc get groupsync ldap-groupsync -n group-sync-operator >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️  GroupSync CR not found. Some operations may not sync automatically.${NC}"
    fi
    
    echo -e "${GREEN}✅ Prerequisites met${NC}"
    echo
    
    while true; do
        show_menu
        case $choice in
            1)
                read -p "Username: " username
                read -p "Full name: " fullname
                read -p "Email: " email
                add_user "$username" "$fullname" "$email"
                force_groupsync
                ;;
            2)
                read -p "Group name (e.g., app-ocp-rbac-newteam-cluster-admin): " groupname
                read -p "Description: " description
                add_rbac_group "$groupname" "$description"
                force_groupsync
                ;;
            3)
                read -p "Username: " username
                read -p "Group name: " groupname
                add_user_to_group "$username" "$groupname"
                force_groupsync
                ;;
            4)
                read -p "Username: " username
                read -p "Group name: " groupname
                remove_user_from_group "$username" "$groupname"
                force_groupsync
                ;;
            5)
                read -p "Username to delete: " username
                delete_user "$username"
                force_groupsync
                ;;
            6)
                read -p "Group name to delete: " groupname
                delete_group "$groupname"
                force_groupsync
                ;;
            7)
                force_groupsync
                ;;
            8)
                check_openshift_groups "CURRENT"
                ;;
            s1)
                scenario_new_hire
                ;;
            s2)
                scenario_role_change
                ;;
            s3)
                scenario_team_restructure
                ;;
            s4)
                scenario_departure
                ;;
            s5)
                scenario_bda_onboarding
                ;;
            0)
                echo -e "${GREEN}👋 Goodbye!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}❌ Invalid option${NC}"
                ;;
        esac
        echo
        read -p "Press Enter to continue..."
    done
}

# Handle command line arguments
if [ $# -gt 0 ]; then
    case $1 in
        new-hire)
            scenario_new_hire
            ;;
        role-change) 
            scenario_role_change
            ;;
        team-restructure)
            scenario_team_restructure
            ;;
        departure)
            scenario_departure
            ;;
        bda-onboarding)
            scenario_bda_onboarding
            ;;
        *)
            echo "Usage: $0 [new-hire|role-change|team-restructure|departure|bda-onboarding]"
            echo "Or run without arguments for interactive mode"
            exit 1
            ;;
    esac
else
    main
fi