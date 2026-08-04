#!/usr/bin/env bash
# Bootstrap an enterprise-shaped PKI for the test LDAP directory using cert-manager.
#
# Produces the same shape a real cluster has — a root CA in a ConfigMap, and a serving
# certificate issued from it by a named CA — instead of the service-ca shortcut. That makes the
# chart's CA path exercise the code an enterprise deployment actually hits.
#
# The chain:
#
#   ClusterIssuer/ldap-selfsigned-bootstrap   selfSigned, signs nothing but the root
#     -> Certificate/ldap-enterprise-root-ca  isCA, in the cert-manager namespace
#          -> ClusterIssuer/ldap-enterprise-ca            the CA that signs leaves
#               -> Certificate/openldap-serving-cert-cm   CN + both Service DNS SANs
#          -> ConfigMap <CA_CONFIGMAP_NAME> key ca.crt    what groupSync.ca points at
#
# The root Certificate MUST live in the cert-manager namespace: a ClusterIssuer of kind `ca`
# resolves its secretName in the cluster resource namespace, which this cluster sets with
# --cluster-resource-namespace=$(POD_NAMESPACE) — the namespace cert-manager itself runs in.
# A root issued anywhere else leaves the ClusterIssuer permanently NotReady.
#
# The CA ConfigMap is created in TWO namespaces on purpose. openshift-config is the enterprise
# convention and where an OAuth LDAP identity provider would read it, but the operator can only
# read it there if its ServiceAccount has cross-namespace ConfigMap read. The copy in the
# operator's own namespace always works. Point groupSync.ca.namespace at whichever you want to
# exercise.
#
# trust-manager is deliberately not used. The Bundle CRD is present on this cluster but no
# trust-manager controller runs, so a Bundle would never reconcile.
#
#   ./15-bootstrap-cert-manager-ca.sh apply         create the PKI
#   ./15-bootstrap-cert-manager-ca.sh switch-ldap   point the LDAP server at it
#   ./15-bootstrap-cert-manager-ca.sh verify        prove the chain and the SANs
#   ./15-bootstrap-cert-manager-ca.sh revert-ldap   back to service-ca
#   ./15-bootstrap-cert-manager-ca.sh delete        remove the PKI

set -euo pipefail

LDAP_NS="${LDAP_NS:-ldap-testing}"
LDAP_SVC="${LDAP_SVC:-openldap-service}"
OPERATOR_NS="${OPERATOR_NS:-group-sync-operator}"

# Resolved, not assumed: a ClusterIssuer of kind `ca` reads its secret from here.
CM_NS="${CM_NS:-cert-manager}"

BOOTSTRAP_ISSUER="ldap-selfsigned-bootstrap"
ROOT_CERT="ldap-enterprise-root-ca"
ROOT_SECRET="ldap-enterprise-root-ca"
CA_ISSUER="ldap-enterprise-ca"
LEAF_CERT="openldap-serving-cert-cm"
LEAF_SECRET="openldap-certmanager-tls"

# ca-config-map is the name an OpenShift LDAP identity provider reads, so it is the enterprise
# shape. A pre-existing one is replaced only when its certificate has already expired, and only
# after a backup — see the guard in cmd_apply.
CA_CONFIGMAP_NAME="${CA_CONFIGMAP_NAME:-ca-config-map}"
CA_CONFIGMAP_NAMESPACES="${CA_CONFIGMAP_NAMESPACES:-openshift-config ${OPERATOR_NS}}"
BACKUP_DIR="${BACKUP_DIR:-./.ca-configmap-backup}"

SAN_SHORT="${LDAP_SVC}.${LDAP_NS}.svc"
SAN_FQDN="${LDAP_SVC}.${LDAP_NS}.svc.cluster.local"

# Marks every object this script owns, so delete can never reach anything it did not create.
OWNED_KEY="app.kubernetes.io/managed-by"
OWNED_VAL="15-bootstrap-cert-manager-ca"
OWNED="${OWNED_KEY}=${OWNED_VAL}"

