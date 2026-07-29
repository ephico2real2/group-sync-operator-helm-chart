#!/bin/bash

# 🔧 STEP 1: Setup OAuth Secrets and CA Certificates
# 
# This script creates the source OAuth secret and CA certificate needed
# for GroupSync operator testing. The Helm chart will automatically create
# the target secret from the source secret.
#
# Purpose: Sets up prerequisite secrets and certificates for local testing

set -e

echo "🎉 GroupSync Operator Test Environment Setup"
echo "============================================="
echo

# Check prerequisites
echo "🔍 Checking prerequisites..."

if ! command -v oc &> /dev/null; then
    echo "❌ oc CLI not found. Please install OpenShift CLI."
    exit 1
fi

if ! command -v openssl &> /dev/null; then
    echo "❌ openssl not found. Please install OpenSSL."
    exit 1
fi

if ! oc auth can-i create configmaps -n openshift-config &> /dev/null; then
    echo "❌ Insufficient permissions. Please ensure you can create ConfigMaps in openshift-config."
    exit 1
fi

echo "✅ Prerequisites check passed!"
echo

# Generate demo CA certificate
echo "🔒 Generating demo CA certificate..."
if [[ ! -f ca-cert.pem ]]; then
    openssl req -x509 -newkey rsa:4096 \
        -keyout ca-key.pem \
        -out ca-cert.pem \
        -days 365 \
        -nodes \
        -subj "/CN=Demo LDAP CA/O=Demo Organization/C=US"
    
    # Validate certificate was generated successfully
    if ! openssl x509 -in ca-cert.pem -noout -text >/dev/null 2>&1; then
        echo "❌ Error: Certificate generation failed or produced invalid certificate"
        exit 1
    fi
    echo "✅ Demo CA certificate created: ca-cert.pem"
else
    echo "ℹ️ Demo CA certificate already exists: ca-cert.pem"
    # Validate existing certificate
    if ! openssl x509 -in ca-cert.pem -noout -text >/dev/null 2>&1; then
        echo "❌ Error: Existing certificate file is invalid"
        echo "Please remove ca-cert.pem and regenerate, or fix the certificate file"
        exit 1
    fi
    echo "✅ Existing certificate is valid"
fi
echo

# Create ConfigMap
echo "📋 Creating ConfigMap for CA certificate..."
if oc get configmap ca-config-map-test -n openshift-config &> /dev/null; then
    echo "ℹ️ ConfigMap ca-config-map-test already exists in openshift-config"
    read -p "Do you want to replace it? (y/N): " replace_ca
    if [[ $replace_ca =~ ^[Yy]$ ]]; then
        oc delete configmap ca-config-map-test -n openshift-config
        oc create configmap ca-config-map-test --from-file=ca.crt=./ca-cert.pem -n openshift-config
        echo "✅ ConfigMap ca-config-map-test replaced in openshift-config"
    fi
else
    oc create configmap ca-config-map-test --from-file=ca.crt=./ca-cert.pem -n openshift-config
    echo "✅ ConfigMap ca-config-map-test created in openshift-config"
fi
echo

# Create OAuth LDAP Secret in openshift-config namespace (simulates existing OAuth setup)
echo "🔑 Creating OAuth LDAP secret in openshift-config (simulates existing OAuth setup)..."
if oc get secret ldap-secret -n openshift-config &> /dev/null; then
    echo "ℹ️ Secret ldap-secret already exists in openshift-config"
    echo "Do you want to replace it? [y/N]"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        oc delete secret ldap-secret -n openshift-config
        oc create secret generic ldap-secret \
            --from-literal=bindPassword='bindpassword123' \
            -n openshift-config
        echo "✅ Secret ldap-secret replaced in openshift-config"
    fi
else
    oc create secret generic ldap-secret \
        --from-literal=bindPassword='bindpassword123' \
        -n openshift-config
    echo "✅ Secret ldap-secret created in openshift-config (simulates OAuth secret)"
fi
echo

# Note: Target GroupSync secret will be created automatically by the Helm chart's OAuth extraction job
echo "ℹ️ Target GroupSync secret will be created automatically by Helm chart"
echo "The OAuth secret extraction job will handle creating ldap-group-sync secret"
echo

# Verification
echo "🔍 Verifying setup..."
echo "ConfigMap status:"
if oc get configmap ca-config-map-test -n openshift-config &> /dev/null; then
    oc get configmap ca-config-map-test -n openshift-config
    # Verify ConfigMap contains the certificate
    if oc get configmap ca-config-map-test -n openshift-config -o jsonpath='{.data.ca\.crt}' | base64 -d 2>/dev/null | openssl x509 -noout -text >/dev/null 2>&1; then
        echo "✅ ConfigMap contains valid CA certificate"
    else
        echo "⚠️ Warning: ConfigMap exists but certificate validation failed"
    fi
else
    echo "❌ Error: ConfigMap ca-config-map-test not found in openshift-config"
    exit 1
fi
echo
echo "OAuth secret verification:"
echo "The Helm chart will automatically create the target secret from this source secret"
if oc get secret ldap-secret -n openshift-config &> /dev/null; then
    oc get secret ldap-secret -n openshift-config
    echo "✅ OAuth secret exists in openshift-config"
else
    echo "❌ Error: Secret ldap-secret not found in openshift-config"
    exit 1
fi
echo

echo "🎉 Test environment setup complete!"
echo
echo "📝 Next steps:"
echo "1. Deploy GroupSync Helm chart (it will create target secret automatically)"
echo "2. Check OAuth extraction job: oc get jobs -n group-sync-operator"
echo "3. Verify target secret creation: oc get secret ldap-group-sync -n group-sync-operator"
echo "4. Monitor GroupSync status: oc describe groupsync ldap-group-sync -n group-sync-operator"
echo
echo "📚 For cleanup, run: ./99-cleanup-everything.sh"

