#!/usr/bin/env bash
# Bootstrap an enterprise-shaped PKI for the test LDAP directory using cert-manager.
#
# Produces the same shape a real cluster has: a root CA in a ConfigMap, and a serving certificate
# issued from it by a named CA. Nothing here is OpenShift-specific — no service-ca, no
# serving-cert-secret-name, no inject-cabundle — so it works on any cluster running cert-manager.
#
# The chain:
#
#   ClusterIssuer/ldap-selfsigned-bootstrap   selfSigned, signs nothing but the root
#     -> Certificate/ldap-enterprise-root-ca  isCA, in the cert-manager namespace
#          -> ClusterIssuer/ldap-enterprise-ca            the CA that signs leaves
#               -> Certificate/openldap-serving-cert-cm   CN + both Service DNS SANs
#          -> ConfigMap openshift-config/<CA_CONFIGMAP_NAME>  the enterprise CA source
#
# This script stops at that ConfigMap. It writes the enterprise CA where an OpenShift LDAP identity
# provider reads it, and the chart takes over: oauthSecretExtraction.caCopy copies it to
# <COPY_NAME> in the operator's namespace, which is what groupSync.ca loads. So the full path is
#
#   cert-manager -> openshift-config/ca-config-map -> group-sync-operator/ca-config-map-copy
#
# and no override values file is needed — that is the chart default. Rotating the CA here changes
# the chart's caSourceHash, so the next helm upgrade remakes the copy.
#
# The root Certificate MUST live in the cert-manager namespace: a ClusterIssuer of kind `ca`
# resolves its secretName in the cluster resource namespace, which this cluster sets with
# --cluster-resource-namespace=$(POD_NAMESPACE) — the namespace cert-manager itself runs in.
# A root issued anywhere else leaves the ClusterIssuer permanently NotReady.
#
# trust-manager is deliberately not used. The Bundle CRD is present on this cluster but no
# trust-manager controller runs, so a Bundle would never reconcile.
#
# RUN apply BEFORE deploying the LDAP server. 01-ldap-server.yaml mounts the leaf secret this creates,
# so the pod sits in ContainerCreating until it exists.
#
#   ./15-bootstrap-cert-manager-ca.sh apply            create the PKI and the serving certificate
#   ./15-bootstrap-cert-manager-ca.sh verify           prove the chain and SANs from inside the cluster
#   ./15-bootstrap-cert-manager-ca.sh trust-cluster    publish the root to proxy/cluster.spec.trustedCA,
#                                                      so trustedCA.injected can carry it
#   ./15-bootstrap-cert-manager-ca.sh untrust-cluster  undo that
#   ./15-bootstrap-cert-manager-ca.sh delete           remove the PKI

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

# openshift-config ONLY. This script's job is to produce the enterprise CA source — the same
# ConfigMap an OpenShift LDAP identity provider reads — and the chart's oauthSecretExtraction.caCopy
# copies it to ca-config-map-copy in the operator's namespace. Writing it here as well would leave two
# CAs in that namespace with nothing saying which one groupSync.ca uses.
CA_CONFIGMAP_NAMESPACES="${CA_CONFIGMAP_NAMESPACES:-openshift-config}"

# Where the chart puts the copy. Only read, never written, by this script — verify checks the CA the
# operator actually loads rather than the source it was made from.
COPY_NAME="${COPY_NAME:-ca-config-map-copy}"