log()  { echo "  $*"; }
step() { echo; echo "== $*"; }
die()  { echo "FAILED: $*" >&2; exit 1; }

require_cert_manager() {
  oc get crd clusterissuers.cert-manager.io >/dev/null 2>&1 \
    || die "cert-manager CRDs not found. Install the cert-manager operator first:
  oc get packagemanifests | grep cert-manager"
  local ready
  ready=$(oc get deploy cert-manager -n "$CM_NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
  [ "${ready:-0}" -ge 1 ] || die "cert-manager controller is not ready in namespace ${CM_NS}"

  # The whole chain depends on this flag, so it is read rather than assumed.
  local crn
  crn=$(oc get deploy cert-manager -n "$CM_NS" \
        -o jsonpath='{range .spec.template.spec.containers[0].args[*]}{@}{"\n"}{end}' 2>/dev/null \
        | sed -n 's/^--cluster-resource-namespace=//p')
  case "$crn" in
    ''|'$(POD_NAMESPACE)') log "cluster resource namespace: ${CM_NS} (operand namespace)" ;;
    "$CM_NS")              log "cluster resource namespace: ${CM_NS}" ;;
    *) log "cluster resource namespace is ${crn}, not ${CM_NS} — using it for the root"
       CM_NS="$crn" ;;
  esac
}

wait_ready() {
  local kind="$1" name="$2" ns="${3:-}"
  local args=(wait "--for=condition=Ready" "${kind}/${name}" --timeout=180s)
  [ -n "$ns" ] && args+=(-n "$ns")
  log "waiting for ${kind}/${name} to be Ready"
  oc "${args[@]}" >/dev/null 2>&1 && return 0

  echo "  ${kind}/${name} did not become Ready:" >&2
  if [ -n "$ns" ]; then oc describe "$kind" "$name" -n "$ns" 2>&1 | tail -20 | sed 's/^/    /' >&2
  else oc describe "$kind" "$name" 2>&1 | tail -20 | sed 's/^/    /' >&2; fi
  die "${kind}/${name} not Ready"
}

# Prints the value of this script's ownership label, empty when absent.
configmap_owner() {
  oc get configmap "$1" -n "$2" -o json 2>/dev/null \
    | python3 -c "import sys,json;print((json.load(sys.stdin)['metadata'].get('labels') or {}).get('${OWNED_KEY}',''))"
}

# Replacing a live CA breaks every client trusting it, so an unowned ConfigMap is replaced only
# when its certificate has already expired — and its contents are saved first either way.
guard_existing_configmap() {
  local ns="$1" name="$2" owner
  oc get configmap "$name" -n "$ns" >/dev/null 2>&1 || return 0

  owner="$(configmap_owner "$name" "$ns")"
  [ "$owner" = "$OWNED_VAL" ] && return 0

  mkdir -p "$BACKUP_DIR"
  local backup="${BACKUP_DIR}/${ns}-${name}.yaml"
  oc get configmap "$name" -n "$ns" -o yaml > "$backup"
  log "backed up existing ${ns}/${name} to ${backup}"

  local pem="${BACKUP_DIR}/${ns}-${name}.ca.crt"
  oc extract "configmap/${name}" -n "$ns" --keys=ca.crt --to="$BACKUP_DIR" --confirm >/dev/null 2>&1 || true
  [ -s "${BACKUP_DIR}/ca.crt" ] && mv "${BACKUP_DIR}/ca.crt" "$pem"

  if [ -s "$pem" ] && openssl x509 -in "$pem" -noout -checkend 0 >/dev/null 2>&1; then
    local subj enddate
    subj=$(openssl x509 -in "$pem" -noout -subject 2>/dev/null)
    enddate=$(openssl x509 -in "$pem" -noout -enddate 2>/dev/null)
    die "ConfigMap ${ns}/${name} holds a certificate that is still VALID and was not created by
  this script. Refusing to replace it — anything trusting it would break.
    ${subj}
    ${enddate}
  Set CA_CONFIGMAP_NAME to a free name, or delete it deliberately first."
  fi

  if [ -s "$pem" ]; then
    log "existing ${ns}/${name} certificate is EXPIRED ($(openssl x509 -in "$pem" -noout -enddate 2>/dev/null | sed 's/notAfter=//')) — replacing it"
  else
    log "existing ${ns}/${name} has no usable ca.crt — replacing it"
  fi
}

