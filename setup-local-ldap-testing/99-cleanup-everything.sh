#!/bin/bash

# 🧹 FINAL: Complete Test Environment Cleanup
# 
# Removes all demo resources created during GroupSync operator testing,
# including secrets, ConfigMaps, certificates, and temporary files.
# Does not remove the Helm chart deployment.
#
# Purpose: Clean teardown of all test resources (preserves Helm deployment)

set -e

echo "🧹 GroupSync Operator Test Environment Cleanup"
echo "==============================================="
echo

echo "⚠️  This will remove:"
echo "  - ConfigMap 'ca-config-map-test' from openshift-config namespace"
echo "  - Secret 'ldap-secret' from openshift-config namespace (source OAuth secret)"
echo "  - Local certificate files (ca-cert.pem, ca-key.pem)"
echo "  - Everything in 'ldap-testing' namespace (LDAP server, phpLDAPadmin, PVCs, etc.)"
echo "  - 'ldap-testing' namespace itself"
echo
echo "ℹ️  Note: Secret 'ldap-group-sync' in group-sync-operator namespace is NOT removed"
echo "   because it is managed by the Helm chart's OAuth extraction job."
echo
echo "Do you want to continue? [y/N]"
read -r response

if [[ ! "$response" =~ ^[Yy]$ ]]; then
    echo "🚫 Cleanup cancelled."
    exit 0
fi

echo
echo "🧹 Starting cleanup..."
echo

# Remove ConfigMap
echo "📋 Removing ConfigMap..."
if oc get configmap ca-config-map-test -n openshift-config &> /dev/null; then
    oc delete configmap ca-config-map-test -n openshift-config
    echo "✅ ConfigMap ca-config-map-test removed from openshift-config"
else
    echo "ℹ️ ConfigMap ca-config-map-test not found in openshift-config"
fi
echo

# Note: We do NOT remove ldap-group-sync secret from group-sync-operator namespace
# because it is created and managed by the Helm chart's OAuth extraction job.
# It will be removed when the Helm chart is uninstalled.

# Remove Secret from openshift-config (source OAuth secret)
echo "🔑 Removing Secret from openshift-config..."
if oc get secret ldap-secret -n openshift-config &> /dev/null; then
    oc delete secret ldap-secret -n openshift-config
    echo "✅ Secret ldap-secret removed from openshift-config"
else
    echo "ℹ️ Secret ldap-secret not found in openshift-config"
fi
echo

# Remove local certificate files
echo "📁 Removing local certificate files..."
if [[ -f ca-cert.pem ]]; then
    rm -f ca-cert.pem
    echo "✅ Removed ca-cert.pem"
else
    echo "ℹ️ ca-cert.pem not found"
fi

if [[ -f ca-key.pem ]]; then
    rm -f ca-key.pem
    echo "✅ Removed ca-key.pem"
else
    echo "ℹ️ ca-key.pem not found"
fi
echo

# Remove everything in ldap-testing namespace (including the namespace itself)
echo "🗑️  Removing ldap-testing namespace and all resources..."
if kubectl get namespace ldap-testing &> /dev/null; then
    # Delete all resources in the namespace first
    kubectl delete -f 01-ldap-server.yaml --ignore-not-found=true
    kubectl delete -f 02-phpldapadmin.yaml --ignore-not-found=true
    kubectl delete -f 03-ldap-bootstrap-job.yaml --ignore-not-found=true
    
    # Also clean up any remaining resources
    kubectl delete all --all -n ldap-testing --ignore-not-found=true
    kubectl delete pvc --all -n ldap-testing --ignore-not-found=true
    kubectl delete configmap --all -n ldap-testing --ignore-not-found=true
    kubectl delete serviceaccount --all -n ldap-testing --ignore-not-found=true
    kubectl delete rolebinding --all -n ldap-testing --ignore-not-found=true
    kubectl delete route --all -n ldap-testing --ignore-not-found=true
    
    # Finally delete the namespace itself
    kubectl delete namespace ldap-testing --ignore-not-found=true
    echo "✅ ldap-testing namespace and all resources removed"
else
    echo "ℹ️ ldap-testing namespace not found"
fi
echo

echo "🎉 Cleanup complete!"
echo
echo "📝 Note: The following are still deployed (managed by Helm):"
echo "  - Helm release 'group-sync'"
echo "  - GroupSync CR"
echo "  - Secret 'ldap-group-sync' in group-sync-operator namespace (created by OAuth extraction job)"
echo
echo "To remove them as well:"
echo "  helm uninstall group-sync"
echo "  oc delete namespace group-sync-operator  # (optional)"
echo
echo "📋 Summary of what was cleaned up:"
echo "  ✅ ConfigMap ca-config-map-test (openshift-config)"
echo "  ✅ Secret ldap-secret (openshift-config)"
echo "  ✅ Local certificate files (ca-cert.pem, ca-key.pem)"
echo "  ✅ ldap-testing namespace and all resources"
echo
echo "🔄 To recreate the test environment, run: ./10-setup-oauth-secrets.sh"