# Referenced by proxy/cluster.spec.trustedCA, which requires the key ca-bundle.crt. Separate from
# CA_CONFIGMAP_NAME because that one uses ca.crt.
TRUST_BUNDLE_CM="${TRUST_BUNDLE_CM:-ldap-enterprise-ca-bundle}"
# Anchored to this script's directory, not the caller's. As ./.ca-configmap-backup it followed the
# working directory, so running the script from the repo root dropped cluster material outside the one
# path .gitignore covers.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${BACKUP_DIR:-${SCRIPT_DIR}/.ca-configmap-backup}"

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
  local ns="$1" name="$2" incoming="${3:-}" owner
  oc get configmap "$name" -n "$ns" >/dev/null 2>&1 || return 0

  owner="$(configmap_owner "$name" "$ns")"
  [ "$owner" = "$OWNED_VAL" ] && return 0

  mkdir -p "$BACKUP_DIR"
  local backup="${BACKUP_DIR}/${ns}-${name}.yaml"
  oc get configmap "$name" -n "$ns" -o yaml > "$backup"
  log "backed up existing ${ns}/${name} to ${backup}"

  # Cleared BEFORE the extract, so that $pem existing afterwards PROVES this run read it out of the
  # live ConfigMap. BACKUP_DIR persists between runs, and the extract only overwrites $pem when it
  # succeeds — so without this a leftover file from an earlier run is read below as though it were the
  # current cluster state, and the decision to replace a live CA gets made from a file on this laptop.
  # Every branch after this point depends on that distinction.
  local pem="${BACKUP_DIR}/${ns}-${name}.ca.crt"
  rm -f "$pem" "${BACKUP_DIR}/ca.crt"
  oc extract "configmap/${name}" -n "$ns" --keys=ca.crt --to="$BACKUP_DIR" --confirm >/dev/null 2>&1 || true
  [ -s "${BACKUP_DIR}/ca.crt" ] && mv "${BACKUP_DIR}/ca.crt" "$pem"

  # Identical contents replace nothing, so apply stays idempotent. Without this, anything that
  # rewrites the ConfigMap and drops the ownership label — a plain oc apply, a GitOps sync — turns
  # every later apply into a hard failure over a CA this script already put there.
  if [ -n "$incoming" ] && [ -s "$pem" ] && cmp -s "$pem" "$incoming"; then
    log "existing ${ns}/${name} already holds this exact CA — leaving it"
    return 0
  fi

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
    return 0
  fi

  # No readable ca.crt is NOT the same as empty. The caller overwrites this ConfigMap unconditionally
  # once this function returns, so treating "cannot read it" as permission to replace clobbers whatever
  # is actually in there — a corporate bundle stored under ca-bundle.crt, a multi-key trust ConfigMap,
  # a binary blob. The one thing the expired-certificate branch above has, and this one does not, is
  # evidence that replacing is safe.
  #
  # The full backup taken above means nothing is lost, but a lab script should not be the reason a
  # cluster-wide trust object changes shape. Refuse and name what is in there instead.
  local keys
  keys=$(oc get configmap "$name" -n "$ns" -o go-template='{{range $k,$v := .data}}{{$k}} {{end}}' 2>/dev/null)
  if [ "${FORCE_REPLACE_UNOWNED:-false}" = "true" ]; then
    log "existing ${ns}/${name} has no readable ca.crt (keys: ${keys:-none}) — replacing it anyway"
    log "  because FORCE_REPLACE_UNOWNED=true. Backup: ${backup}"
    return 0
  fi
  die "ConfigMap ${ns}/${name} exists, was not created by this script, and has no readable ca.crt.
  Its keys are: ${keys:-<none>}
  Refusing to replace it, because there is no evidence that doing so is safe — a ConfigMap holding a
  trust bundle under another key looks exactly like this one. A full backup is at
    ${backup}
  Pick one:
    CA_CONFIGMAP_NAME=<free-name> ./15-bootstrap-cert-manager-ca.sh apply    write somewhere else
    FORCE_REPLACE_UNOWNED=true    ./15-bootstrap-cert-manager-ca.sh apply    replace it deliberately
    oc delete configmap ${name} -n ${ns}                                     remove it yourself first"
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
    guard_existing_configmap "$ns" "$CA_CONFIGMAP_NAME" "${tmp}/ca.crt"
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
      name: ${COPY_NAME}
      namespace: ${OPERATOR_NS}
      key: ca.crt

  That is already the chart default, so no override file is needed. The enterprise CA now lives at
  openshift-config/${CA_CONFIGMAP_NAME}; the chart's oauthSecretExtraction.caCopy reads it and writes
  ${OPERATOR_NS}/${COPY_NAME}, which is what the operator loads. A changed CA here moves the
  caSourceHash, so the next helm upgrade remakes the copy.

  Next: oc apply -f setup-local-ldap-testing/01-ldap-server.yaml   # mounts ${LEAF_SECRET}
        helm upgrade group-sync ../charts/group-sync-operator-helm -n ${OPERATOR_NS}
        ./15-bootstrap-cert-manager-ca.sh verify