cmd_apply() {
  require_cert_manager

  step "self-signed bootstrap issuer"
  oc apply -f - <<YAML | sed 's/^/  /'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${BOOTSTRAP_ISSUER}
  labels:
    ${OWNED_KEY}: ${OWNED_VAL}
spec:
  selfSigned: {}
YAML
  wait_ready clusterissuer "$BOOTSTRAP_ISSUER"

  step "enterprise root CA in ${CM_NS}"
  oc apply -f - <<YAML | sed 's/^/  /'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${ROOT_CERT}
  namespace: ${CM_NS}
  labels:
    ${OWNED_KEY}: ${OWNED_VAL}
spec:
  isCA: true
  commonName: LDAP Enterprise Root CA
  subject:
    organizations: ["Enterprise IT"]
    organizationalUnits: ["Directory Services"]
  secretName: ${ROOT_SECRET}
  duration: 87600h    # 10y — a root outlives the leaves it signs
  renewBefore: 720h
  privateKey:
    algorithm: RSA
    size: 4096
    # A rotated key needs a re-signed chain; Never keeps the CA stable for the leaf's lifetime.
    rotationPolicy: Never
  usages: ["cert sign", "crl sign", "digital signature"]
  issuerRef:
    name: ${BOOTSTRAP_ISSUER}
    kind: ClusterIssuer
    group: cert-manager.io
YAML
  wait_ready certificate "$ROOT_CERT" "$CM_NS"

  step "CA issuer backed by that root"
  oc apply -f - <<YAML | sed 's/^/  /'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${CA_ISSUER}
  labels:
    ${OWNED_KEY}: ${OWNED_VAL}
spec:
  ca:
    secretName: ${ROOT_SECRET}
YAML
  wait_ready clusterissuer "$CA_ISSUER"

  step "serving certificate for ${SAN_SHORT}"
  oc get namespace "$LDAP_NS" >/dev/null 2>&1 \
    || die "namespace ${LDAP_NS} not found — run 30-manage-ldap-server.sh first"
  oc apply -f - <<YAML | sed 's/^/  /'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${LEAF_CERT}
  namespace: ${LDAP_NS}
  labels:
    ${OWNED_KEY}: ${OWNED_VAL}
spec:
  # CN plus both SANs. Verification uses the SANs; the CN is set because some LDAP clients
  # still display it.
  commonName: ${SAN_SHORT}
  dnsNames:
    - ${SAN_SHORT}
    - ${SAN_FQDN}
  secretName: ${LEAF_SECRET}
  duration: 2160h     # 90d
  renewBefore: 360h   # 15d
  privateKey:
    algorithm: RSA
    size: 2048
    rotationPolicy: Always
  usages: ["server auth", "digital signature", "key encipherment"]
  issuerRef:
    name: ${CA_ISSUER}
    kind: ClusterIssuer
    group: cert-manager.io
YAML
  wait_ready certificate "$LEAF_CERT" "$LDAP_NS"

  step "root CA into ConfigMap ${CA_CONFIGMAP_NAME}"
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  # oc extract, not jsonpath: the key contains a dot and jsonpath treats it as a path
  # separator, so {.data.ca.crt} and {.data['ca.crt']} both return empty on a resource that
  # has the key.
  oc extract "secret/${ROOT_SECRET}" -n "$CM_NS" --keys=ca.crt --to="$tmp" --confirm >/dev/null 2>&1 || true
  # Checked on the file, not the exit code: a missing key exits 0 and writes nothing.
  [ -s "${tmp}/ca.crt" ] || die "secret ${CM_NS}/${ROOT_SECRET} has no ca.crt"
  grep -q 'BEGIN CERTIFICATE' "${tmp}/ca.crt" || die "ca.crt in ${CM_NS}/${ROOT_SECRET} is not PEM"

  for ns in $CA_CONFIGMAP_NAMESPACES; do
    if ! oc get namespace "$ns" >/dev/null 2>&1; then
      log "skipping ${ns} — namespace does not exist"
      continue
    fi
    guard_existing_configmap "$ns" "$CA_CONFIGMAP_NAME"
    oc create configmap "$CA_CONFIGMAP_NAME" -n "$ns" \
       --from-file=ca.crt="${tmp}/ca.crt" --dry-run=client -o yaml \
      | oc label --local -f - -o yaml "$OWNED" \
      | oc apply -f - >/dev/null
    log "ConfigMap ${ns}/${CA_CONFIGMAP_NAME} key ca.crt"
  done

  step "chart values for this PKI"
  cat <<VALUES
  groupSync:
    url: "ldaps://${SAN_FQDN}:636"
    insecure: false
    ca:
      field: caSecret
      kind: ConfigMap
      name: ${CA_CONFIGMAP_NAME}
      namespace: ${OPERATOR_NS}
      key: ca.crt

  Use namespace openshift-config instead to exercise the cross-namespace read.
  Next: ./15-bootstrap-cert-manager-ca.sh switch-ldap
VALUES
}