VALUES
}

# Publishes the root to the cluster-wide trust bundle, so trustedCA.injected can carry it.
#
# LOCAL SIMULATION ONLY — NEVER RUN THIS ON A SHARED OR PRODUCTION CLUSTER.
#
# proxy/cluster.spec.trustedCA is platform-team property. On a real cluster it already holds the
# corporate root, it is changed only when that root is rotated, and repointing it swaps the trust anchor
# for EVERY workload that consumes the injected bundle — not just this operator. A chart or script that
# manages it can take out unrelated services.
#
# This exists purely so a lab cluster can pretend it has what an enterprise already has, and the chart
# can then be exercised as a CONSUMER of it. The chart itself never touches the proxy: no template
# patches it and no ServiceAccount is granted config.openshift.io/proxies. That separation is
# deliberate — keep it.
#
# This is what an enterprise cluster normally already has: the corporate root sits in
# proxy/cluster.spec.trustedCA, a validator merges it with the system store into
# openshift-config-managed/trusted-ca-bundle, and every ConfigMap labelled
# config.openshift.io/inject-trusted-cabundle gets the result. Nothing to copy per namespace.
#
# proxy.spec.trustedCA requires the key ca-bundle.crt, NOT ca.crt, so the root is republished under
# that name rather than reusing the ConfigMap apply created.
#
# COSTS A MACHINECONFIG ROLLOUT. The merge itself is API-level and takes seconds, but the trust bundle
# also belongs on the nodes, so MCO then rolls the pool. Measured on single-node CRC: new rendered
# MachineConfigs, pool Updating for ~105s, never Degraded, and the node's Ready condition transitioned.
# On a multi-node cluster MCO cordons and drains one node at a time. The MCP state is printed at the end
# so the roll is visible rather than a surprise.
cmd_trust_cluster() {
  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN

  oc extract "secret/${ROOT_SECRET}" -n "$CM_NS" --keys=ca.crt --to="$tmp" --confirm >/dev/null 2>&1 || true
  [ -s "${tmp}/ca.crt" ] || die "root CA not found in ${CM_NS}/${ROOT_SECRET} — run apply first"

  step "publishing the root to openshift-config/${TRUST_BUNDLE_CM}"
  oc create configmap "$TRUST_BUNDLE_CM" -n openshift-config \
     --from-file=ca-bundle.crt="${tmp}/ca.crt" --dry-run=client -o yaml \
    | oc label --local -f - -o yaml "$OWNED" \
    | oc apply -f - >/dev/null
  log "key ca-bundle.crt, as proxy.spec.trustedCA requires"

  local current
  current=$(oc get proxy cluster -o jsonpath='{.spec.trustedCA.name}' 2>/dev/null)
  if [ -n "$current" ] && [ "$current" != "$TRUST_BUNDLE_CM" ]; then
    die "proxy/cluster already trusts ConfigMap '${current}'.
  Refusing to replace it — that is the cluster's corporate trust bundle and every workload depends on
  it. Add this root to that bundle instead, or on a throwaway cluster:
    oc patch proxy cluster --type=merge -p '{\"spec\":{\"trustedCA\":{\"name\":\"${TRUST_BUNDLE_CM}\"}}}'"
  fi

  mkdir -p "$BACKUP_DIR"
  oc get proxy cluster -o yaml > "${BACKUP_DIR}/proxy-cluster.yaml" 2>/dev/null \
    && log "backed up proxy/cluster to ${BACKUP_DIR}/proxy-cluster.yaml"

  step "pointing proxy/cluster.spec.trustedCA at it"
  oc patch proxy cluster --type=merge \
     -p "{\"spec\":{\"trustedCA\":{\"name\":\"${TRUST_BUNDLE_CM}\"}}}" 2>&1 | sed 's/^/  /'

  step "waiting for the validator to merge it"
  local subject want
  want="LDAP Enterprise Root CA"
  for _ in $(seq 1 24); do
    rm -rf "${tmp}/merged" && mkdir -p "${tmp}/merged"
    oc extract configmap/trusted-ca-bundle -n openshift-config-managed \
       --keys=ca-bundle.crt --to="${tmp}/merged" --confirm >/dev/null 2>&1 || true
    if [ -s "${tmp}/merged/ca-bundle.crt" ] && grep -q 'BEGIN CERTIFICATE' "${tmp}/merged/ca-bundle.crt"; then
      subject=$(awk '/BEGIN CERT/{n++} {print > ("'"${tmp}"'/c" n ".pem")}' "${tmp}/merged/ca-bundle.crt" 2>/dev/null; \
                for f in "${tmp}"/c*.pem; do openssl x509 -in "$f" -noout -subject 2>/dev/null; done | grep -c "$want" || true)
      if [ "${subject:-0}" -gt 0 ]; then
        log "merged: $(grep -c 'BEGIN CERTIFICATE' "${tmp}/merged/ca-bundle.crt") certificates, including ${want}"
        break
      fi
    fi
    sleep 5
  done
  [ "${subject:-0}" -gt 0 ] || die "the root did not appear in openshift-config-managed/trusted-ca-bundle.
  Check: oc get proxy cluster -o yaml"

  step "MachineConfigPool state"
  oc get mcp master -o jsonpath='  updated={.status.conditions[?(@.type=="Updated")].status} updating={.status.conditions[?(@.type=="Updating")].status}{"\n"}' 2>/dev/null

  cat <<NEXT

  Every ConfigMap labelled config.openshift.io/inject-trusted-cabundle now receives this root, so
  the chart can use trustedCA.injected instead of copying:

    helm upgrade group-sync ../charts/group-sync-operator-helm -n ${OPERATOR_NS} --reset-values -f ../charts/group-sync-operator-helm/crc-injected-values.yaml

  To undo: ./15-bootstrap-cert-manager-ca.sh untrust-cluster
NEXT
}

# Reverts trust-cluster. Only clears trustedCA if it still names OUR ConfigMap, so it can never strip a
# corporate trust anchor someone else put there. Same LOCAL-SIMULATION-ONLY caveat as trust-cluster.
cmd_untrust_cluster() {
  local current
  current=$(oc get proxy cluster -o jsonpath='{.spec.trustedCA.name}' 2>/dev/null)
  if [ "$current" = "$TRUST_BUNDLE_CM" ]; then
    step "clearing proxy/cluster.spec.trustedCA"
    oc patch proxy cluster --type=merge -p '{"spec":{"trustedCA":{"name":""}}}' 2>&1 | sed 's/^/  /'
  elif [ -n "$current" ]; then
    log "proxy/cluster trusts '${current}', not ours — leaving it alone"
  else
    log "proxy/cluster.spec.trustedCA is already empty"
  fi
  oc delete configmap "$TRUST_BUNDLE_CM" -n openshift-config --ignore-not-found 2>&1 | sed 's/^/  /'
  log "groupSync.ca must point back at the copy, or re-enable caCopy"
}

cmd_verify() {
  step "certificate the LDAPS endpoint actually presents"

  # Verifies against the CA the operator ACTUALLY loads, read from the GroupSync CR — not a name this
  # script assumes. The chart can point the CR at either the copy fed by this script's source
  # (caCopy.enabled) or an OpenShift-injected trust bundle (trustedCA.injected), and those differ in
  # BOTH name and key: ca.crt for the copy, ca-bundle.crt for an injected bundle. Hardcoding the copy
  # verified a stale orphan left behind by an earlier copy-mode install while the live release trusted
  # something else entirely — reporting FAILED with the chain in fact fine.
  #
  # `|| true` is load-bearing twice over: with no GroupSync CR in the namespace `oc get` exits 1, and
  # under the set -euo pipefail at the top of this file a failing command substitution aborts the whole
  # script — silently, before the fallback below can explain anything. Ranging over providers[*].ldap
  # rather than indexing providers[0] also skips any non-LDAP provider, so an unrelated GroupSync CR
  # sorting ahead of ours cannot make this read an empty name and fall back for the wrong reason.
  local ca_cm ca_key ref
  ref=$(oc get groupsync -n "$OPERATOR_NS" \
        -o jsonpath='{range .items[*].spec.providers[*].ldap}{.caSecret.name}{" "}{.caSecret.key}{"\n"}{end}' \
        2>/dev/null | grep -v '^[[:space:]]*$' | head -1) || true
  ca_cm=${ref%% *}
  ca_key=${ref#* }

  if [ -n "$ca_cm" ]; then
    # Empty key means the chart left it defaulted; the operator falls back to ca.crt, so match that.
    : "${ca_key:=ca.crt}"
    if ! oc get configmap "$ca_cm" -n "$OPERATOR_NS" >/dev/null 2>&1; then
      die "the GroupSync CR loads ${OPERATOR_NS}/${ca_cm}, which does not exist — so the operator has
  no CA at all. Either the chart's extraction job has not run, or trustedCA.injected names a
  ConfigMap that was never created:
    helm upgrade group-sync ../charts/group-sync-operator-helm -n ${OPERATOR_NS}"
    fi
  else
    # Nothing to read: either the chart is not installed, or its LDAP provider has no caSecret at all
    # (insecure: true, so the chain is never checked). Fall back to the copy this script's source feeds,
    # which is still worth verifying — it is what a later switch to insecure: false would rely on.
    ca_cm="$COPY_NAME"
    ca_key="ca.crt"
    oc get configmap "$ca_cm" -n "$OPERATOR_NS" >/dev/null 2>&1 \
      || die "no GroupSync CR in ${OPERATOR_NS} names a CA, and there is no ${OPERATOR_NS}/${COPY_NAME}
  to fall back on. Install the chart first — or, if it is installed with insecure: true, run apply so
  ${CA_CONFIGMAP_NAMESPACES}/${CA_CONFIGMAP_NAME} exists and the copy can be built from it."
    log "no CA named by any GroupSync CR — falling back to the copy"
  fi

  # A stale copy verifies against nothing useful, so the recorded source hash is surfaced. Absent on an
  # injected bundle, which this script does not write, so the suffix simply drops out.
  local stamped
  stamped=$(oc get configmap "$ca_cm" -n "$OPERATOR_NS" \
            -o jsonpath='{.metadata.annotations.group-sync\.redhat-cop\.io/source-hash}' 2>/dev/null)
  log "verifying against ${OPERATOR_NS}/${ca_cm} key ${ca_key}${stamped:+ (source-hash ${stamped})}"

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
      '-CAfile /ca/${ca_key} -verify_return_error 2>&1 '
      '| grep -Ei \"^subject=|^issuer=|Verify return code|Verification\"; '
      'echo | openssl s_client -connect ${SAN_FQDN}:636 -CAfile /ca/${ca_key} 2>/dev/null '
      '| openssl x509 -noout -ext subjectAltName'],
    'volumeMounts':[{'name':'ca','mountPath':'/ca','readOnly':True}],
    'securityContext':{'allowPrivilegeEscalation':False,'capabilities':{'drop':['ALL']}}}],
  'securityContext':{'runAsNonRoot':True,'seccompProfile':{'type':'RuntimeDefault'}},
  'volumes':[{'name':'ca','configMap':{'name':'${ca_cm}'}}]}}))")

  # Asserted on the success string, not on an exit code. oc run's status is masked by the pipe, and
  # a chain that fails to verify still produces output — so a missing "Verify return code: 0" is the
  # only reliable signal that this did NOT pass.
  local out
  out=$(oc run "ldaps-verify-$$" -n "$OPERATOR_NS" --rm -i --restart=Never \
        --image=registry.redhat.io/rhel9/openssl:latest \
        --overrides="$overrides" 2>&1) || true
  printf '%s\n' "$out" | sed 's/^/  /'

  printf '%s' "$out" | grep -q 'Verify return code: 0 (ok)' \
    || die "the LDAPS endpoint did not verify against ${OPERATOR_NS}/${ca_cm}.
  Either the endpoint is not serving the cert-manager certificate (run switch-ldap, then
  'oc rollout restart deploy/openldap-server -n ${LDAP_NS}'), or ${ca_cm} does not carry the root that
  signed it. For a copy that means the source is stale (run apply); for an injected bundle it means the
  root never reached the cluster's trust (run trust-cluster)."

  printf '%s' "$out" | grep -q "DNS:${SAN_FQDN}" \
    || die "the served certificate has no SAN for ${SAN_FQDN}, so a verifying client will reject it."
  log "verified: chain OK and SAN matches ${SAN_FQDN}"
}