cmd_switch_ldap() {
  oc get secret "$LEAF_SECRET" -n "$LDAP_NS" >/dev/null 2>&1 \
    || die "secret ${LDAP_NS}/${LEAF_SECRET} not found — run apply first"

  step "pointing openldap-server at the cert-manager certificate"
  # Both volumes become the one cert-manager secret, so the install-certs initContainer needs no
  # change: it reads /tls/tls.crt, /tls/tls.key and /ca/service-ca.crt, and the items mapping
  # below presents ca.crt under that last name.
  local vols
  vols=$(oc get deploy openldap-server -n "$LDAP_NS" -o json | python3 -c "
import sys,json
out=[]
for v in json.load(sys.stdin)['spec']['template']['spec']['volumes']:
    if v['name']=='serving-cert':
        v={'name':'serving-cert','secret':{'secretName':'${LEAF_SECRET}','defaultMode':420}}
    elif v['name']=='service-ca':
        v={'name':'service-ca','secret':{'secretName':'${LEAF_SECRET}','defaultMode':420,
             'items':[{'key':'ca.crt','path':'service-ca.crt'}]}}
    out.append(v)
print(json.dumps(out))")

  oc patch deployment openldap-server -n "$LDAP_NS" --type=json \
     -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/volumes\",\"value\":${vols}}]" >/dev/null
  log "volumes serving-cert and service-ca now both read ${LEAF_SECRET}"

  oc rollout status deploy/openldap-server -n "$LDAP_NS" --timeout=300s 2>&1 | tail -1 | sed 's/^/  /'
  cmd_verify
}

cmd_revert_ldap() {
  step "pointing openldap-server back at service-ca"
  local vols
  vols=$(oc get deploy openldap-server -n "$LDAP_NS" -o json | python3 -c "
import sys,json
out=[]
for v in json.load(sys.stdin)['spec']['template']['spec']['volumes']:
    if v['name']=='serving-cert':
        v={'name':'serving-cert','secret':{'secretName':'openldap-serving-cert','defaultMode':420}}
    elif v['name']=='service-ca':
        v={'name':'service-ca','configMap':{'name':'openldap-service-ca','defaultMode':420}}
    out.append(v)
print(json.dumps(out))")

  oc patch deployment openldap-server -n "$LDAP_NS" --type=json \
     -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/volumes\",\"value\":${vols}}]" >/dev/null
  oc rollout status deploy/openldap-server -n "$LDAP_NS" --timeout=300s 2>&1 | tail -1 | sed 's/^/  /'
  log "reverted — groupSync.ca must point back at openshift-service-ca.crt"
}

cmd_verify() {
  step "certificate the LDAPS endpoint actually presents"
  oc get configmap "$CA_CONFIGMAP_NAME" -n "$OPERATOR_NS" >/dev/null 2>&1 \
    || die "ConfigMap ${OPERATOR_NS}/${CA_CONFIGMAP_NAME} not found — run apply"

  # Run inside the cluster and against the Service DNS name: that is the only way the SAN check
  # means anything. -verify_return_error makes a bad chain a non-zero exit rather than a warning.
  local overrides
  overrides=$(python3 -c "
import json
print(json.dumps({'spec':{
  'containers':[{
    'name':'verify','image':'registry.redhat.io/rhel9/openssl:latest',
    'command':['/bin/sh','-c',
      'echo | openssl s_client -connect ${SAN_FQDN}:636 -servername ${SAN_FQDN} '
      '-CAfile /ca/ca.crt -verify_return_error 2>&1 '
      '| grep -Ei \"^subject=|^issuer=|Verify return code|Verification\"; '
      'echo | openssl s_client -connect ${SAN_FQDN}:636 -CAfile /ca/ca.crt 2>/dev/null '
      '| openssl x509 -noout -ext subjectAltName'],
    'volumeMounts':[{'name':'ca','mountPath':'/ca','readOnly':True}],
    'securityContext':{'allowPrivilegeEscalation':False,'capabilities':{'drop':['ALL']}}}],
  'securityContext':{'runAsNonRoot':True,'seccompProfile':{'type':'RuntimeDefault'}},
  'volumes':[{'name':'ca','configMap':{'name':'${CA_CONFIGMAP_NAME}'}}]}}))")

  # Asserted on the success string, not on an exit code. oc run's status is masked by the pipe, and
  # a chain that fails to verify still produces output — so a missing "Verify return code: 0" is the
  # only reliable signal that this did NOT pass.
  local out
  out=$(oc run "ldaps-verify-$$" -n "$OPERATOR_NS" --rm -i --restart=Never \
        --image=registry.redhat.io/rhel9/openssl:latest \
        --overrides="$overrides" 2>&1) || true
  printf '%s\n' "$out" | sed 's/^/  /'

  printf '%s' "$out" | grep -q 'Verify return code: 0 (ok)' \
    || die "the LDAPS endpoint did not verify against ${CA_CONFIGMAP_NAME}.
  Either the endpoint is not serving the cert-manager certificate (run switch-ldap), or the CA in
  the ConfigMap is not the one that signed it (run apply)."

  printf '%s' "$out" | grep -q "DNS:${SAN_FQDN}" \
    || die "the served certificate has no SAN for ${SAN_FQDN}, so a verifying client will reject it."
  log "verified: chain OK and SAN matches ${SAN_FQDN}"
}

cmd_delete() {
  step "deleting only objects labelled ${OWNED}"
  for ns in $CA_CONFIGMAP_NAMESPACES; do
    oc delete configmap -n "$ns" -l "$OWNED" --ignore-not-found 2>&1 | sed 's/^/  /'
  done
  oc delete certificate -n "$LDAP_NS" -l "$OWNED" --ignore-not-found 2>&1 | sed 's/^/  /'
  oc delete certificate -n "$CM_NS"   -l "$OWNED" --ignore-not-found 2>&1 | sed 's/^/  /'
  oc delete clusterissuer              -l "$OWNED" --ignore-not-found 2>&1 | sed 's/^/  /'
  # cert-manager does not garbage-collect the secrets its Certificates produced.
  oc delete secret "$LEAF_SECRET" -n "$LDAP_NS" --ignore-not-found 2>&1 | sed 's/^/  /'
  oc delete secret "$ROOT_SECRET" -n "$CM_NS"   --ignore-not-found 2>&1 | sed 's/^/  /'
  log "the LDAP server still references ${LEAF_SECRET} until you run revert-ldap"
}

case "${1:-apply}" in
  apply)       cmd_apply ;;
  switch-ldap) cmd_switch_ldap ;;
  revert-ldap) cmd_revert_ldap ;;
  verify)      cmd_verify ;;
  delete)      cmd_delete ;;
  *) die "unknown command '${1}'. Use: apply | switch-ldap | verify | revert-ldap | delete" ;;
esac