cmd_delete() {
  step "deleting only objects labelled ${OWNED}"

  # The trust bundle is labelled OWNED and lives in openshift-config, so the sweep below would take it —
  # while proxy/cluster.spec.trustedCA still names it. That leaves the cluster proxy pointing at a
  # ConfigMap that no longer exists, and the validator can no longer build
  # openshift-config-managed/trusted-ca-bundle for anything relying on trusted-CA injection.
  #
  # So it is EXCLUDED rather than deleted, and the proxy is left untouched: removing a ConfigMap the
  # cluster depends on should be an explicit act, not a side effect of cleanup. untrust-cluster is the
  # command that does it, in the right order.
  local trusted_by_proxy
  trusted_by_proxy=$(oc get proxy cluster -o jsonpath='{.spec.trustedCA.name}' 2>/dev/null)

  for ns in $CA_CONFIGMAP_NAMESPACES; do
    if [ "$trusted_by_proxy" = "$TRUST_BUNDLE_CM" ] && [ "$ns" = "openshift-config" ]; then
      # Delete by name, skipping the bundle, instead of by label selector.
      for cm in $(oc get configmap -n "$ns" -l "$OWNED" -o name 2>/dev/null); do
        if [ "${cm##*/}" = "$TRUST_BUNDLE_CM" ]; then
          log "KEEPING ${ns}/${TRUST_BUNDLE_CM} — proxy/cluster.spec.trustedCA still names it"
          log "  to remove it: ./15-bootstrap-cert-manager-ca.sh untrust-cluster"
          continue
        fi
        oc delete "$cm" -n "$ns" --ignore-not-found 2>&1 | sed 's/^/  /'
      done
    else
      oc delete configmap -n "$ns" -l "$OWNED" --ignore-not-found 2>&1 | sed 's/^/  /'
    fi
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
  apply)           cmd_apply ;;
  verify)          cmd_verify ;;
  trust-cluster)   cmd_trust_cluster ;;
  untrust-cluster) cmd_untrust_cluster ;;
  delete)          cmd_delete ;;
  *) die "unknown command '${1}'. Use: apply | verify | trust-cluster | untrust-cluster | delete" ;;
esac
